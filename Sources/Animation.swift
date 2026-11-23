import Metal
import simd
import Foundation

/// Anima a cena: balanço das palmeiras e demais nós animados do `scene.bin` (V40S).
/// - Os canais de animação mexem na translação/rotação dos nós (loop de `duration` segundos).
/// - Malhas com skin são deformadas na CPU (4 juntas por vértice) em buffers próprios, em rodízio
///   para a GPU nunca ler um buffer que está sendo escrito.
/// - Para malhas com skin a posição final já sai no espaço do mundo (junta * bind inversa), então
///   elas são desenhadas com a matriz identidade.
final class SceneAnimator {
    private let scene: LoadedScene
    private(set) var world: [simd_float4x4]
    private var t: [SIMD3<Float>]
    private var q: [SIMD4<Float>]
    private var jointMats: [[simd_float4x4]]
    private let slots = 4
    private var slot = 0

    private struct Skinned {
        let drawIndex: Int
        let skin: Int
        let source: SkinSource
        let buffers: [MTLBuffer]
    }
    private var skinned: [Skinned] = []
    private var skinnedByDraw: [Int: Int] = [:]

    /// Só cria o animador se a cena tiver o que animar.
    init?(scene: LoadedScene, device: MTLDevice) {
        guard !scene.channels.isEmpty, scene.duration > 0, !scene.nodeParent.isEmpty else { return nil }
        self.scene = scene
        self.t = scene.nodeT
        self.q = scene.nodeQ
        self.world = [simd_float4x4](repeating: matrix_identity_float4x4, count: scene.nodeParent.count)
        self.jointMats = scene.skins.map { [simd_float4x4](repeating: matrix_identity_float4x4, count: $0.joints.count) }

        for (i, d) in scene.draws.enumerated() {
            guard d.node >= 0, d.node < scene.nodeSkin.count else { continue }
            let sk = scene.nodeSkin[d.node]
            guard sk >= 0, sk < scene.skins.count, let src = scene.skinSources[d.mesh] else { continue }
            if scene.meshes[d.mesh].indexCount == 0 { continue }
            let vc = src.base.count / 5
            var bufs: [MTLBuffer] = []
            for _ in 0..<slots {
                guard let b = device.makeBuffer(bytes: src.base, length: vc * 20, options: .storageModeShared) else { return nil }
                bufs.append(b)
            }
            skinnedByDraw[i] = skinned.count
            skinned.append(Skinned(drawIndex: i, skin: sk, source: src, buffers: bufs))
        }
        computeWorld()
    }

    /// Buffer de vértices já deformado para o quadro atual (nil = desenhar a malha original).
    func skinnedBuffer(forDraw i: Int) -> MTLBuffer? {
        guard let k = skinnedByDraw[i] else { return nil }
        return skinned[k].buffers[slot]
    }

    func update(time: Double) {
        let dur = Double(scene.duration)
        let tt = Float(time.truncatingRemainder(dividingBy: dur))
        for ch in scene.channels {
            guard ch.node >= 0, ch.node < t.count else { continue }
            let n = ch.times.count
            var i0 = 0
            var frac: Float = 0
            if n > 1 && tt > ch.times[0] {
                if tt >= ch.times[n - 1] {
                    i0 = n - 1
                } else {
                    var lo = 0
                    var hi = n - 1
                    while hi - lo > 1 {
                        let mid = (lo + hi) / 2
                        if ch.times[mid] <= tt { lo = mid } else { hi = mid }
                    }
                    i0 = lo
                    let span = ch.times[hi] - ch.times[lo]
                    frac = span > 0 ? (tt - ch.times[lo]) / span : 0
                }
            }
            let i1 = min(i0 + 1, n - 1)
            if ch.path == 0 {
                let a = SIMD3<Float>(ch.values[i0 * 3], ch.values[i0 * 3 + 1], ch.values[i0 * 3 + 2])
                let b = SIMD3<Float>(ch.values[i1 * 3], ch.values[i1 * 3 + 1], ch.values[i1 * 3 + 2])
                t[ch.node] = a + (b - a) * frac
            } else {
                let a = SIMD4<Float>(ch.values[i0 * 4], ch.values[i0 * 4 + 1], ch.values[i0 * 4 + 2], ch.values[i0 * 4 + 3])
                var b = SIMD4<Float>(ch.values[i1 * 4], ch.values[i1 * 4 + 1], ch.values[i1 * 4 + 2], ch.values[i1 * 4 + 3])
                if simd_dot(a, b) < 0 { b = -b }
                let m = a + (b - a) * frac
                let len = max(simd_length(m), 1e-6)
                q[ch.node] = m / len
            }
        }
        computeWorld()
        slot = (slot + 1) % slots
        for sk in skinned { skin(sk) }
    }

    private func computeWorld() {
        let n = scene.nodeParent.count
        for i in 0..<n {
            let local = simd_float4x4.trs(t: t[i], q: q[i], s: scene.nodeS[i])
            let p = scene.nodeParent[i]
            if p >= 0 && p < i {
                world[i] = world[p] * local
            } else {
                world[i] = local
            }
        }
    }

    private func skin(_ sk: Skinned) {
        let info = scene.skins[sk.skin]
        let jc = info.joints.count
        if jc == 0 { return }
        var mats = jointMats[sk.skin]
        for j in 0..<jc {
            let node = info.joints[j]
            mats[j] = (node >= 0 && node < world.count) ? world[node] * info.ibm[j] : matrix_identity_float4x4
        }
        jointMats[sk.skin] = mats

        let vc = sk.source.base.count / 5
        let dst = sk.buffers[slot].contents().bindMemory(to: Float.self, capacity: vc * 5)
        sk.source.base.withUnsafeBufferPointer { base in
            sk.source.joints.withUnsafeBufferPointer { joints in
                sk.source.weights.withUnsafeBufferPointer { weights in
                    for i in 0..<vc {
                        let p = SIMD4<Float>(base[i * 5], base[i * 5 + 1], base[i * 5 + 2], 1)
                        var acc = SIMD4<Float>(0, 0, 0, 0)
                        var wsum: Float = 0
                        for k in 0..<4 {
                            let w = weights[i * 4 + k]
                            if w <= 0 { continue }
                            let j = min(Int(joints[i * 4 + k]), jc - 1)
                            acc += (mats[j] * p) * w
                            wsum += w
                        }
                        if wsum > 0 {
                            dst[i * 5] = acc.x
                            dst[i * 5 + 1] = acc.y
                            dst[i * 5 + 2] = acc.z
                        } else {
                            // sem peso: fica no lugar de repouso, no espaço do mundo
                            let m = scene.draws[sk.drawIndex].world * p
                            dst[i * 5] = m.x
                            dst[i * 5 + 1] = m.y
                            dst[i * 5 + 2] = m.z
                        }
                        dst[i * 5 + 3] = base[i * 5 + 3]
                        dst[i * 5 + 4] = base[i * 5 + 4]
                    }
                }
            }
        }
    }
}

import Metal
import simd
import Foundation

enum SceneError: Error {
    case missing
    case badMagic
    case truncated
}

struct MeshGPU {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let material: Int
}

struct MaterialInfo {
    let texture: Int
    let blend: Bool
    let tint: SIMD4<Float>
}

struct SceneDraw {
    let mesh: Int
    let world: simd_float4x4
    let node: Int
}

/// Esqueleto: nós das juntas e matrizes bind inversas (formato V40S, seção de skins).
struct SkinInfo {
    var joints: [Int]
    var ibm: [simd_float4x4]
}

/// Canal de animação de um nó. path 0 = translação (3 floats), 1 = rotação quaternion xyzw (4 floats).
struct AnimChannel {
    let node: Int
    let path: Int
    let times: [Float]
    let values: [Float]
}

/// Dados por vértice de uma malha com skin: posição+uv de repouso, 4 juntas e 4 pesos.
struct SkinSource {
    var base: [Float]      // vc * 5 (x y z u v)
    var joints: [UInt8]    // vc * 4
    var weights: [Float]   // vc * 4
}

final class LoadedScene {
    var meshes: [MeshGPU] = []
    var materials: [MaterialInfo] = []
    var textureNames: [String] = []
    var draws: [SceneDraw] = []
    var radius: Float = 0

    // hierarquia e animação
    var nodeParent: [Int] = []
    var nodeT: [SIMD3<Float>] = []
    var nodeQ: [SIMD4<Float>] = []
    var nodeS: [SIMD3<Float>] = []
    var nodeSkin: [Int] = []
    var skins: [SkinInfo] = []
    var channels: [AnimChannel] = []
    var duration: Float = 0
    var skinSources: [Int: SkinSource] = [:]   // índice da malha -> dados de skin
}

/// Formato "V40S" v2 (scene.bin):
///   header: magic[4] version u32, radius f32, nodeCount u32
///   nodes : parent i32, pos f32x3, quat f32x4 (xyzw), scale f32x3, mesh i32, skin i32  (52 bytes)
///   meshes: count u32, depois por malha: a u32, material u32, vertCount u32, idxCount u32, flags u32,
///           vertices (pos f32x3, uv f32x2), índices u32, e se flags != 0: vertCount * 32 bytes de animação
///   materiais: count u32, cada um: textura u32, blend u32, tint f32x4
///   texturas : count u32, cada uma: len u32 + nome
enum SceneLoader {
    private struct Reader {
        let data: Data
        var offset = 0

        init(_ d: Data) { data = d }

        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw SceneError.truncated }
            let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: v)
        }

        mutating func i32() throws -> Int32 {
            return Int32(bitPattern: try u32())
        }

        mutating func f32() throws -> Float {
            return Float(bitPattern: try u32())
        }

        mutating func floats(_ n: Int) throws -> [Float] {
            guard n >= 0, offset + n * 4 <= data.count else { throw SceneError.truncated }
            var out = [Float](repeating: 0, count: n)
            let start = offset
            let bytes = n * 4
            if bytes > 0 {
                out.withUnsafeMutableBytes { dst in
                    data.withUnsafeBytes { src in
                        dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[start..<(start + bytes)]))
                    }
                }
            }
            offset += bytes
            return out
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0, offset + n <= data.count else { throw SceneError.truncated }
            offset += n
        }

        mutating func string(_ n: Int) throws -> String {
            guard n >= 0, offset + n <= data.count else { throw SceneError.truncated }
            let sub = data.subdata(in: offset..<(offset + n))
            offset += n
            return String(decoding: sub, as: UTF8.self)
        }
    }

    static func load(device: MTLDevice, name: String) throws -> LoadedScene {
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "bin", subdirectory: name) else {
            throw SceneError.missing
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var r = Reader(data)

        let magic = try r.u32()
        guard magic == 0x53303456 else { throw SceneError.badMagic } // "V40S"
        _ = try r.u32() // versão
        let scene = LoadedScene()
        scene.radius = try r.f32()
        let nodeCount = Int(try r.u32())

        struct Node {
            var parent: Int
            var local: simd_float4x4
            var mesh: Int
            var skin: Int
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            let parent = Int(try r.i32())
            let p = SIMD3<Float>(try r.f32(), try r.f32(), try r.f32())
            let q = SIMD4<Float>(try r.f32(), try r.f32(), try r.f32(), try r.f32())
            let s = SIMD3<Float>(try r.f32(), try r.f32(), try r.f32())
            let mesh = Int(try r.i32())
            let skin = Int(try r.i32())
            nodes.append(Node(parent: parent, local: simd_float4x4.trs(t: p, q: q, s: s), mesh: mesh, skin: skin))
            scene.nodeParent.append(parent)
            scene.nodeT.append(p)
            scene.nodeQ.append(q)
            scene.nodeS.append(s)
            scene.nodeSkin.append(skin)
        }

        let meshCount = Int(try r.u32())
        for _ in 0..<meshCount {
            _ = try r.u32()
            let material = Int(try r.u32())
            let vc = Int(try r.u32())
            let ic = Int(try r.u32())
            let flags = try r.u32()

            // flags == 0: vértice de 20 bytes (pos + uv).
            // flags != 0: vértice de 52 bytes intercalado (20 + 32 de animação).
            let vstride = flags != 0 ? 52 : 20
            let ibytes = ic * 4
            guard r.offset + vc * vstride + ibytes <= data.count else { throw SceneError.truncated }

            let vb: MTLBuffer? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLBuffer? in
                let src = raw.baseAddress!.advanced(by: r.offset)
                if vstride == 20 {
                    return device.makeBuffer(bytes: src, length: vc * 20, options: .storageModeShared)
                }
                guard let buf = device.makeBuffer(length: vc * 20, options: .storageModeShared) else { return nil }
                let dst = buf.contents()
                for i in 0..<vc {
                    memcpy(dst + i * 20, src + i * vstride, 20)
                }
                return buf
            }
            let ib: MTLBuffer? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLBuffer? in
                return device.makeBuffer(bytes: raw.baseAddress!.advanced(by: r.offset + vc * vstride),
                                         length: ibytes, options: .storageModeShared)
            }
            guard let vbuf = vb, let ibuf = ib else { throw SceneError.truncated }

            // Proteção: índice fora do intervalo derruba a GPU. Nesse caso a malha não é desenhada.
            let indicesOK: Bool = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                let base = r.offset + vc * vstride
                for i in 0..<ic {
                    let idx = raw.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                    if Int(idx) >= vc { return false }
                }
                return true
            }

            if vstride == 52 && indicesOK {
                // 32 bytes por vértice depois de pos+uv: 4 índices de junta (float) e 4 pesos (float)
                var src = SkinSource(base: [Float](repeating: 0, count: vc * 5),
                                     joints: [UInt8](repeating: 0, count: vc * 4),
                                     weights: [Float](repeating: 0, count: vc * 4))
                let baseOff = r.offset
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    for i in 0..<vc {
                        let o = baseOff + i * 52
                        for k in 0..<5 {
                            src.base[i * 5 + k] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + k * 4, as: UInt32.self))
                        }
                        for k in 0..<4 {
                            let jf = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + 20 + k * 4, as: UInt32.self))
                            src.joints[i * 4 + k] = jf.isFinite ? UInt8(max(0, min(255, jf))) : 0
                            src.weights[i * 4 + k] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + 36 + k * 4, as: UInt32.self))
                        }
                    }
                }
                scene.skinSources[scene.meshes.count] = src
            }

            try r.skip(vc * vstride + ibytes)
            scene.meshes.append(MeshGPU(vertexBuffer: vbuf, indexBuffer: ibuf,
                                        indexCount: indicesOK ? ic : 0, material: material))
        }

        let matCount = Int(try r.u32())
        for _ in 0..<matCount {
            let tex = Int(try r.u32())
            let blend = try r.u32()
            let tint = SIMD4<Float>(try r.f32(), try r.f32(), try r.f32(), try r.f32())
            scene.materials.append(MaterialInfo(texture: tex, blend: blend != 0, tint: tint))
        }

        let texCount = Int(try r.u32())
        for _ in 0..<texCount {
            let len = Int(try r.u32())
            scene.textureNames.append(try r.string(len))
        }

        // Seções opcionais no fim do arquivo: skins e canais de animação (se faltar ou estiver truncado, a cena fica estática).
        if r.offset + 4 <= data.count {
            do {
                var skins: [SkinInfo] = []
                let skinCount = Int(try r.u32())
                for _ in 0..<skinCount {
                    let jc = Int(try r.u32())
                    var joints: [Int] = []
                    var ibm: [simd_float4x4] = []
                    for _ in 0..<jc {
                        joints.append(Int(try r.u32()))
                        let f = try r.floats(16)
                        ibm.append(simd_float4x4(columns: (
                            SIMD4<Float>(f[0], f[1], f[2], f[3]),
                            SIMD4<Float>(f[4], f[5], f[6], f[7]),
                            SIMD4<Float>(f[8], f[9], f[10], f[11]),
                            SIMD4<Float>(f[12], f[13], f[14], f[15]))))
                    }
                    skins.append(SkinInfo(joints: joints, ibm: ibm))
                }
                var channels: [AnimChannel] = []
                var duration: Float = 0
                let chCount = Int(try r.u32())
                for _ in 0..<chCount {
                    let node = Int(try r.u32())
                    let path = Int(try r.u32())
                    _ = try r.u32()            // interpolação (0 = linear)
                    let dur = try r.f32()
                    let n = Int(try r.u32())
                    let comps = path == 1 ? 4 : 3
                    guard path == 0 || path == 1 || path == 2, n > 0 else { throw SceneError.truncated }
                    let times = try r.floats(n)
                    let values = try r.floats(n * comps)
                    duration = max(duration, dur)
                    if path != 2 {
                        channels.append(AnimChannel(node: node, path: path, times: times, values: values))
                    }
                }
                scene.skins = skins
                scene.channels = channels
                scene.duration = duration
            } catch {
                scene.skins = []
                scene.channels = []
                scene.skinSources = [:]
            }
        }

        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            if n.parent >= 0 && n.parent < i {
                world[i] = world[n.parent] * n.local
            } else {
                world[i] = n.local
            }
            if n.mesh >= 0 && n.mesh < scene.meshes.count {
                scene.draws.append(SceneDraw(mesh: n.mesh, world: world[i], node: i))
            }
        }
        return scene
    }
}

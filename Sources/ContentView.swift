import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            PassthroughLayer(menu: model.menu, tracker: model.tracker, vr: model.vrMode)
                .ignoresSafeArea()
            MetalView(model: model)
                .ignoresSafeArea()
            NightOverlay(menu: model.menu)
                .ignoresSafeArea()
            if model.vrMode {
                VRMenuLayer(model: model, menu: model.menu, pointer: model.pointer)
                    .ignoresSafeArea()
            } else {
                TopBar(model: model, tracker: model.tracker)
                MenuOverlay(menu: model.menu, app: model, keyboard: model.keyboard, browser: model.browser)
                    .ignoresSafeArea()
                VRButton(model: model)
                CaptureOverlay(capture: model.capture)
                    .ignoresSafeArea()
                PointerOverlay(pointer: model.pointer)
                    .ignoresSafeArea()
            }
        }
        .onAppear { model.start() }
        .sheet(item: $model.sharePayload) { payload in
            ShareSheet(url: payload.url)
        }
        .sheet(item: $model.picker) { req in
            PickerView(request: req, app: model, onDone: { model.picker = nil })
        }
    }
}

/// Estado das mãos (canto superior) e miniatura da câmera.
struct TopBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tracker: HandTracker

    private var buildNumber: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                Text("v3 #\(buildNumber) • \(tracker.status)")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(.top, 58)
                    .padding(.leading, 14)
                Spacer()
                if model.showCamera {
                    CameraPreview(session: tracker.session)
                        .frame(width: 104, height: 138)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.5), lineWidth: 1))
                        .padding(.top, 54)
                        .padding(.trailing, 14)
                }
            }
            if model.renderInfo.hasPrefix("ERRO") || model.renderInfo.hasPrefix("GPU") {
                Text(model.renderInfo)
                    .font(.caption2)
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// Passthrough: câmera por trás da cena (o Renderer limpa o fundo transparente e não desenha o ambiente).
/// No modo VR a câmera aparece nos dois olhos.
struct PassthroughLayer: View {
    @ObservedObject var menu: MenuModel
    let tracker: HandTracker
    let vr: Bool

    var body: some View {
        if menu.passthrough {
            if vr {
                VREyes(shift: CGFloat(menu.vrShiftFraction)) { _ in
                    CameraPreview(session: tracker.session)
                }
            } else {
                CameraPreview(session: tracker.session)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - modo VR

/// Desenha o conteúdo duas vezes, lado a lado: olho esquerdo e olho direito.
/// `shift` (fração da largura) aproxima as imagens uma da outra, para casar com as lentes.
struct VREyes<Content: View>: View {
    let shift: CGFloat
    let content: (Int) -> Content

    init(shift: CGFloat, @ViewBuilder content: @escaping (Int) -> Content) {
        self.shift = shift
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            eyes(geo.size)
        }
    }

    private func eyes(_ size: CGSize) -> some View {
        let half = size.width / 2
        let dx = shift * size.width
        return HStack(spacing: 0) {
            eye(0, half: half, height: size.height, dx: dx)
            eye(1, half: half, height: size.height, dx: -dx)
        }
        .frame(width: size.width, height: size.height)
    }

    private func eye(_ index: Int, half: CGFloat, height: CGFloat, dx: CGFloat) -> some View {
        return ZStack {
            content(index)
                .frame(width: half, height: height)
                .offset(x: dx)
        }
        .frame(width: half, height: height)
        .clipped()
    }
}

/// Menu e cursores das mãos nos dois olhos. Só o olho esquerdo registra os alvos da pinça.
struct VRMenuLayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var menu: MenuModel
    let pointer: PointerModel

    var body: some View {
        VREyes(shift: CGFloat(menu.vrShiftFraction)) { i in
            ZStack {
                MenuOverlay(menu: menu, app: model, keyboard: model.keyboard, browser: model.browser,
                            registersFrames: i == 0, vr: true)
                PointerOverlay(pointer: pointer)
            }
        }
    }
}

/// Botão para entrar no modo VR (modo normal, canto superior esquerdo).
struct VRButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack {
            HStack {
                Button(action: { model.toggleVR() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                        Text("Entrar no modo VR")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
                }
                Spacer()
            }
            .padding(.top, 94)
            .padding(.leading, 14)
            Spacer()
        }
    }
}

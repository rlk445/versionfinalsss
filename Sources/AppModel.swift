import SwiftUI
import UIKit

final class AppModel: ObservableObject {
    let tracker = HandTracker()
    let motion = MotionController()
    let audio = AudioManager()
    let menu = MenuModel()
    let keyboard = KeyboardModel()
    let browser = BrowserModel()
    let media = MediaModel()
    let capture = CaptureManager()
    let notifs = NotificationsModel()
    let controllers = ControllersModel()
    let cast = CastModel()
    let pointer = PointerModel()
    weak var renderer: Renderer?

    @Published var gyroEnabled = true {
        didSet { motion.enabled = gyroEnabled }
    }
    @Published var showCamera = true
    /// Modo VR (tela dividida em dois olhos, em paisagem, para VR Box / Shinecon).
    @Published var vrMode = false {
        didSet { if vrMode != oldValue { applyVR() } }
    }
    /// Inverte a paisagem (home à esquerda / à direita), conforme o encaixe do celular no VR Box.
    @Published var vrFlip: Bool {
        didSet {
            UserDefaults.standard.set(vrFlip, forKey: "vr_flip")
            if vrMode { OrientationControl.apply(vrOrientationMask) }
        }
    }
    private var cameraBeforeVR: HandCamera?
    @Published var renderInfo = "renderer: iniciando…"
    @Published var booting = true
    @Published var showWelcome = false
    @Published var sharePayload: SharePayload?
    @Published var picker: PickerRequest?
    private var started = false

    init() {
        vrFlip = UserDefaults.standard.bool(forKey: "vr_flip")
        menu.app = self
        keyboard.app = self
        browser.app = self
        media.app = self
        capture.app = self
        notifs.app = self
        controllers.app = self
        cast.app = self
        applyPrefs()
    }

    /// Aplica as preferências do menu nos módulos de áudio e de mãos.
    func applyPrefs() {
        audio.sfxEnabled = menu.sounds
        audio.hoverEnabled = menu.hoverSounds
        audio.envSoundsEnabled = menu.envSounds
        audio.volume = Float(menu.volume)
        tracker.handsEnabled = menu.handTracking
    }

    func start() {
        if started { return }
        started = true
        motion.start()
        tracker.start()
        menu.startMonitoring()
        media.refresh()
        audio.play("startup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                self.booting = false
                self.showWelcome = !UserDefaults.standard.bool(forKey: "welcomed")
            }
        }
    }

    func recenter() {
        renderer?.recenter()
    }

    var vrOrientationMask: UIInterfaceOrientationMask {
        return vrFlip ? .landscapeLeft : .landscapeRight
    }

    func toggleVR() {
        vrMode.toggle()
    }

    /// Entra/sai do modo VR: gira a tela, troca a câmera (traseira no VR) e recentraliza a vista.
    private func applyVR() {
        if vrMode {
            OrientationControl.apply(vrOrientationMask)
            cameraBeforeVR = tracker.camera
            if tracker.camera == .front && HandCamera.backWide.device() != nil {
                tracker.selectCamera(.backWide)
            }
            menu.showToast("Modo VR: encaixe o celular no VR Box")
        } else {
            OrientationControl.apply(.portrait)
            if let prev = cameraBeforeVR, prev != tracker.camera {
                tracker.selectCamera(prev)
            }
            cameraBeforeVR = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.recenter()
        }
    }
}

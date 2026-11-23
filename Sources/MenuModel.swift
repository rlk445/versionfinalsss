import SwiftUI
import UIKit
import Network

enum MenuPage: Hashable {
    case quick, settings, environments, system, personal, hands, access, storage, about
    case files, share, notifs, profile, privacy, library

    var title: String {
        switch self {
        case .quick: return "Configurações rápidas"
        case .settings: return "Configurações"
        case .environments: return "Ambientes"
        case .system: return "Sistema"
        case .personal: return "Personalização"
        case .hands: return "Mãos e Controles"
        case .access: return "Acessibilidade"
        case .storage: return "Armazenamento"
        case .about: return "Sobre"
        case .files: return "Arquivos"
        case .share: return "Compartilhar"
        case .notifs: return "Notificações"
        case .profile: return "Perfil"
        case .privacy: return "Privacidade"
        case .library: return "Apps"
        }
    }
}

/// Janelas de aplicativo que ficam no lugar do painel de páginas.
enum AppWindow {
    case browser, viewer
}

struct PointerDot: Identifiable {
    let id: String
    let point: CGPoint
    let pinching: Bool
}

/// Posição dos cursores das mãos na tela. Fica separado do menu para que só o cursor redesenhe a cada quadro.
final class PointerModel: ObservableObject {
    @Published var dots: [PointerDot] = []
}

/// O que uma pinça começou a fazer (decidido no instante em que a pinça fecha).
enum PressKind {
    case scene                       // arrastar o cenário
    case blocked                     // pinça sobre o painel, sem efeito
    case slider(String)              // arrastar um controle deslizante (id bruto)
    case scroll                      // rolar a lista
    case web(CGPoint)                // pinça sobre a página web: vira clique se não arrastar
    case webScroll                   // arrastar a página web
    case grab                        // mover o menu
    case resize                      // redimensionar o menu pela borda
    case pendingTap(String, CGPoint) // botão dentro da lista: vira clique só se não arrastar
}

struct EnvInfo {
    let id: String
    let name: String
    let grad: Int
}

final class MenuModel: ObservableObject {
    /// Os 7 ambientes do shell original (ENV_IDS / ENV_NAMES).
    static let environments: [EnvInfo] = [
        EnvInfo(id: "winterlodge", name: "Winter Lodge", grad: 1),
        EnvInfo(id: "desert", name: "Desert Terrace", grad: 0),
        EnvInfo(id: "bubbles", name: "Bubbles", grad: 2),
        EnvInfo(id: "ryokan", name: "Ryokan Retreat", grad: 3),
        EnvInfo(id: "dome", name: "Quest Dome", grad: 4),
        EnvInfo(id: "spacestation", name: "Space Station", grad: 5),
        EnvInfo(id: "cybercity", name: "Cyber City", grad: 8)
    ]

    static func isAvailable(_ id: String) -> Bool {
        return Bundle.main.url(forResource: "scene", withExtension: "bin", subdirectory: id) != nil
    }

    static func envName(_ id: String) -> String {
        return environments.first(where: { $0.id == id })?.name ?? id
    }

    weak var app: AppModel?

    // estado de navegação
    @Published var isOpen = false
    @Published var stack: [MenuPage] = []
    @Published var hoverId: String?
    @Published var offset: CGSize = .zero
    @Published var scroll: CGFloat = 0
    @Published var toast: String?
    @Published var loadingEnv: String?
    @Published var window: AppWindow?
    @Published var profileName: String {
        didSet { UserDefaults.standard.set(profileName, forKey: "profile_name") }
    }
    @Published var profilePhoto: UIImage?

    // estado do sistema
    @Published var now = Date()
    @Published var battery = -1
    @Published var charging = false
    @Published var wifi = false

    // preferências (salvas em UserDefaults)
    @Published var themeLight: Bool { didSet { UserDefaults.standard.set(themeLight, forKey: "theme_light") } }
    @Published var night: Bool { didSet { UserDefaults.standard.set(night, forKey: "night") } }
    @Published var sounds: Bool {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds"); app?.applyPrefs() }
    }
    @Published var envSounds: Bool {
        didSet { UserDefaults.standard.set(envSounds, forKey: "env_sounds"); app?.applyPrefs() }
    }
    @Published var hoverSounds: Bool {
        didSet { UserDefaults.standard.set(hoverSounds, forKey: "hover_sounds"); app?.applyPrefs() }
    }
    @Published var handTracking: Bool {
        didSet { UserDefaults.standard.set(handTracking, forKey: "hand_tracking"); app?.applyPrefs() }
    }
    /// 1 ou 2 mãos rastreadas ao mesmo tempo.
    @Published var maxHands: Int {
        didSet { UserDefaults.standard.set(maxHands, forKey: "max_hands"); app?.applyPrefs() }
    }
    /// Tamanho do painel do menu, ajustado arrastando a borda (como no PC). 1.0 = tamanho padrão.
    @Published var panelScale: CGFloat {
        didSet { UserDefaults.standard.set(Double(panelScale), forKey: "panel_scale") }
    }
    @Published var volume: Double {
        didSet { UserDefaults.standard.set(volume, forKey: "volume"); app?.applyPrefs() }
    }
    @Published var textScaleIdx: Int { didSet { UserDefaults.standard.set(textScaleIdx, forKey: "text_scale") } }
    @Published var homeEnv: String { didSet { UserDefaults.standard.set(homeEnv, forKey: "home_env") } }
    @Published var brightness: Double
    /// Separação das duas imagens do modo VR (0...4, 2 = padrão; maior = imagens mais juntas).
    @Published var vrShiftIdx: Int {
        didSet { UserDefaults.standard.set(vrShiftIdx, forKey: "vr_shift") }
    }
    /// Passthrough: mostra a câmera no lugar do ambiente virtual (não é salvo).
    @Published var passthrough = false

    // posições dos alvos (preenchido pelo SwiftUI; não precisa redesenhar nada)
    var frames: [String: CGRect] = [:]
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    private var dragBase: CGSize?
    private var resizeBase: CGFloat?
    private var touchScrollBase: CGFloat?
    private var toastWork: DispatchWorkItem?
    private var timer: Timer?
    private var monitoring = false
    private let pathMonitor = NWPathMonitor()

    init() {
        let d = UserDefaults.standard
        func flag(_ key: String, _ def: Bool) -> Bool {
            return d.object(forKey: key) == nil ? def : d.bool(forKey: key)
        }
        themeLight = flag("theme_light", false)
        night = flag("night", false)
        sounds = flag("sounds", true)
        envSounds = flag("env_sounds", true)
        hoverSounds = flag("hover_sounds", true)
        handTracking = flag("hand_tracking", true)
        maxHands = d.object(forKey: "max_hands") == nil ? 2 : (d.integer(forKey: "max_hands") == 1 ? 1 : 2)
        panelScale = CGFloat(d.object(forKey: "panel_scale") == nil ? 1.0 : min(max(d.double(forKey: "panel_scale"), 0.75), 1.5))
        volume = d.object(forKey: "volume") == nil ? 0.8 : d.double(forKey: "volume")
        textScaleIdx = d.integer(forKey: "text_scale")
        homeEnv = d.string(forKey: "home_env") ?? "desert"
        brightness = Double(UIScreen.main.brightness)
        vrShiftIdx = d.object(forKey: "vr_shift") == nil ? 2 : max(0, min(4, d.integer(forKey: "vr_shift")))
        profileName = d.string(forKey: "profile_name") ?? ""
        profilePhoto = UIImage(contentsOfFile: MenuModel.profilePhotoURL.path)
    }

    // MARK: - perfil

    static var profilePhotoURL: URL {
        return MediaModel.docs.appendingPathComponent("profile.jpg")
    }

    func setProfilePhoto(_ img: UIImage?) {
        if let img = img, let data = img.jpegData(compressionQuality: 0.85) {
            try? data.write(to: MenuModel.profilePhotoURL)
            profilePhoto = img
        } else {
            try? FileManager.default.removeItem(at: MenuModel.profilePhotoURL)
            profilePhoto = nil
        }
    }

    // MARK: - aparência

    var theme: Theme { return themeLight ? Theme.light : Theme.dark }

    /// Deslocamento de cada imagem do VR, em fração da largura da tela (positivo = aproxima as imagens).
    var vrShiftFraction: Float {
        return Float(vrShiftIdx - 2) * 0.012
    }

    var ts: CGFloat {
        let scales: [CGFloat] = [1.0, 1.15, 1.3]
        return scales[max(0, min(textScaleIdx, scales.count - 1))]
    }

    // MARK: - status do sistema

    func startMonitoring() {
        if monitoring { return }
        monitoring = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied && path.usesInterfaceType(.wifi)
            DispatchQueue.main.async { self?.wifi = ok }
        }
        pathMonitor.start(queue: DispatchQueue(label: "metulas.net"))
    }

    private func refreshStatus() {
        now = Date()
        let level = UIDevice.current.batteryLevel
        battery = level < 0 ? -1 : Int((level * 100).rounded())
        let st = UIDevice.current.batteryState
        charging = (st == .charging || st == .full)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var timeText: String { return MenuModel.timeFormatter.string(from: now) }
    var dateText: String { return MenuModel.dateFormatter.string(from: now) }

    var batteryText: String {
        if battery < 0 { return "--" }
        return charging ? "\(battery)% ⚡" : "\(battery)%"
    }

    var batterySymbol: String {
        if battery < 0 { return "battery.100" }
        if battery < 15 { return "battery.0" }
        if battery < 60 { return "battery.25" }
        return "battery.100"
    }

    var storageText: String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = v.volumeAvailableCapacityForImportantUsage,
           let total = v.volumeTotalCapacity {
            return String(format: "%.2f GB livres de %.2f GB", Double(free) / 1e9, Double(total) / 1e9)
        }
        return "indisponível"
    }

    // MARK: - navegação

    func toggleMenu() {
        if isOpen {
            isOpen = false
            stack = []
        } else {
            isOpen = true
        }
        scroll = 0
    }

    func close() {
        isOpen = false
        stack = []
        scroll = 0
    }

    func openBrowser() {
        stack = []
        scroll = 0
        isOpen = true
        if window == .browser {
            window = nil
            app?.keyboard.close()
        } else {
            window = .browser
            app?.browser.ensureTab()
        }
    }

    func show(_ page: MenuPage) {
        if stack == [page] {
            stack = []
        } else {
            stack = [page]
        }
        scroll = 0
        isOpen = true
    }

    func push(_ page: MenuPage) {
        stack.append(page)
        scroll = 0
    }

    func back() {
        if !stack.isEmpty { stack.removeLast() }
        scroll = 0
    }

    private func pushCard(_ key: String) {
        switch key {
        case "system": push(.system)
        case "personal": push(.personal)
        case "hands": push(.hands)
        case "access": push(.access)
        case "storage": push(.storage)
        case "about": push(.about)
        case "envs": push(.environments)
        case "files": push(.files)
        case "share": push(.share)
        case "notifs": push(.notifs)
        case "profile": push(.profile)
        case "privacy": push(.privacy)
        case "library": push(.library)
        default: break
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    // MARK: - ações (toque ou pinça passam pelo mesmo caminho)

    /// `rawId` é o id do alvo: "b:acao" ou "s:b:acao" (botão dentro da lista rolável).
    func activate(_ rawId: String) {
        var id = rawId
        if id.hasPrefix("s:") { id.removeFirst(2) }
        guard id.hasPrefix("b:") else { return }
        let a = String(id.dropFirst(2))

        // teclado virtual: som próprio, não passa pelo clique padrão
        if a.hasPrefix("key:") {
            app?.keyboard.press(String(a.dropFirst(4)))
            return
        }
        app?.audio.play(a.hasPrefix("web:") || a.hasPrefix("view:") ? "ui_general_keypress_01" : "sfx_press")

        if a.hasPrefix("web:") {
            app?.browser.action(String(a.dropFirst(4)))
            return
        }
        if a.hasPrefix("file:") {
            app?.media.action(String(a.dropFirst(5)))
            return
        }
        if a.hasPrefix("view:") {
            app?.media.viewerAction(String(a.dropFirst(5)))
            return
        }
        switch a {
        case "toggle": toggleMenu()
        case "quick": show(.quick)
        case "envs": show(.environments)
        case "settings": show(.settings)
        case "about": show(.about)
        case "files":
            show(.files)
            app?.media.refresh()
        case "share": show(.share)
        case "notifs": show(.notifs)
        case "apps": show(.library)
        case "browser": openBrowser()
        case "win:close":
            if window == .viewer { app?.media.stopPlayer() }
            window = nil
            app?.keyboard.close()
        case "cap:photo": app?.capture.takePhoto()
        case "cap:video": app?.capture.toggleRecording()
        case "notif:clear": app?.notifs.clear()
        case "profile:name":
            app?.keyboard.open(.name, initial: profileName)
        case "profile:photo":
            app?.picker = PickerRequest(kind: .profile)
        case "profile:remove":
            setProfilePhoto(nil)
        case "welcome":
            UserDefaults.standard.set(true, forKey: "welcomed")
            app?.showWelcome = false
        case "back": back()
        case "close":
            stack = []
            scroll = 0
        case "reset":
            app?.recenter()
            showToast("Vista centralizada")
        case "tog:camera": app?.showCamera.toggle()
        case "tog:gyro": app?.gyroEnabled.toggle()
        case "tog:night": night.toggle()
        case "tog:sounds": sounds.toggle()
        case "tog:envsounds": envSounds.toggle()
        case "tog:hover": hoverSounds.toggle()
        case "tog:hands": handTracking.toggle()
        case "tog:passthrough":
            passthrough.toggle()
            showToast(passthrough ? "Passthrough ligado" : "Passthrough desligado")
        case "tog:vr": app?.toggleVR()
        case "tog:vrflip":
            app?.vrFlip.toggle()
            showToast("Orientação do VR invertida")
        case "cast":
            showToast(app?.cast.active == true ? "Tela sendo transmitida" : "Use a Central de Controle > Espelhar tela")
        case "theme:dark": themeLight = false
        case "theme:light": themeLight = true
        case "wifi": showToast(wifi ? "Wi-Fi conectado" : "Wi-Fi desconectado")
        case "opensettings":
            if let u = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(u)
            }
        default:
            if a.hasPrefix("card:") {
                pushCard(String(a.dropFirst(5)))
            } else if a.hasPrefix("env:") {
                selectEnv(String(a.dropFirst(4)))
            } else if a.hasPrefix("cam:") {
                if let cam = HandCamera(rawValue: String(a.dropFirst(4))) {
                    app?.tracker.selectCamera(cam)
                    showToast(cam.title)
                }
            } else if a.hasPrefix("vrsep:") {
                vrShiftIdx = max(0, min(4, Int(a.dropFirst(6)) ?? 2))
            } else if a.hasPrefix("text:") {
                textScaleIdx = Int(a.dropFirst(5)) ?? 0
            } else if a.hasPrefix("hands:") {
                maxHands = Int(a.dropFirst(6)) == 1 ? 1 : 2
                showToast(maxHands == 1 ? "Rastreando 1 mão" : "Rastreando 2 mãos")
            } else if a.hasPrefix("app:") {
                openLibraryApp(String(a.dropFirst(4)))
            }
        }
    }

    /// Abre um atalho da biblioteca: app do iOS (URL scheme), página no navegador do Metulas ou favorito.
    func openLibraryApp(_ key: String) {
        var target: String?
        if key.hasPrefix("bm:") {
            let i = Int(key.dropFirst(3)) ?? -1
            let list = app?.browser.bookmarks ?? []
            if i >= 0 && i < list.count && list[i].count > 1 { target = "web:" + list[i][1] }
        } else {
            target = AppLibrary.apps.first(where: { $0.id == key })?.url
        }
        guard let t = target else { return }
        if t.hasPrefix("web:") {
            stack = []
            scroll = 0
            isOpen = true
            window = .browser
            app?.browser.newTab(String(t.dropFirst(4)))
        } else if let u = URL(string: t) {
            UIApplication.shared.open(u, options: [:]) { [weak self] ok in
                if !ok { self?.showToast("Não foi possível abrir") }
            }
        }
    }

    func selectEnv(_ id: String) {
        if loadingEnv != nil { return }
        if id == homeEnv { return }
        if !MenuModel.isAvailable(id) {
            showToast("Esse ambiente não está incluído no app")
            return
        }
        guard let r = app?.renderer else { return }
        loadingEnv = id
        r.switchEnvironment(id) { [weak self] ok, message in
            guard let self = self else { return }
            self.loadingEnv = nil
            if ok {
                self.homeEnv = id
                self.app?.audio.setEnvironment(id)
                self.showToast(MenuModel.envName(id))
            } else {
                self.showToast(message)
            }
        }
    }

    func applySlider(_ name: String, _ fraction: Double) {
        let f = min(max(fraction, 0), 1)
        switch name {
        case "sl:volume":
            volume = f
        case "sl:brightness":
            let v = max(0.05, f)
            brightness = v
            UIScreen.main.brightness = CGFloat(v)
        case "sl:seek":
            app?.media.seek(f)
        default:
            break
        }
    }

    // MARK: - rolagem e arrasto do menu (toque)

    var maxScroll: CGFloat { return max(0, contentHeight - viewportHeight) }

    func scrollBy(_ dy: CGFloat) {
        scroll = min(max(scroll + dy, 0), maxScroll)
    }

    func clampScroll() {
        let m = maxScroll
        if scroll > m { scroll = m }
    }

    func touchScroll(_ translation: CGFloat) {
        if touchScrollBase == nil { touchScrollBase = scroll }
        scroll = min(max((touchScrollBase ?? 0) - translation, 0), maxScroll)
    }

    func endTouchScroll() { touchScrollBase = nil }

    private func clampOffset(_ s: CGSize) -> CGSize {
        return CGSize(width: min(max(s.width, -140), 140), height: min(max(s.height, -320), 60))
    }

    func touchDragMenu(_ translation: CGSize) {
        if dragBase == nil { dragBase = offset }
        let b = dragBase ?? .zero
        offset = clampOffset(CGSize(width: b.width + translation.width, height: b.height + translation.height))
    }

    func endTouchDragMenu() { dragBase = nil }

    // MARK: - redimensionar o menu (arrastar pela borda, como no PC)

    private func clampScale(_ s: CGFloat) -> CGFloat { min(max(s, 0.75), 1.5) }

    func touchResizeMenu(_ translation: CGSize) {
        if resizeBase == nil { resizeBase = panelScale }
        let base = resizeBase ?? 1.0
        let d = (translation.width + translation.height) / 2   // arrastar p/ baixo-direita aumenta, p/ cima-esquerda diminui
        panelScale = clampScale(base + d / 220)
    }

    func endTouchResizeMenu() { resizeBase = nil }

    // MARK: - entrada por pinça

    func hitTest(_ p: CGPoint) -> String? {
        let viewport = frames["p:scroll"]
        var best: String?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (id, r) in frames where r.contains(p) {
            if id.hasPrefix("s:") {
                guard let v = viewport, v.contains(p) else { continue }
            }
            let area = r.width * r.height
            if area < bestArea {
                bestArea = area
                best = id
            }
        }
        return best
    }

    func setHover(_ p: CGPoint?) {
        var found: String?
        if let p = p, let id = hitTest(p) {
            let n = id.hasPrefix("s:") ? String(id.dropFirst(2)) : id
            if n.hasPrefix("b:") || n.hasPrefix("sl:") || n == "g:grab" || n == "g:resize" { found = id }
        }
        if found != hoverId {
            hoverId = found
            if found != nil { app?.audio.play("sfx_hover", hover: true) }
        }
    }

    func pressBegan(at p: CGPoint) -> PressKind {
        guard let id = hitTest(p) else { return .scene }
        let scrolled = id.hasPrefix("s:")
        let n = scrolled ? String(id.dropFirst(2)) : id
        if n.hasPrefix("b:") {
            if scrolled { return .pendingTap(id, p) }
            activate(id)
            return .blocked
        }
        if n.hasPrefix("sl:") {
            setSlider(id, at: p)
            return .slider(id)
        }
        if n == "g:grab" { return .grab }
        if n == "g:resize" { return .resize }
        if id == "p:web" { return .web(p) }
        if id == "p:scroll" { return .scroll }
        return .blocked
    }

    func pressMoved(_ kind: PressKind, to p: CGPoint, delta: CGPoint) -> PressKind {
        switch kind {
        case .slider(let id):
            setSlider(id, at: p)
        case .scroll:
            scrollBy(-delta.y)
        case .grab:
            offset = clampOffset(CGSize(width: offset.width + delta.x, height: offset.height + delta.y))
        case .resize:
            panelScale = clampScale(panelScale + (delta.x + delta.y) / 2 / 220)
        case .web(let start):
            let dx = p.x - start.x
            let dy = p.y - start.y
            if sqrt(dx * dx + dy * dy) > 16 {
                app?.browser.scrollBy(dx: -delta.x, dy: -delta.y)
                return .webScroll
            }
        case .webScroll:
            app?.browser.scrollBy(dx: -delta.x, dy: -delta.y)
        case .pendingTap(_, let start):
            let dx = p.x - start.x
            let dy = p.y - start.y
            if sqrt(dx * dx + dy * dy) > 16 {
                scrollBy(-delta.y)
                return .scroll
            }
        default:
            break
        }
        return kind
    }

    func pressEnded(_ kind: PressKind) {
        if case .pendingTap(let id, _) = kind { activate(id) }
        if case .web(let p) = kind { app?.browser.tap(atGlobal: p) }
    }

    private func setSlider(_ rawId: String, at p: CGPoint) {
        guard let r = frames[rawId], r.width > 1 else { return }
        let f = Double((p.x - r.minX) / r.width)
        applySlider(rawId.hasPrefix("s:") ? String(rawId.dropFirst(2)) : rawId, f)
    }
}

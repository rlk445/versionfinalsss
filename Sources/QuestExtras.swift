import SwiftUI
import UIKit
import GameController

// MARK: - Controles (GameController): equivalente iOS dos "Controllers" do Quest

/// Controles Bluetooth (Xbox, PlayStation, MFi). Analógico direito gira a vista,
/// botão Menu abre/fecha o menu, B volta uma página.
final class ControllersModel: ObservableObject {
    struct Info: Identifiable {
        let id: String
        let name: String
        let battery: Int?     // 0...100
        let charging: Bool
    }

    @Published private(set) var list: [Info] = []
    weak var app: AppModel? {
        didSet { refresh() }
    }

    /// Valor atual do analógico direito (-1...1). Lido pelo Renderer a cada quadro.
    private(set) var stick = SIMD2<Float>(0, 0)
    private var bound = Set<ObjectIdentifier>()

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        var out: [Info] = []
        for c in GCController.controllers() {
            bind(c)
            var level: Int? = nil
            var charging = false
            if let b = c.battery {
                if b.batteryLevel >= 0 { level = Int((b.batteryLevel * 100).rounded()) }
                charging = (b.batteryState == .charging)
            }
            let name = c.vendorName ?? c.productCategory
            out.append(Info(id: String(UInt(bitPattern: ObjectIdentifier(c).hashValue)), name: name, battery: level, charging: charging))
        }
        if GCController.controllers().isEmpty { stick = SIMD2<Float>(0, 0) }
        list = out
        app?.objectWillChange.send()
    }

    private func bind(_ c: GCController) {
        let key = ObjectIdentifier(c)
        if bound.contains(key) { return }
        guard let pad = c.extendedGamepad else { return }
        bound.insert(key)
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.stick = SIMD2<Float>(x, y)
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.app?.menu.activate("b:toggle") }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.app?.menu.activate("b:back") }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            DispatchQueue.main.async { self?.app?.recenter() }
        }
    }
}

// MARK: - Transmitir (Cast)

/// O iOS só deixa espelhar a tela pela Central de Controle; aqui o app apenas detecta se a tela está sendo transmitida/gravada.
final class CastModel: ObservableObject {
    @Published private(set) var active = false
    weak var app: AppModel?

    init() {
        active = UIScreen.main.isCaptured
        NotificationCenter.default.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.active = UIScreen.main.isCaptured
            self.app?.objectWillChange.send()
        }
    }
}

// MARK: - Biblioteca de apps (iOS não deixa listar apps instalados: atalhos fixos + favoritos do navegador)

struct LibraryApp: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let url: String      // "web:<url>" abre no navegador do Metulas
}

enum AppLibrary {
    static let apps: [LibraryApp] = [
        LibraryApp(id: "store", title: "Loja", subtitle: "App Store", icon: "bag.fill", url: "itms-apps://apps.apple.com/"),
        LibraryApp(id: "explore", title: "Explorar", subtitle: "Descobrir na web", icon: "sparkles", url: "web:https://www.youtube.com/"),
        LibraryApp(id: "people", title: "Pessoas", subtitle: "FaceTime", icon: "person.2.fill", url: "facetime://"),
        LibraryApp(id: "messages", title: "Mensagens", subtitle: "Conversar", icon: "message.fill", url: "sms:"),
        LibraryApp(id: "maps", title: "Mapas", subtitle: "Lugares e rotas", icon: "map.fill", url: "maps://"),
        LibraryApp(id: "music", title: "Música", subtitle: "Ouvir", icon: "music.note", url: "music://"),
        LibraryApp(id: "photos", title: "Fotos", subtitle: "Álbum do iPhone", icon: "photo.fill", url: "photos-redirect://"),
        LibraryApp(id: "files", title: "Arquivos (iOS)", subtitle: "App Arquivos", icon: "folder.fill", url: "shareddocuments://"),
        LibraryApp(id: "mail", title: "E-mail", subtitle: "Escrever", icon: "envelope.fill", url: "mailto:")
    ]
}

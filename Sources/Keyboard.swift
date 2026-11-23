import SwiftUI

enum KeyTarget {
    case url      // barra de endereço do navegador
    case name     // nome do perfil
    case page     // campo de texto dentro da página web
}

/// Teclado virtual (port do KB_LETTERS / KB_SYM / KB_SYM2 / KB_EMOJI do Shell.java).
/// Todas as teclas são alvos de pinça com id "b:key:<token>".
final class KeyboardModel: ObservableObject {
    @Published var isOpen = false
    @Published var page = 0          // 0 letras, 1 símbolos, 2 símbolos 2, 3 emojis
    @Published var shiftState = 0    // 0 desligado, 1 próxima letra, 2 caps lock
    @Published var text = ""
    var target: KeyTarget = .url
    weak var app: AppModel?

    private static let lettersRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["§shift", "z", "x", "c", "v", "b", "n", "m", "§bs"],
        ["§sym", "§emoji", "§space", ".", "§enter"]
    ]
    private static let urlRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["§shift", "z", "x", "c", "v", "b", "n", "m", "§bs"],
        ["§sym", "/", "§com", "§space", ".", "§enter"]
    ]
    private static let symRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["@", "#", "$", "&", "*", "(", ")", "'", "\""],
        ["§sym2", "%", "-", "+", "=", "/", ";", ":", "§bs"],
        ["§abc", "_", "§space", ",", ".", "!", "?", "§enter"]
    ]
    private static let sym2Rows: [[String]] = [
        ["~", "`", "•", "√", "π", "÷", "×", "¶", "∆", "|"],
        ["£", "¢", "€", "¥", "^", "º", "{", "}", "\\"],
        ["§sym", "[", "]", "<", ">", "—", "¿", "¡", "§bs"],
        ["§abc", "_", "§space", ",", ".", "§enter"]
    ]
    private static let emojiRows: [[String]] = [
        ["😀", "😁", "😂", "🤣", "😃", "😄", "😅", "😆", "😉", "😊"],
        ["😋", "😎", "😍", "😘", "🙂", "🤗", "🤔", "😐", "😑", "🙄"],
        ["😏", "😣", "😥", "😮", "😯", "😪", "😫", "😴", "😌", "§bs"],
        ["§abc", "😝", "😜", "§space", "👍", "❤️", "§enter"]
    ]

    var rows: [[String]] {
        switch page {
        case 1: return KeyboardModel.symRows
        case 2: return KeyboardModel.sym2Rows
        case 3: return KeyboardModel.emojiRows
        default: return target == .url ? KeyboardModel.urlRows : KeyboardModel.lettersRows
        }
    }

    func open(_ t: KeyTarget, initial: String) {
        target = t
        text = initial
        page = 0
        shiftState = 0
        isOpen = true
        app?.audio.play("ui_appear")
    }

    func close() {
        if !isOpen { return }
        isOpen = false
        app?.audio.play("ui_disappear")
    }

    func press(_ token: String) {
        guard let app = app else { return }
        switch token {
        case "§bs":
            app.audio.play("kb_backspace")
            backspace()
        case "§enter":
            app.audio.play("kb_press")
            enter()
        case "§shift":
            app.audio.play("kb_layout")
            shiftState = (shiftState + 1) % 3
        case "§space":
            app.audio.play("kb_press")
            insert(" ")
        case "§com":
            app.audio.play("kb_press")
            insert(".com")
        case "§sym":
            app.audio.play("kb_layout")
            page = 1
        case "§sym2":
            app.audio.play("kb_layout")
            page = 2
        case "§abc":
            app.audio.play("kb_layout")
            page = 0
        case "§emoji":
            app.audio.play("kb_layout")
            page = 3
        case "§hide":
            close()
        default:
            app.audio.play("kb_press")
            let c = (page == 0 && shiftState > 0) ? token.uppercased() : token
            insert(c)
            if shiftState == 1 { shiftState = 0 }
        }
    }

    private func insert(_ s: String) {
        switch target {
        case .page:
            app?.browser.insertText(s)
        case .name:
            text += s
            app?.menu.profileName = text
        case .url:
            text += s
        }
    }

    private func backspace() {
        switch target {
        case .page:
            app?.browser.backspacePage()
        case .name:
            if !text.isEmpty { text.removeLast() }
            app?.menu.profileName = text
        case .url:
            if !text.isEmpty { text.removeLast() }
        }
    }

    private func enter() {
        switch target {
        case .page:
            app?.browser.enterPage()
        case .name:
            close()
        case .url:
            let t = text
            close()
            app?.browser.go(t)
        }
    }
}

struct KeyCap: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme
    let token: String
    let label: String
    let active: Bool
    let fixed: CGFloat?

    var body: some View {
        let id = "b:key:" + token
        return Button(action: { menu.activate(id) }) {
            Text(label)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(active ? Color.white : theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: fixed, height: 42)
                .frame(maxWidth: fixed == nil ? CGFloat.infinity : nil)
                .background(RoundedRectangle(cornerRadius: 9).fill(active ? theme.accent : theme.card))
                .hoverFX(menu, id, theme, 9)
        }
        .buttonStyle(PlainButtonStyle())
        .target(id)
    }
}

struct KeyboardPanel: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var kb: KeyboardModel
    let theme: Theme

    private func label(_ t: String) -> String {
        switch t {
        case "§bs": return "⌫"
        case "§enter": return "↵"
        case "§shift": return kb.shiftState == 2 ? "⇪" : "⇧"
        case "§space": return "espaço"
        case "§com": return ".com"
        case "§sym": return "123"
        case "§sym2": return "#+="
        case "§abc": return "ABC"
        case "§emoji": return "☺︎"
        default:
            if kb.page == 0 && kb.shiftState > 0 { return t.uppercased() }
            return t
        }
    }

    private func fixedWidth(_ t: String) -> CGFloat? {
        switch t {
        case "§bs", "§shift", "§enter", "§sym", "§sym2", "§abc", "§emoji": return 46
        case "§com": return 54
        default: return nil
        }
    }

    var body: some View {
        let rows = kb.rows
        return VStack(spacing: 5) {
            HStack {
                Text(kb.target == .url ? "Endereço" : (kb.target == .name ? "Nome" : "Texto da página"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.sub)
                Spacer()
                let hideId = "b:key:§hide"
                Button(action: { menu.activate(hideId) }) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16))
                        .foregroundColor(theme.text)
                        .frame(width: 44, height: 26)
                        .background(Capsule().fill(theme.card))
                        .hoverFX(menu, hideId, theme, 13)
                }
                .buttonStyle(PlainButtonStyle())
                .target(hideId)
            }
            .padding(.horizontal, 4)
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(0..<rows[r].count, id: \.self) { i in
                        let t = rows[r][i]
                        KeyCap(menu: menu, theme: theme, token: t, label: label(t),
                               active: (t == "§shift" && kb.shiftState > 0), fixed: fixedWidth(t))
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18).fill(theme.panel.opacity(0.97)))
        .target("p:kb")
    }
}

import SwiftUI
import AVFoundation

private let sharePageColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

// MARK: - avatar

struct AvatarView: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme
    let size: CGFloat

    private var initial: String {
        let n = menu.profileName.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "M" }
        return String(n.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(tileGradient(7))
            if let img = menu.profilePhoto {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Compartilhar

struct SharePage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var capture: CaptureManager
    @ObservedObject var media: MediaModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        let recent = Array(media.gallery.prefix(6))
        return VStack(spacing: 10) {
            ActionRow(menu: menu, theme: theme, action: "b:cap:photo", title: "Tirar foto",
                      subtitle: "Contagem de 3 segundos e captura da cena", icon: "camera.fill")
            ActionRow(menu: menu, theme: theme, action: "b:cap:video",
                      title: capture.recording ? "Parar gravação" : "Gravar vídeo",
                      subtitle: capture.recording ? "Gravando " + capture.timeText : "Grava a tela do app",
                      icon: capture.recording ? "stop.circle.fill" : "record.circle")
            SectionTitle(text: "Capturas recentes", theme: theme, scale: s)
            if recent.isEmpty {
                Text("Fotos e vídeos que você tirar aparecem aqui.")
                    .font(.system(size: 13 * s))
                    .foregroundColor(theme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10)
            } else {
                LazyVGrid(columns: sharePageColumns, spacing: 8) {
                    ForEach(recent) { it in
                        ThumbTile(menu: menu, media: media, theme: theme, item: it)
                    }
                }
            }
            ActionRow(menu: menu, theme: theme, action: "b:card:files", title: "Ver tudo em Arquivos",
                      subtitle: "", icon: "folder.fill")
        }
        .onAppear { media.refresh() }
    }
}

// MARK: - Notificações

struct NotifsPage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var notifs: NotificationsModel
    let theme: Theme

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 10) {
            if notifs.items.isEmpty {
                Text("Sem notificações novas")
                    .font(.system(size: 14 * s))
                    .foregroundColor(theme.sub)
                    .padding(.top, 30)
                    .padding(.bottom, 14)
            }
            ForEach(notifs.items) { n in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: n.icon)
                        .font(.system(size: 20))
                        .foregroundColor(theme.text)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.system(size: 15 * s, weight: .semibold)).foregroundColor(theme.text)
                        Text(n.body).font(.system(size: 12 * s)).foregroundColor(theme.sub).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(NotifsPage.rel.localizedString(for: n.date, relativeTo: Date()))
                        .font(.system(size: 11 * s))
                        .foregroundColor(theme.sub)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
            }
            if !notifs.items.isEmpty {
                ActionRow(menu: menu, theme: theme, action: "b:notif:clear", title: "Limpar tudo", subtitle: "", icon: "trash")
            }
            Text("No iPhone o app só mostra os avisos dele mesmo (capturas, downloads, gravações). O iOS não permite ler as notificações de outros apps.")
                .font(.system(size: 11 * s))
                .foregroundColor(theme.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .onAppear { notifs.markRead() }
    }
}

// MARK: - Perfil

struct ProfilePage: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        let name = menu.profileName.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 10) {
            AvatarView(menu: menu, theme: theme, size: 84)
                .padding(.top, 6)
            Text(name.isEmpty ? "Usuário" : name)
                .font(.system(size: 20 * s, weight: .semibold))
                .foregroundColor(theme.text)
            ActionRow(menu: menu, theme: theme, action: "b:profile:name", title: "Editar nome",
                      subtitle: "Abre o teclado virtual", icon: "pencil")
            ActionRow(menu: menu, theme: theme, action: "b:profile:photo", title: "Alterar foto",
                      subtitle: "Escolher do álbum de fotos", icon: "photo")
            if menu.profilePhoto != nil {
                ActionRow(menu: menu, theme: theme, action: "b:profile:remove", title: "Remover foto",
                          subtitle: "", icon: "trash")
            }
        }
    }
}

// MARK: - Privacidade e navegador

struct PrivacyPage: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme

    private var cameraText: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "Permitida"
        case .denied: return "Negada"
        case .restricted: return "Restrita"
        default: return "Ainda não pedida"
        }
    }

    var body: some View {
        let s = menu.ts
        return VStack(spacing: 10) {
            SectionTitle(text: "Permissões", theme: theme, scale: s)
            InfoRow(theme: theme, scale: s, title: "Câmera (mãos)", value: cameraText)
            InfoRow(theme: theme, scale: s, title: "Rastreio de mãos", value: "Processado no aparelho")
            ActionRow(menu: menu, theme: theme, action: "b:opensettings", title: "Ajustes do iOS",
                      subtitle: "Câmera, fotos e arquivos", icon: "gearshape")
            SectionTitle(text: "Navegador", theme: theme, scale: s)
            ActionRow(menu: menu, theme: theme, action: "b:web:clear", title: "Limpar dados de navegação",
                      subtitle: "Cookies, cache e histórico", icon: "trash.fill")
        }
    }
}

// MARK: - abertura e boas-vindas

struct BootSplash: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(argb: 0xFF14161A), Color(argb: 0xFF2D3550)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26).fill(tileGradient(0)).frame(width: 92, height: 92)
                    Image(systemName: "mountain.2.fill").font(.system(size: 44)).foregroundColor(.white)
                }
                Text("Metulas")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .ignoresSafeArea()
    }
}

struct WelcomeCard: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme

    var body: some View {
        let id = "b:welcome"
        return ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Bem-vindo ao Metulas")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(theme.text)
                Text("Pince com o polegar e o indicador na frente da câmera para clicar e arrastar. O botão redondo abre o menu. Tudo também funciona por toque.")
                    .font(.system(size: 14))
                    .foregroundColor(theme.sub)
                    .multilineTextAlignment(.center)
                Button(action: { menu.activate(id) }) {
                    Text("Continuar")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent))
                        .hoverFX(menu, id, theme, 14)
                }
                .buttonStyle(PlainButtonStyle())
                .target(id)
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(RoundedRectangle(cornerRadius: 24).fill(theme.panel))
        }
    }
}

// MARK: - Apps (biblioteca)

struct LibraryPage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var browser: BrowserModel
    let theme: Theme

    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let s = menu.ts
        let marks = browser.bookmarks
        return VStack(spacing: 10) {
            SectionTitle(text: "Apps do iPhone", theme: theme, scale: s)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(AppLibrary.apps) { a in
                    InfoTile(menu: menu, theme: theme, action: "b:app:" + a.id, icon: a.icon,
                             title: a.title, subtitle: a.subtitle)
                }
            }
            SectionTitle(text: "Apps da web (favoritos)", theme: theme, scale: s)
            if marks.isEmpty {
                Text("Favoritos do navegador aparecem aqui como atalhos.")
                    .font(.system(size: 13 * s))
                    .foregroundColor(theme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(Array(marks.prefix(12).enumerated()), id: \.offset) { i, m in
                        InfoTile(menu: menu, theme: theme, action: "b:app:bm:\(i)", icon: "globe",
                                 title: m.first ?? "Site", subtitle: m.count > 1 ? m[1] : "")
                    }
                }
            }
            Text("O iOS não deixa um app listar os apps instalados, por isso a biblioteca usa atalhos para os apps do sistema.")
                .font(.system(size: 11 * s))
                .foregroundColor(theme.sub)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
}

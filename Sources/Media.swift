import SwiftUI
import AVFoundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

enum MediaKind {
    case photo, video, other
}

struct MediaItem: Identifiable {
    let id: String
    let url: URL
    let kind: MediaKind
    let date: Date
    let isDownload: Bool
    let size: Int64

    var name: String { return url.lastPathComponent }
}

/// Fotos, vídeos e downloads do app (port do Media.java e da página Files do Shell.java).
/// Tudo fica em Documents/ e aparece no app Arquivos do iPhone (UIFileSharingEnabled).
final class MediaModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var thumbs: [String: UIImage] = [:]
    @Published var viewerIndex = 0
    @Published var player: AVPlayer?
    @Published var playing = false
    @Published var progress: Double = 0
    weak var app: AppModel?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var refreshing = false

    static var docs: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func dir(_ name: String) -> URL {
        let u = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var capturesDir: URL { return dir("Captures") }
    static var importedDir: URL { return dir("Imported") }
    static var downloadsDir: URL { return dir("Downloads") }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func kindOf(_ url: URL) -> MediaKind {
        let e = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(e) { return .photo }
        if ["mp4", "mov", "m4v"].contains(e) { return .video }
        return .other
    }

    /// Fotos e vídeos (para o visualizador).
    var visual: [MediaItem] { return items.filter { $0.kind != .other } }
    var gallery: [MediaItem] { return items.filter { $0.kind != .other && !$0.isDownload } }
    var downloads: [MediaItem] { return items.filter { $0.isDownload } }

    var currentItem: MediaItem? {
        let v = visual
        if viewerIndex >= 0 && viewerIndex < v.count { return v[viewerIndex] }
        return nil
    }

    // MARK: lista

    func refresh() {
        if refreshing { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var out: [MediaItem] = []
            let fm = FileManager.default
            let folders: [(URL, Bool)] = [(MediaModel.capturesDir, false), (MediaModel.importedDir, false), (MediaModel.downloadsDir, true)]
            for (dir, isDl) in folders {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                for f in files {
                    let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    out.append(MediaItem(id: f.path, url: f, kind: MediaModel.kindOf(f),
                                         date: v?.contentModificationDate ?? Date(),
                                         isDownload: isDl, size: Int64(v?.fileSize ?? 0)))
                }
            }
            out.sort { $0.date > $1.date }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.items = out
                self.refreshing = false
                self.loadThumbs(out)
            }
        }
    }

    private func loadThumbs(_ list: [MediaItem]) {
        let missing = list.filter { $0.kind != .other && thumbs[$0.id] == nil }
        if missing.isEmpty { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for it in missing {
                if let img = MediaModel.makeThumb(it) {
                    DispatchQueue.main.async { self?.thumbs[it.id] = img }
                }
            }
        }
    }

    private static func makeThumb(_ item: MediaItem) -> UIImage? {
        switch item.kind {
        case .photo:
            return loadFull(item.url, maxPixel: 360)
        case .video:
            let gen = AVAssetImageGenerator(asset: AVAsset(url: item.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 360, height: 360)
            if let cg = try? gen.copyCGImage(at: CMTime.zero, actualTime: nil) { return UIImage(cgImage: cg) }
            return nil
        case .other:
            return nil
        }
    }

    static func loadFull(_ url: URL, maxPixel: Int = 2048) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: importar do álbum de fotos

    func importPicked(_ results: [PHPickerResult]) {
        for r in results {
            let p = r.itemProvider
            var type: UTType?
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                type = UTType.movie
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                type = UTType.image
            }
            guard let t = type else { continue }
            p.loadFileRepresentation(forTypeIdentifier: t.identifier) { [weak self] url, _ in
                guard let url = url else { return }
                var ext = url.pathExtension
                if ext.isEmpty { ext = (t == UTType.movie) ? "mov" : "jpg" }
                let prefix = (t == UTType.movie) ? "VID" : "IMG"
                let name = "\(prefix)-\(MediaModel.stamp())-\(Int.random(in: 100...999)).\(ext)"
                let dest = MediaModel.importedDir.appendingPathComponent(name)
                try? FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        app?.menu.showToast("Importando…")
    }

    // MARK: ações ("b:file:<ação>")

    func action(_ a: String) {
        guard let app = app else { return }
        if a == "import" {
            app.picker = PickerRequest(kind: .media)
        } else if a == "refresh" {
            refresh()
        } else if a.hasPrefix("open:") {
            let i = Int(a.dropFirst(5)) ?? -1
            guard i >= 0 && i < items.count else { return }
            open(items[i])
        } else if a.hasPrefix("share:") {
            let i = Int(a.dropFirst(6)) ?? -1
            guard i >= 0 && i < items.count else { return }
            app.sharePayload = SharePayload(url: items[i].url)
        }
    }

    func open(_ item: MediaItem) {
        guard let app = app else { return }
        if item.kind == .other {
            app.sharePayload = SharePayload(url: item.url)
            return
        }
        let v = visual
        guard let idx = v.firstIndex(where: { $0.id == item.id }) else { return }
        viewerIndex = idx
        app.menu.stack = []
        app.menu.window = .viewer
        app.menu.isOpen = true
        prepareCurrent()
    }

    // MARK: visualizador

    func prepareCurrent() {
        stopPlayer()
        guard let it = currentItem, it.kind == .video else { return }
        let p = AVPlayer(url: it.url)
        player = p
        progress = 0
        playing = false
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self = self, let d = self.player?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            self.progress = min(1, max(0, t.seconds / d))
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: p.currentItem, queue: .main) { [weak self] _ in
            self?.player?.seek(to: CMTime.zero)
            self?.player?.pause()
            self?.playing = false
        }
    }

    func stopPlayer() {
        if let t = timeObserver { player?.removeTimeObserver(t) }
        timeObserver = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        player?.pause()
        player = nil
        playing = false
        progress = 0
    }

    func closeViewer() {
        stopPlayer()
        app?.menu.window = nil
    }

    func step(_ d: Int) {
        let n = visual.count
        if n == 0 { return }
        viewerIndex = (viewerIndex + d + n) % n
        prepareCurrent()
    }

    func togglePlay() {
        guard let p = player else { return }
        if playing {
            p.pause()
            playing = false
        } else {
            p.play()
            playing = true
        }
    }

    func seek(_ f: Double) {
        guard let p = player, let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        progress = f
        p.seek(to: CMTime(seconds: d * f, preferredTimescale: 600), toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
    }

    func deleteCurrent() {
        guard let it = currentItem else { return }
        stopPlayer()
        try? FileManager.default.removeItem(at: it.url)
        thumbs.removeValue(forKey: it.id)
        items.removeAll(where: { $0.id == it.id })
        app?.menu.showToast("Arquivo excluído")
        if visual.isEmpty {
            app?.menu.window = nil
        } else {
            viewerIndex = min(viewerIndex, visual.count - 1)
            prepareCurrent()
        }
    }

    func viewerAction(_ a: String) {
        switch a {
        case "prev": step(-1)
        case "next": step(1)
        case "play": togglePlay()
        case "delete": deleteCurrent()
        case "share":
            if let it = currentItem { app?.sharePayload = SharePayload(url: it.url) }
        default: break
        }
    }
}

// MARK: - vistas do visualizador

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { return AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { return layer as! AVPlayerLayer }
}

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.player = player
    }
}

struct AsyncPhoto: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let i = image {
                Image(uiImage: i).resizable().scaledToFit()
            } else {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .task(id: url) {
            image = nil
            let u = url
            let img = await Task.detached(priority: .userInitiated) { MediaModel.loadFull(u) }.value
            image = img
        }
    }
}

struct SeekBar: View {
    @ObservedObject var menu: MenuModel
    let theme: Theme
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: 8)
                Capsule().fill(theme.accent).frame(width: max(8, g.size.width * CGFloat(value)), height: 8)
                Circle().fill(Color.white).frame(width: 20, height: 20)
                    .offset(x: max(0, min(g.size.width - 20, g.size.width * CGFloat(value) - 10)))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    menu.applySlider("sl:seek", Double(v.location.x / max(g.size.width, 1)))
                }
            )
        }
        .frame(height: 30)
        .target("sl:seek")
    }
}

struct ViewerWindow: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var media: MediaModel
    let theme: Theme

    private func roundBtn(_ id: String, _ icon: String) -> some View {
        Button(action: { menu.activate(id) }) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.text)
                .frame(width: 38, height: 38)
                .background(Circle().fill(theme.card))
                .overlay(Circle().fill(menu.hoverId == id ? theme.hover : Color.clear))
        }
        .buttonStyle(PlainButtonStyle())
        .target(id)
    }

    var body: some View {
        let item = media.currentItem
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(item?.name ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                roundBtn("b:view:share", "square.and.arrow.up")
                roundBtn("b:view:delete", "trash")
                roundBtn("b:win:close", "xmark")
            }
            .padding(.horizontal, 10)
            ZStack {
                if let it = item {
                    if it.kind == .video, let p = media.player {
                        VideoPlayerView(player: p)
                    } else if it.kind == .photo {
                        AsyncPhoto(url: it.url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 8)
            HStack(spacing: 8) {
                roundBtn("b:view:prev", "chevron.left")
                if item?.kind == .video {
                    roundBtn("b:view:play", media.playing ? "pause.fill" : "play.fill")
                    SeekBar(menu: menu, theme: theme, value: media.progress)
                } else {
                    Spacer()
                    Text("\(media.viewerIndex + 1) / \(media.visual.count)")
                        .font(.system(size: 13))
                        .foregroundColor(theme.sub)
                    Spacer()
                }
                roundBtn("b:view:next", "chevron.right")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .padding(.top, 10)
        .background(RoundedRectangle(cornerRadius: 24).fill(theme.panel.opacity(0.97)))
        .target("p:viewer")
    }
}

// MARK: - páginas de menu: Arquivos

private let threeColumns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

struct ThumbTile: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var media: MediaModel
    let theme: Theme
    let item: MediaItem

    var body: some View {
        let idx = media.items.firstIndex(where: { $0.id == item.id }) ?? 0
        let id = "s:b:file:open:\(idx)"
        return Button(action: { menu.activate(id) }) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(theme.card)
                if let t = media.thumbs[item.id] {
                    Image(uiImage: t).resizable().scaledToFill()
                }
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .hoverFX(menu, id, theme, 10)
        }
        .buttonStyle(PlainButtonStyle())
        .target(id)
    }
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}

struct FilesPage: View {
    @ObservedObject var menu: MenuModel
    @ObservedObject var media: MediaModel
    let theme: Theme

    var body: some View {
        let s = menu.ts
        let gal = media.gallery
        let dls = media.downloads
        return VStack(spacing: 10) {
            ActionRow(menu: menu, theme: theme, action: "b:file:import", title: "Importar fotos e vídeos",
                      subtitle: "Do álbum de fotos do iPhone", icon: "square.and.arrow.down")
            SectionTitle(text: "Capturas e importados", theme: theme, scale: s)
            if gal.isEmpty {
                Text("Fotos e vídeos que você capturar aparecem aqui.")
                    .font(.system(size: 13 * s))
                    .foregroundColor(theme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(columns: threeColumns, spacing: 8) {
                    ForEach(gal) { it in
                        ThumbTile(menu: menu, media: media, theme: theme, item: it)
                    }
                }
            }
            SectionTitle(text: "Downloads", theme: theme, scale: s)
            if dls.isEmpty {
                Text("Nenhum download ainda")
                    .font(.system(size: 13 * s))
                    .foregroundColor(theme.sub)
                    .padding(.vertical, 8)
            }
            ForEach(dls) { it in
                downloadRow(it, s)
            }
            ActionRow(menu: menu, theme: theme, action: "b:file:refresh", title: "Atualizar lista",
                      subtitle: "Os arquivos ficam em Arquivos > Metulas", icon: "arrow.clockwise")
        }
        .onAppear { media.refresh() }
    }

    private func downloadRow(_ it: MediaItem, _ s: CGFloat) -> some View {
        let idx = media.items.firstIndex(where: { $0.id == it.id }) ?? 0
        let id = "s:b:file:open:\(idx)"
        let icon = it.kind == .photo ? "photo" : (it.kind == .video ? "film" : "doc.fill")
        return Button(action: { menu.activate(id) }) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(theme.text).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.name).font(.system(size: 14 * s, weight: .medium)).foregroundColor(theme.text).lineLimit(1)
                    Text(formatBytes(it.size)).font(.system(size: 12 * s)).foregroundColor(theme.sub)
                }
                Spacer(minLength: 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(theme.card))
            .hoverFX(menu, id, theme)
        }
        .buttonStyle(PlainButtonStyle())
        .target(id)
    }
}

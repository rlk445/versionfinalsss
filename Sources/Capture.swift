import SwiftUI
import ReplayKit
import PhotosUI

// MARK: - notificações (dentro do app)

struct AppNotification: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let icon: String
    let date: Date
}

/// O iOS não deixa um app ler notificações de outros apps (no Quest o NotifListener fazia isso).
/// Aqui a lista guarda os avisos do próprio Metulas: capturas, downloads, gravações.
final class NotificationsModel: ObservableObject {
    @Published var items: [AppNotification] = []
    @Published var unread = 0
    weak var app: AppModel?

    func post(title: String, body: String, icon: String) {
        items.insert(AppNotification(title: title, body: body, icon: icon, date: Date()), at: 0)
        if items.count > 50 { items = Array(items.prefix(50)) }
        unread += 1
        app?.audio.play("oc_notif_toast")
        app?.menu.showToast(title)
    }

    func clear() {
        items.removeAll()
        unread = 0
    }

    func markRead() { unread = 0 }
}

// MARK: - capturas (foto e vídeo)

final class CaptureManager: ObservableObject {
    @Published var countdown: Int?
    @Published var recording = false
    @Published var seconds = 0
    weak var app: AppModel?
    private var timer: Timer?
    private var busy = false

    /// Contagem regressiva de 3 segundos, como no Shell.java.
    private func startCountdown(_ done: @escaping () -> Void) {
        if busy { return }
        busy = true
        countdown = 3
        app?.audio.play("camera_focus")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let n = (self.countdown ?? 1) - 1
            if n <= 0 {
                t.invalidate()
                self.countdown = nil
                self.busy = false
                done()
            } else {
                self.countdown = n
                self.app?.audio.play("Effect_Tick")
            }
        }
    }

    func takePhoto() {
        guard let app = app else { return }
        app.menu.close()
        startCountdown { [weak self] in
            guard let self = self, let app = self.app else { return }
            app.renderer?.requestSnapshot { image in
                guard let image = image, let data = image.jpegData(compressionQuality: 0.92) else {
                    app.menu.showToast("Não foi possível tirar a foto")
                    return
                }
                let url = MediaModel.capturesDir.appendingPathComponent("IMG-\(MediaModel.stamp()).jpg")
                do {
                    try data.write(to: url)
                    app.audio.play("camera_click")
                    app.media.refresh()
                    app.notifs.post(title: "Foto salva", body: url.lastPathComponent, icon: "camera.fill")
                } catch {
                    app.menu.showToast("Falha ao salvar a foto")
                }
            }
        }
    }

    func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            app?.menu.close()
            startCountdown { [weak self] in self?.beginRecording() }
        }
    }

    private func beginRecording() {
        let rec = RPScreenRecorder.shared()
        guard rec.isAvailable else {
            app?.menu.showToast("Gravação de tela indisponível")
            return
        }
        rec.isMicrophoneEnabled = false
        rec.startRecording { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let e = error {
                    self.app?.menu.showToast("Gravação cancelada: " + e.localizedDescription)
                    return
                }
                self.recording = true
                self.seconds = 0
                self.app?.audio.play("VideoRecord")
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.seconds += 1
                }
            }
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        let url = MediaModel.capturesDir.appendingPathComponent("VID-\(MediaModel.stamp()).mp4")
        RPScreenRecorder.shared().stopRecording(withOutput: url) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recording = false
                self.app?.audio.play("VideoStop")
                if let e = error {
                    self.app?.menu.showToast("Falha ao salvar o vídeo: " + e.localizedDescription)
                } else {
                    self.app?.media.refresh()
                    self.app?.notifs.post(title: "Vídeo salvo", body: url.lastPathComponent, icon: "video.fill")
                }
            }
        }
    }

    var timeText: String {
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - folhas do sistema (compartilhar e escolher do álbum)

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        return UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct PickerRequest: Identifiable {
    enum Kind { case media, profile }
    let id = UUID()
    let kind: Kind
}

struct PickerView: UIViewControllerRepresentable {
    let request: PickerRequest
    let app: AppModel
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        if request.kind == .profile {
            cfg.filter = .images
            cfg.selectionLimit = 1
        } else {
            cfg.filter = .any(of: [.images, .videos])
            cfg.selectionLimit = 0
        }
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PickerView

        init(_ p: PickerView) { parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let kind = parent.request.kind
            let app = parent.app
            parent.onDone()
            if results.isEmpty { return }
            if kind == .profile {
                results[0].itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    if let img = obj as? UIImage {
                        DispatchQueue.main.async { app.menu.setProfilePhoto(img) }
                    }
                }
            } else {
                app.media.importPicked(results)
            }
        }
    }
}

// MARK: - contagem regressiva e indicador de gravação

struct CaptureOverlay: View {
    @ObservedObject var capture: CaptureManager

    var body: some View {
        ZStack {
            if let n = capture.countdown {
                Text("\(n)")
                    .font(.system(size: 120, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.6), radius: 8)
                    .transition(.opacity)
            }
            if capture.recording {
                VStack {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text(capture.timeText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.top, 54)
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }
}

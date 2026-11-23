import AVFoundation
import UIKit
import MediaPipeTasksVision

/// Largura/altura do quadro da câmera já girado para a orientação da tela
/// (retrato: 480x640 = 0.75; paisagem do modo VR: 640x480 = 1.333).
var cameraAspect: Float = 0.75

/// Câmeras que podem ser usadas no rastreamento das mãos.
enum HandCamera: String, CaseIterable {
    case backWide, backUltra, backTele, front

    var title: String {
        switch self {
        case .backWide: return "Traseira principal (1x)"
        case .backUltra: return "Traseira ultra-angular (0,5x)"
        case .backTele: return "Traseira teleobjetiva"
        case .front: return "Frontal (selfie)"
        }
    }

    var detail: String {
        switch self {
        case .backWide: return "Recomendada para o VR Box"
        case .backUltra: return "Campo de visão maior: pega a mão mais perto do rosto"
        case .backTele: return "Campo de visão estreito, só para mãos mais afastadas"
        case .front: return "Usada no modo normal (retrato)"
        }
    }

    var position: AVCaptureDevice.Position {
        return self == .front ? .front : .back
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .backUltra: return .builtInUltraWideCamera
        case .backTele: return .builtInTelephotoCamera
        default: return .builtInWideAngleCamera
        }
    }

    func device() -> AVCaptureDevice? {
        return AVCaptureDevice.default(deviceType, for: .video, position: position)
    }

    /// Só lista as câmeras que existem neste aparelho.
    static var available: [HandCamera] {
        return HandCamera.allCases.filter { $0.device() != nil }
    }
}

struct TrackedHand {
    let label: String            // "Left" ou "Right" (câmera frontal espelhada)
    let points: [SIMD3<Float>]   // 21 pontos: x,y em 0...1 da imagem, z relativo ao pulso
    let pinching: Bool
    let pinchPoint: SIMD2<Float> // ponto médio entre polegar e indicador (0...1)
}

final class HandTracker: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "iniciando câmera…"
    @Published var camera: HandCamera

    private let queue = DispatchQueue(label: "metulas.camera")
    private let lock = NSLock()
    private var landmarker: HandLandmarker?
    private var lastTimestamp = 0
    private var latest: [TrackedHand] = []
    private var latestTime: CFTimeInterval = 0
    private var smoothed: [String: [SIMD3<Float>]] = [:]
    private var pinchState: [String: Bool] = [:]
    private var configured = false
    private var videoOutput: AVCaptureVideoDataOutput?
    private var activeCamera: HandCamera
    private var orientation: UIInterfaceOrientation = .portrait
    /// Ligado/desligado pelo menu (Mãos e Controles).
    var handsEnabled = true

    override init() {
        let saved = UserDefaults.standard.string(forKey: "hand_camera") ?? HandCamera.front.rawValue
        var cam = HandCamera(rawValue: saved) ?? .front
        if cam.device() == nil { cam = .front }
        camera = cam
        activeCamera = cam
        super.init()
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.setStatus("sem permissão de câmera (Ajustes > Metulas)")
                return
            }
            self.queue.async { self.configure() }
        }
    }

    func currentHands() -> [TrackedHand] {
        lock.lock()
        defer { lock.unlock() }
        if !handsEnabled { return [] }
        if CACurrentMediaTime() - latestTime > 0.4 { return [] }
        return latest
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    private func configure() {
        if configured { return }
        guard let modelPath = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            setStatus("modelo hand_landmarker.task ausente")
            return
        }
        do {
            let options = HandLandmarkerOptions()
            options.baseOptions.modelAssetPath = modelPath
            options.runningMode = .liveStream
            options.numHands = 2
            options.minHandDetectionConfidence = 0.5
            options.minHandPresenceConfidence = 0.5
            options.minTrackingConfidence = 0.5
            options.handLandmarkerLiveStreamDelegate = self
            landmarker = try HandLandmarker(options: options)
        } catch {
            setStatus("erro no MediaPipe: \(error.localizedDescription)")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let device = activeCamera.device() ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            setStatus("câmera indisponível")
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            setStatus("não foi possível ler a câmera")
            return
        }
        session.addOutput(output)
        videoOutput = output

        session.commitConfiguration()
        configured = true
        applyConnectionSettings()
        session.startRunning()
        setStatus("mostre as mãos para a câmera")
    }

    // MARK: - escolha da câmera e orientação

    /// Troca a câmera do rastreamento (e do passthrough) e guarda a escolha.
    func selectCamera(_ cam: HandCamera) {
        UserDefaults.standard.set(cam.rawValue, forKey: "hand_camera")
        DispatchQueue.main.async { self.camera = cam }
        queue.async {
            self.activeCamera = cam
            guard self.configured else { return }
            guard let device = cam.device(), let input = try? AVCaptureDeviceInput(device: device) else {
                self.setStatus("essa câmera não existe neste aparelho")
                return
            }
            self.session.beginConfiguration()
            for old in self.session.inputs { self.session.removeInput(old) }
            if self.session.canAddInput(input) { self.session.addInput(input) }
            self.session.commitConfiguration()
            self.lock.lock()
            self.latest = []
            self.lock.unlock()
            self.smoothed.removeAll()
            self.pinchState.removeAll()
            self.applyConnectionSettings()
            self.setStatus("câmera: \(cam.title)")
        }
    }

    /// Chamado pelo Renderer a cada quadro com a orientação atual da interface.
    func setInterfaceOrientation(_ o: UIInterfaceOrientation) {
        if o == orientation { return }
        orientation = o
        cameraAspect = o.isLandscape ? 4.0 / 3.0 : 0.75
        queue.async { self.applyConnectionSettings() }
    }

    /// Gira e espelha o vídeo que vai para o MediaPipe: a imagem chega "em pé" na orientação da tela.
    private func applyConnectionSettings() {
        guard let conn = videoOutput?.connection(with: .video) else { return }
        let o = orientation
        if #available(iOS 17.0, *) {
            var angle: CGFloat = 90
            switch o {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        } else if conn.isVideoOrientationSupported {
            switch o {
            case .landscapeRight: conn.videoOrientation = .landscapeRight
            case .landscapeLeft: conn.videoOrientation = .landscapeLeft
            case .portraitUpsideDown: conn.videoOrientation = .portraitUpsideDown
            default: conn.videoOrientation = .portrait
            }
        }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (activeCamera == .front)
        }
    }

    // MARK: - análise dos pontos

    private func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let dx = (a.x - b.x) * cameraAspect
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    fileprivate func process(_ result: HandLandmarkerResult) {
        var hands: [TrackedHand] = []
        for (i, lms) in result.landmarks.enumerated() {
            if lms.count < 21 { continue }
            var label = "Right"
            if i < result.handedness.count, let cat = result.handedness[i].first, let n = cat.categoryName {
                label = n
            }
            var pts = lms.map { SIMD3<Float>($0.x, $0.y, $0.z) }
            if let prev = smoothed[label], prev.count == pts.count {
                for k in 0..<pts.count {
                    pts[k] = prev[k] + (pts[k] - prev[k]) * 0.6
                }
            }
            smoothed[label] = pts

            let size = max(dist(pts[0], pts[9]), 0.001)
            let ratio = dist(pts[4], pts[8]) / size
            let wasPinching = pinchState[label] ?? false
            let pinching = wasPinching ? (ratio < 0.34) : (ratio < 0.22)
            pinchState[label] = pinching
            let mid = SIMD2<Float>((pts[4].x + pts[8].x) * 0.5, (pts[4].y + pts[8].y) * 0.5)
            hands.append(TrackedHand(label: label, points: pts, pinching: pinching, pinchPoint: mid))
        }
        if hands.isEmpty {
            smoothed.removeAll()
            pinchState.removeAll()
        }
        lock.lock()
        latest = hands
        latestTime = CACurrentMediaTime()
        lock.unlock()
        let count = hands.count
        DispatchQueue.main.async {
            self.status = count == 0 ? "nenhuma mão detectada" : "mãos: \(count)  •  pince e arraste para girar"
        }
    }
}

extension HandTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let landmarker = landmarker else { return }
        let ts = Int(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        guard ts > lastTimestamp else { return }
        lastTimestamp = ts
        do {
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .up)
            try landmarker.detectAsync(image: image, timestampInMilliseconds: ts)
        } catch {
            // quadro descartado
        }
    }
}

extension HandTracker: HandLandmarkerLiveStreamDelegate {
    func handLandmarker(_ handLandmarker: HandLandmarker,
                        didFinishDetection result: HandLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        guard let result = result else { return }
        queue.async { self.process(result) }
    }
}

import SwiftUI
import AVFoundation

final class PreviewView: UIView {
    override class var layerClass: AnyClass { return AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let o = window?.windowScene?.interfaceOrientation ?? .portrait
        if let c = previewLayer.connection {
            if #available(iOS 17.0, *) {
                var angle: CGFloat = 90
                switch o {
                case .landscapeRight: angle = 0
                case .landscapeLeft: angle = 180
                case .portraitUpsideDown: angle = 270
                default: angle = 90
                }
                if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            } else if c.isVideoOrientationSupported {
                switch o {
                case .landscapeRight: c.videoOrientation = .landscapeRight
                case .landscapeLeft: c.videoOrientation = .landscapeLeft
                case .portraitUpsideDown: c.videoOrientation = .portraitUpsideDown
                default: c.videoOrientation = .portrait
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

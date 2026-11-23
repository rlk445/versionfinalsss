import SwiftUI
import UIKit

/// Controla quais orientações a tela aceita: retrato no modo normal, paisagem no modo VR.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationMask
    }
}

enum OrientationControl {
    /// Muda a orientação permitida e gira a tela agora.
    static func apply(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        if #available(iOS 16.0, *) {
            scene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        } else {
            // iOS 15: o valor de UIDeviceOrientation é o oposto do da interface em paisagem
            var device: UIDeviceOrientation = .portrait
            if mask == .landscapeRight { device = .landscapeLeft }
            if mask == .landscapeLeft { device = .landscapeRight }
            UIDevice.current.setValue(device.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}

@main
struct MetulasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

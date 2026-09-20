import AlertController
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UpdateNotice.shared.startWatching()
        // Idempotent, and a no-op off Catalyst. Registered here rather than
        // lazily so a bundled helper exists before the first listing asks.
        MacLaunchAgent.shared.activate()
        // The icon's own red, and the icon itself on every alert card — light
        // and dark, rendered by Scripts/make-app-mark.swift.
        AlertControllerConfiguration.accentColor = UIColor(named: "AccentColor") ?? .systemRed
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

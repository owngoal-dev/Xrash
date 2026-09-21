import AlertController
import UIKit
import UserNotifications

final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UpdateNotice.shared.startWatching()
        // The delegate has to be in place before this method returns, or a
        // notification tapped on a cold launch is delivered to nobody.
        UNUserNotificationCenter.current().delegate = self
        CrashNotice.shared.start()
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
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    // MARK: Notifications

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(CrashNotice.shared.presentationOptions(for: Self.reportID(in: notification)))
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Self.reportID(in: response.notification).map { CrashNotice.shared.show(reportID: $0) }
        completionHandler()
    }

    private static func reportID(in notification: UNNotification) -> String? {
        notification.request.content.userInfo[CrashNotice.reportIDKey] as? String
    }
}

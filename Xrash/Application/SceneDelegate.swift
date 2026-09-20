import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Self.waitForFirstListing()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ReportsSplitViewController()
        window.makeKeyAndVisible()
        self.window = window
        self.scene(scene, openURLContexts: connectionOptions.urlContexts)
    }

    private static var hasWaited = false

    /// The launch screen stays up for the first listing, once, on a cold
    /// launch: a list that is there when the app appears is worth more than
    /// appearing a moment sooner with a spinner that turns into rows. Past the
    /// budget the list goes up with its loading state.
    private static func waitForFirstListing() {
        guard !hasWaited else { return }
        hasWaited = true
        LoadBudget.wait(LoadBudget.launch) { await AppEnvironment.shared.library.refresh() }
    }

    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard !contexts.isEmpty else { return }
        ExternalFileRouter.open(contexts.map(\.url), from: window?.rootViewController)
    }

    func sceneDidBecomeActive(_: UIScene) {
        UpdateNotice.shared.presentIfPending(in: window)
        // The helper may have been turned off in System Settings while the app
        // was in the background.
        MacLaunchAgent.shared.refresh()
    }
}

import AlertController
import UIKit

/// The package replaced or removed the running copy (`ExecutableWatch`): old
/// code, against a daemon the package's postinst has already restarted. The
/// watch cannot tell an update from a removal, so the wording covers both.
@MainActor
final class UpdateNotice {
    static let shared = UpdateNotice()

    private var isPending = false

    private init() {}

    func startWatching() {
        ExecutableWatch.start { [weak self] in
            self?.isPending = true
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.first { $0.activationState == .foregroundActive }?.windows.first(where: \.isKeyWindow)
            self?.presentIfPending(in: window)
        }
    }

    func presentIfPending(in window: UIWindow?) {
        guard isPending, var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        isPending = false
        let alert = AlertViewController(
            title: String.LocalizationValue("Xrash Was Updated or Removed"),
            message: String.LocalizationValue("This copy is no longer installed. Quit it and open Xrash again to continue.")
        ) { context in
            context.addAction(title: String.LocalizationValue("Later")) {
                context.dispose()
            }
            context.addAction(title: String.LocalizationValue("Quit"), attribute: .accent) {
                context.dispose { QuietExit.run() }
            }
        }
        presenter.present(alert, animated: true)
    }
}

import AlertController
import SPIndicator
import UIKit
import XrashBundle

/// One line of feedback, nothing to press.
///
// ponytail: no queue and no window of its own — SPIndicator presents on the
// key window. Port Fila's Presenter if two toasts ever need to line up.
@MainActor
enum Toast {
    static func show(_ title: String) {
        SPIndicatorView(title: title, preset: .done).present(duration: 2, haptic: .success)
    }
}

/// Files handed to a share sheet. They are written under one directory with a
/// readable name — `Fila-2026-09-08-191717.crash`, never the report's own
/// `.ips.synced`, because the name is what lands in a mail attachment.
@MainActor
enum ReportShare {
    static func file(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Share", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        return url
    }

    static func file(named name: String, text: String) throws -> URL {
        try file(named: name, contents: Data(text.utf8))
    }

    /// A saved bundle, under its title rather than the id it is stored as.
    /// Every screen that shares one comes through here.
    ///
    /// A bundle carrying system state says so before it leaves: the archive
    /// names every app, package and tweak on the machine, and the person who
    /// made it a week ago should not have to remember that on the way out.
    static func present(
        _ bundle: SavedBundleStore.SavedBundle,
        from controller: UIViewController,
        source: UIView?
    ) {
        guard let systemFiles = bundle.manifest.systemFiles, !systemFiles.isEmpty else {
            return share(bundle, from: controller, source: source)
        }
        let alert = AlertViewController(
            title: String.LocalizationValue("This Report Includes System State"),
            message: String.LocalizationValue("""
            Installed apps, packages, tweaks, running processes and services are included. \
            Review them before sharing.
            """)
        ) { [weak controller] context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Share"), attribute: .accent) {
                context.dispose {
                    guard let controller else { return }
                    Self.share(bundle, from: controller, source: source)
                }
            }
        }
        controller.present(alert, animated: true)
    }

    private static func share(
        _ bundle: SavedBundleStore.SavedBundle,
        from controller: UIViewController,
        source: UIView?
    ) {
        present([AppEnvironment.shared.savedBundles.shareURL(for: bundle)], from: controller, source: source)
    }

    /// The only place a share sheet is made, so the only place it is anchored:
    /// on an iPad it is a popover, and one without a source view raises.
    /// A row that scrolled away or was reused has no window and cannot be the
    /// anchor; the presenter's own view then is, at its centre and arrowless —
    /// an arrow needs room outside the rect, and the whole view leaves none.
    static func present(_ items: [Any], from controller: UIViewController, source: UIView?) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            if let source, source.window != nil {
                popover.sourceView = source
                popover.sourceRect = source.bounds
            } else {
                let view: UIView = controller.view
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        controller.present(sheet, animated: true)
    }
}

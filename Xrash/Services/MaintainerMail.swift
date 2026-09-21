import MessageUI
import UIKit
import XrashBlame
import XrashReport

/// A mail to the person who ships a suspected package, with the report
/// attached as the `.crash` text everyone who debugs one can read.
///
/// The address is parsed in the Kit — `PackageOwner.maintainerAddress`, which
/// is where its test lives — and only the address is written to the recipient
/// field. A package that names nobody offers no mail at all, so the composer
/// is nil rather than half-addressed.
@MainActor
enum MaintainerMail {
    /// The composer, ready to present. Nil when the maintainer field holds no
    /// address worth writing to.
    static func compose(
        owner: PackageOwner,
        report: Report,
        stem: String
    ) -> MFMailComposeViewController? {
        guard let address = owner.maintainerAddress else { return nil }
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = dismisser
        composer.setToRecipients([address])
        let name = owner.name ?? owner.identifier
        composer.setSubject(
            owner.version.map { String(localized: "Crash Report: \(name) (\($0))") }
                ?? String(localized: "Crash Report: \(name)")
        )
        // A suspect is a suspect: the mail says where the package turned up,
        // not that it is to blame. The blank lines are where the sender writes.
        let appears = String(
            localized: "Your package (\(owner.identifier)) appears on the crashed stack of the attached report."
        )
        composer.setMessageBody(appears + "\n\n" + String(localized: "Additional Details:") + "\n\n", isHTML: false)
        composer.addAttachmentData(
            Data(ReportRenderer.crashText(report).utf8),
            mimeType: "text/plain",
            fileName: stem + ".crash"
        )
        return composer
    }

    /// Mail is a system app that may not be set up, and that is a sentence
    /// rather than a silent fall back to the share sheet.
    static func present(owner: PackageOwner, report: Report, stem: String, from controller: UIViewController) {
        guard MFMailComposeViewController.canSendMail() else {
            return controller.presentMessage(
                String.LocalizationValue("Unable to Send Mail"),
                message: String.LocalizationValue("No mail account is set up.")
            )
        }
        guard let composer = compose(owner: owner, report: report, stem: stem) else { return }
        controller.present(composer, animated: true)
    }

    /// `mailComposeDelegate` is weak and the composer dismisses nothing by
    /// itself; one dismisser for the app, because that is all it does.
    private static let dismisser = MailComposeDismisser()
}

private final class MailComposeDismisser: NSObject, MFMailComposeViewControllerDelegate {
    func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith _: MFMailComposeResult,
        error _: Error?
    ) {
        controller.dismiss(animated: true)
    }
}

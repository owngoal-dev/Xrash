import AlertController
import Then
import UIKit

extension UIViewController {
    /// One thing to say and one button. Alerts go through `AlertController`
    /// everywhere in this app, so they all look alike.
    func presentMessage(_ title: String.LocalizationValue, message: String.LocalizationValue) {
        let alert = AlertViewController(title: title, message: message) { context in
            context.addAction(title: String.LocalizationValue("OK"), attribute: .accent) {
                context.dispose()
            }
        }
        present(alert, animated: true)
    }

    /// A failure's own words, which are not a literal to be localised.
    func presentFailure(_ title: String.LocalizationValue, _ error: Error) {
        presentMessage(title, message: String.LocalizationValue(error.localizedDescription))
    }

    /// Every sheet this app presents, at one size, so one replacing another
    /// does not step. The *window's* width class decides, not the presenter's:
    /// a screen inside a split view's primary column is compact on an iPad
    /// whose window is not, and a sheet sized for that came out twice as wide
    /// as the one beside it.
    func presentAsFormSheet(_ viewController: UIViewController) {
        viewController.modalPresentationStyle = .formSheet
        let window = viewIfLoaded?.window?.traitCollection ?? traitCollection
        if window.horizontalSizeClass == .compact {
            viewController.sheetPresentationController?.do {
                $0.detents = [.large()]
                $0.prefersGrabberVisible = true
                $0.prefersScrollingExpandsWhenScrolledToEdge = true
                $0.prefersEdgeAttachedInCompactHeight = true
                $0.widthFollowsPreferredContentSizeWhenEdgeAttached = true
            }
        } else {
            // Fila's and Irisin's card. Set on what is presented — the
            // navigation controller — and only here: a page that sized itself
            // would resize the sheet on every push and pop.
            viewController.preferredContentSize = CGSize(width: 555, height: 555)
        }
        present(viewController, animated: true)
    }
}

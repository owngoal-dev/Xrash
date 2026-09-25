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

    /// Every sheet this app presents, sized here and nowhere else, so one
    /// replacing another does not step. The *window's* width class decides, not
    /// the presenter's: a screen inside a split view's primary column is
    /// compact on an iPad whose window is not, and a sheet sized for that came
    /// out twice as wide as the one beside it.
    ///
    /// The pages take the default size. The welcome passes the size its own
    /// original was drawn at and turns the detents off, which is what leaves it
    /// a plain page sheet on a phone — with no grabber, since it does not
    /// dismiss by hand until its work is done.
    ///
    /// A sheet presented from inside another sheet — the welcome from Settings
    /// on an iPad — takes no size at all. UIKit does not hold a nested form
    /// sheet to its preferred size: the card jumps on presentation and again on
    /// every push, so it keeps the system's own form sheet size instead.
    ///
    /// What is presented is a `SheetNavigationController`, which holds the
    /// size it opens at. A stock navigation controller adds its bar's height
    /// on every read, and the sheet followed the bar on a push that changed it.
    func presentAsFormSheet(
        _ viewController: SheetNavigationController,
        size: CGSize = CGSize(width: 555, height: 555),
        usesDetents: Bool = true,
    ) {
        viewController.modalPresentationStyle = .formSheet
        let window = viewIfLoaded?.window?.traitCollection ?? traitCollection
        if window.horizontalSizeClass == .compact, usesDetents {
            viewController.sheetPresentationController?.do {
                $0.detents = [.large()]
                $0.prefersGrabberVisible = true
                $0.prefersScrollingExpandsWhenScrolledToEdge = true
                $0.prefersEdgeAttachedInCompactHeight = true
                $0.widthFollowsPreferredContentSizeWhenEdgeAttached = true
            }
        } else if presentingViewController == nil {
            // Fila's and Irisin's card. Set on what is presented — the
            // navigation controller — and only here: a page that sized itself
            // would resize the sheet on every push and pop. A presenter that
            // is itself presented is a sheet, and this one would be nested.
            viewController.holdPreferredContentSize(size)
        }
        present(viewController, animated: true)
    }
}

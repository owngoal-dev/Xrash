import UIKit

/// The navigation controller every sheet is presented in, holding the size it
/// opened at for as long as it is on screen.
///
/// UIKit's own adds the navigation bar's height to the preferred size each
/// time it is read, and the bar is not one height: a page with a search bar
/// pinned under its title makes it taller. A form sheet follows the sum, so
/// the Symbols sheet grew by a search bar when a symbol list was pushed and
/// kept it after the pop.
final class SheetNavigationController: UINavigationController {
    private var heldSize: CGSize?

    /// Gives the sheet its size and holds it: what UIKit reports now, with the
    /// root page's bar, is what every page after it gets.
    func holdPreferredContentSize(_ size: CGSize) {
        super.preferredContentSize = size
        heldSize = super.preferredContentSize
    }

    override var preferredContentSize: CGSize {
        get { heldSize ?? super.preferredContentSize }
        set { super.preferredContentSize = newValue }
    }
}

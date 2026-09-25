import UIKit

/// One thing a row's tap menu offers, in the shape both of UIKit's surfaces
/// need it in.
///
/// A row that reads as a single VoiceOver stop hides every subview inside it,
/// the invisible button that opens the menu included, so the same things the
/// menu offers have to reach the rotor as custom actions. Keeping the built
/// `UIAction` and replaying it is not an option below iOS 16, where
/// `performWithSender(_:target:)` does not exist yet; what is kept is the
/// title and the closure, and each surface builds its own element from them.
@MainActor
struct RowMenuAction {
    let title: String
    let symbolName: String
    let run: () -> Void

    var menuElement: UIMenuElement {
        UIAction(title: title, image: UIImage(systemName: symbolName)) { _ in run() }
    }

    var accessibilityAction: UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: title) { _ in
            run()
            return true
        }
    }
}

/// Closures rather than key paths: a key path to a main-actor-isolated property
/// is an error in the Swift 6 language mode.
@MainActor
extension [RowMenuAction] {
    var menuElements: [UIMenuElement] {
        map(\.menuElement)
    }

    var accessibilityActions: [UIAccessibilityCustomAction] {
        map(\.accessibilityAction)
    }
}

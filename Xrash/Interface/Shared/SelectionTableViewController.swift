import UIKit

/// UIKit clears pushed selections on return; sheets and custom alerts also
/// need to clear them when they leave without making the table reappear.
class SelectionTableViewController: UITableViewController {
    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil,
    ) {
        if clearsSelectionOnViewWillAppear, !isEditing, isViewLoaded,
           tableView.indexPathForSelectedRow != nil
        {
            let observer = SelectionDismissalView(owner: self, presentation: viewControllerToPresent)
            viewControllerToPresent.view.addSubview(observer)
        }
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    /// Also used when an asynchronous action finishes before its progress
    /// card has appeared. A following alert or pushed page keeps the row.
    func deselectFinishedAction() {
        guard clearsSelectionOnViewWillAppear, !isEditing, isViewLoaded,
              view.window != nil, presentedViewController == nil,
              let selected = tableView.indexPathForSelectedRow else { return }
        var page: UIViewController = self
        while let parent = page.parent, !(parent is UINavigationController) {
            page = parent
        }
        if let navigation = page.navigationController, navigation.topViewController !== page {
            return
        }
        tableView.deselectRow(at: selected, animated: true)
    }
}

/// Watches the actual removal, including Done, swipe, tap-outside and
/// programmatic dismissal, without replacing a system controller's delegate.
private final class SelectionDismissalView: UIView {
    private weak var owner: SelectionTableViewController?
    private weak var presentation: UIViewController?
    private var wasVisible = false

    init(owner: SelectionTableViewController, presentation: UIViewController) {
        self.owner = owner
        self.presentation = presentation
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wasVisible = true
        } else if wasVisible {
            // UIKit clears the presentation relationship after removing the
            // view. Being covered by another full-screen sheet is not a dismissal.
            DispatchQueue.main.async { [weak owner, weak presentation] in
                guard presentation?.presentingViewController == nil else { return }
                owner?.deselectFinishedAction()
            }
        }
    }
}

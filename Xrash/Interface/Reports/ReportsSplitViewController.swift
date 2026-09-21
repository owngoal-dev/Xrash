import UIKit
import UniformTypeIdentifiers
import XrashReport

/// The shell. Wide: the report list beside the open report, and Saved, Symbols
/// and Settings as form sheets off the list's bar — two columns, never three.
/// Narrow: the four-page tab bar.
///
/// Fila's shape (`RootSplitViewController`): a third controller for `.compact`
/// is what stops UIKit merging the list into a phone's navigation stack.
final class ReportsSplitViewController: UISplitViewController {
    private let list = ReportListViewController()

    init() {
        super.init(style: .doubleColumn)
        list.openReport = { [weak self] summary in
            self?.setViewController(
                UINavigationController(rootViewController: ReportDetailViewController(reportID: summary.id)),
                for: .secondary
            )
        }
        // The process page is the secondary column's own stack, so a report
        // opened from it pushes on top and Back is the process again.
        list.openProcess = { [weak self] name in
            self?.setViewController(
                UINavigationController(rootViewController: ReportListViewController.processPage(for: name)),
                for: .secondary
            )
        }
        list.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                pageAction("heart.text.square", String(localized: "Saved")) { SavedReportsViewController() },
                pageAction("function", String(localized: "Symbols")) { SymbolsViewController() },
                pageAction("gearshape", String(localized: "Settings")) { SettingsViewController() },
            ])
        )
        list.navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "More")
        let primary = UINavigationController(rootViewController: list)
        // Opaque and the standard grey: left to itself the column is a tinted
        // material, and this app's tint is red — the list came out pink.
        primary.view.backgroundColor = .systemGroupedBackground
        list.tableView.backgroundColor = .systemGroupedBackground
        setViewController(primary, for: .primary)
        setViewController(placeholder(), for: .secondary)
        // ponytail: the tab bar keeps a report list of its own, so a report
        // open on one side of a width change is not open on the other. Move
        // one list between the columns, as Fila does, if that ever matters.
        setViewController(RootTabBarController(), for: .compact)
        // Both columns from the start, so an iPad launch does not open on an
        // empty detail pane with the list hidden behind a button.
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        // The list's bar already carries five items, and a list that can be
        // hidden leaves a detail column with no way to pick another report.
        displayModeButtonVisibility = .never
        presentsWithGesture = false
        minimumPrimaryColumnWidth = 320
        maximumPrimaryColumnWidth = 400
        preferredPrimaryColumnWidthFraction = 0.4
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // What shows around and through the sidebar: the same grouped
        // background the detail column has, not the split view's white.
        view.backgroundColor = .systemGroupedBackground
        // One interaction on the root, so a file dropped anywhere in the
        // window — either column, the placeholder, the gap between them —
        // takes the same route a file opened from Finder or Files takes.
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    /// A report brought up from outside the list — a tapped notification. The
    /// compact column keeps a list of its own, so which stack the report joins
    /// is whichever one is on screen.
    func showReport(id: String) {
        // A form sheet over the window would otherwise hide what was tapped.
        presentedViewController?.dismiss(animated: false)
        let detail = ReportDetailViewController(reportID: id)
        guard isCollapsed, let tabs = viewController(for: .compact) as? UITabBarController else {
            return setViewController(UINavigationController(rootViewController: detail), for: .secondary)
        }
        tabs.selectedIndex = 0
        (tabs.selectedViewController as? UINavigationController)?.pushViewController(detail, animated: true)
    }

    /// Back to "Select a Report" — what a deleted detail leaves behind. A
    /// detail opened from a process page goes back to that page instead: the
    /// column still has a list to show, and it is the one that was in use.
    func showPlaceholder() {
        if let navigation = viewController(for: .secondary) as? UINavigationController,
           navigation.viewControllers.count > 1
        {
            navigation.popViewController(animated: true)
            return
        }
        setViewController(placeholder(), for: .secondary)
    }

    private func placeholder() -> UIViewController {
        UINavigationController(rootViewController: ReportPlaceholderViewController())
    }

    /// A page that is a tab on a phone is a form sheet here.
    private func pageAction(
        _ symbol: String,
        _ title: String,
        _ make: @escaping () -> UIViewController
    ) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
            guard let self else { return }
            let page = make()
            let navigation = UINavigationController(rootViewController: page)
            page.navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "xmark"),
                primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) }
            )
            page.navigationItem.leftBarButtonItem?.accessibilityLabel = String(localized: "Close")
            presentAsFormSheet(navigation)
        }
    }
}

/// Files dragged onto the window. Finder hands over the item where it lies
/// and Files hands over a security-scoped copy of the same shape, so both end
/// in `ExternalFileRouter.open`, which brackets the access either way.
extension ReportsSplitViewController: UIDropInteractionDelegate {
    func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        // Files only: a dragged link is a URL too, and refusing it here is
        // what stops the pointer promising a copy nothing would come of.
        session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier])
    }

    func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_: UIDropInteraction, performDrop session: UIDropSession) {
        _ = session.loadObjects(ofClass: URL.self) { [weak self] urls in
            // A dragged link is a URL too, and nothing here can open one.
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return }
            ExternalFileRouter.open(files, from: self)
        }
    }
}

private final class ReportPlaceholderViewController: UIViewController {
    override func loadView() {
        let view = EmptyStateView(.message(
            symbolName: "doc.text.magnifyingglass",
            title: String(localized: "Select a Report"),
            description: String(localized: "Choose a report on the left to see what happened."),
            actionTitle: nil
        ))
        view.backgroundColor = .systemGroupedBackground
        self.view = view
    }
}

import UIKit
import XrashReport

/// Four pages, so a tab bar — in a narrow window only. A wide one is
/// `ReportsSplitViewController`, which hosts this as its compact column.
final class RootTabBarController: UITabBarController {
    init() {
        super.init(nibName: nil, bundle: nil)
        let reports = ReportListViewController()
        reports.openReport = { [weak reports] summary in
            reports?.navigationController?.pushViewController(
                ReportDetailViewController(reportID: summary.id),
                animated: true,
            )
        }
        reports.openProcess = { [weak reports] name in
            reports?.navigationController?.pushViewController(
                ReportListViewController.processPage(for: name),
                animated: true,
            )
        }
        viewControllers = [
            Self.page(reports, title: String(localized: "Reports"), symbol: "exclamationmark.triangle"),
            Self.page(SavedReportsViewController(), title: String(localized: "Saved"), symbol: "heart.text.square"),
            Self.page(SymbolsViewController(), title: String(localized: "Symbols"), symbol: "function"),
            Self.page(SettingsViewController(), title: String(localized: "Settings"), symbol: "gearshape"),
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The Reports tab's stack; its root is the list.
    private var reportsNavigation: UINavigationController? {
        viewControllers?.first as? UINavigationController
    }

    /// The Reports tab, with these screens over its list: what the wide
    /// layout's secondary column had open when the window narrowed.
    func showReportScreens(_ screens: [UIViewController]) {
        guard let navigation = reportsNavigation, let list = navigation.viewControllers.first else { return }
        // A selection left running would keep the tab bar hidden under them.
        if list.isEditing {
            list.setEditing(false, animated: false)
        }
        navigation.setViewControllers([list] + screens, animated: false)
        selectedIndex = 0
    }

    /// Everything pushed over the Reports list, taken off it, for the wide
    /// layout's secondary column. Empty when the list is all there is.
    func takeReportScreens() -> [UIViewController] {
        guard let navigation = reportsNavigation, let list = navigation.viewControllers.first else { return [] }
        let screens = Array(navigation.viewControllers.dropFirst())
        if !screens.isEmpty {
            navigation.setViewControllers([list], animated: false)
        }
        return screens
    }

    /// Every tab opens under a large title; the screens pushed onto it opt
    /// out one by one.
    private static func page(_ root: UIViewController, title: String, symbol: String) -> UIViewController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: symbol), selectedImage: nil)
        navigation.navigationBar.prefersLargeTitles = true
        root.navigationItem.largeTitleDisplayMode = .always
        return navigation
    }
}

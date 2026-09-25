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

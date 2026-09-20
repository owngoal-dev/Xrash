import Combine
import UIKit
import XrashReport

/// The other reports that are the same bug, reusing the list's own row so a
/// crash looks the same wherever it is listed.
final class RelatedReportsViewController: UITableViewController, UISearchResultsUpdating {
    private let summaries: [ReportSummary]
    private let library: ReportLibrary
    private var dataSource: SectionedTableDataSource<Int, String>!
    private var shown = [ReportSummary]()
    private var searchText = ""

    init(summaries: [ReportSummary], library: ReportLibrary = AppEnvironment.shared.library) {
        self.summaries = summaries
        self.library = library
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Similar Reports")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Reports")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(ReportRowCell.self, forCellReuseIdentifier: ReportRowCell.reuseIdentifier)
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ReportRowCell.reuseIdentifier,
                for: indexPath
            )
            if let summary = self?.summaries.first(where: { $0.id == id }) {
                (cell as? ReportRowCell)?.configure(with: ReportRowState(
                    summary: summary,
                    isUnread: self?.library.unreadIDs.value.contains(id) ?? false,
                    reason: nil
                ))
            }
            return cell
        }
        dataSource.header = { [weak self] _ in
            String(
                inflecting: "^[\(self?.shown.count ?? 0) report](inflect: true) with the same signature"
            )
        }
        render()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text ?? ""
        render()
    }

    private func render() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = summaries.filter { summary in
            [summary.processName, summary.bundleID, summary.appVersion]
                .compactMap(\.self)
                .contains { $0.matches(needle) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        if !shown.isEmpty {
            snapshot.appendSections([0])
            snapshot.appendItems(shown.map(\.id).removingDuplicates())
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        tableView.setEmptyState(shown.isEmpty ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "No report here matches “\(needle)”."),
            actionTitle: nil
        ) : nil)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(ReportDetailViewController(reportID: id), animated: true)
    }
}

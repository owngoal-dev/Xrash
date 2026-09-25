import Combine
import UIKit
import XrashReport

/// Pick any other reports to link: the whole library, grouped by process and
/// searchable, with the ones already linked left out.
final class ReportPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let candidates: [ReportSummary]
    private let onPick: ([String]) -> Void
    private var selected = Set<String>()
    private var query = ""
    private var dataSource: UITableViewDiffableDataSource<String, String>!
    private var shown = [String: ReportSummary]()

    init(candidates: [ReportSummary], excluding excluded: Set<String>, onPick: @escaping ([String]) -> Void) {
        self.candidates = candidates.filter { !excluded.contains($0.id) }
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add Other Report")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Add"),
            primaryAction: UIAction { [weak self] _ in self?.add() },
        )
        navigationItem.rightBarButtonItem?.isEnabled = false

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search by process, bundle ID or kind")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(BundleReportCell.self, forCellReuseIdentifier: BundleReportCell.reuseIdentifier)
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier,
                for: indexPath,
            )
            if let self, let summary = shown[id], let cell = cell as? BundleReportCell {
                cell.configure(with: summary)
                cell.accessoryType = selected.contains(id) ? .checkmark : .none
            }
            return cell
        }
        dataSource.defaultRowAnimation = .fade
        render()
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        dataSource.snapshot().sectionIdentifiers[section]
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if selected.remove(id) == nil {
            selected.insert(id)
        }
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        render()
    }

    private func add() {
        onPick(candidates.map(\.id).filter { selected.contains($0) })
        navigationController?.popViewController(animated: true)
    }

    private func render() {
        let matches = candidates.filter { self.matches($0) }
        shown = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for process in orderedProcesses(of: matches) {
            snapshot.appendSections([process])
            snapshot.appendItems(matches.filter { $0.processName == process }.map(\.id), toSection: process)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        if !matches.isEmpty {
            tableView.setEmptyState(nil)
        } else if query.isEmpty {
            tableView.setEmptyState(.message(
                symbolName: "tray",
                title: String(localized: "No Reports"),
                description: String(localized: "There are no other reports to add."),
                actionTitle: nil,
            ))
        } else {
            tableView.setEmptyState(.message(
                symbolName: "magnifyingglass",
                title: String(localized: "No Results"),
                description: String(localized: "No other reports match “\(query)”. Try a different search."),
                actionTitle: nil,
            ))
        }
    }

    /// Case- and diacritic-insensitive, which `localizedStandardContains`
    /// already is. The kind is searchable too, so "hang" finds the hangs.
    // ponytail: the exception reason needs the report decoded, which this
    // screen deliberately does not do for the whole library. Search it once a
    // decoded reason is cached beside the summary.
    private func matches(_ summary: ReportSummary) -> Bool {
        [
            summary.processName,
            summary.fileName,
            summary.bundleID,
            ReportFormat.kindLabel(summary.kind),
        ].contains { $0?.matches(query) == true }
    }

    /// Processes in the order their newest report appears, so the crash the
    /// user is thinking of is near the top rather than filed under "W".
    private func orderedProcesses(of summaries: [ReportSummary]) -> [String] {
        var seen = Set<String>()
        return summaries.map(\.processName).filter { seen.insert($0).inserted }
    }
}

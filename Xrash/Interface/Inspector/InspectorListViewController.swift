// Fila's read-only fact list (MIT, same owner): Fila/Interface/Viewer/Shared/
// KeyValueListViewController.swift, narrowed to the one shape the Mach-O
// inspector pushes and given the search field these lists want: a binary has
// six hundred load commands and the question is always about one of them.

import UIKit

/// One column of monospaced values — dylib paths, load commands, segments.
final class InspectorListViewController: UITableViewController, UISearchResultsUpdating {
    /// Input order identifies even repeated values in an immutable fact list.
    private struct Entry: Hashable {
        let index: Int
        let value: String
    }

    private let entries: [Entry]
    private var dataSource: SectionedTableDataSource<Int, Entry>!
    private var searchText = ""

    init(title: String, rows: [String]) {
        entries = rows.enumerated().map { Entry(index: $0.offset, value: $0.element) }
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        dataSource = SectionedTableDataSource(tableView: tableView) { tableView, indexPath, entry in
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var configuration = UIListContentConfiguration.cell()
            configuration.text = entry.value
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .subheadline)
                .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
            configuration.textProperties.numberOfLines = 0
            // A dylib path has no spaces to break at, and wrapping by word
            // leaves half the row empty next to a line that is cut off anyway.
            configuration.textProperties.lineBreakMode = .byCharWrapping
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
            return cell
        }
        dataSource.header = { [weak self] _ in
            String(inflecting: "^[\(self?.shown.count ?? 0) item](inflect: true)")
        }
        render()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text ?? ""
        render()
    }

    private var shown: [Entry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? entries : entries.filter { $0.value.matches(needle) }
    }

    private func render() {
        let shown = shown
        var snapshot = NSDiffableDataSourceSnapshot<Int, Entry>()
        if !shown.isEmpty {
            snapshot.appendSections([0])
            snapshot.appendItems(shown)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        tableView.setEmptyState(shown.isEmpty ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "Nothing in this list matches “\(searchText)”."),
            actionTitle: nil,
        ) : nil)
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = entry.value
                    Toast.show(String(localized: "Copied"))
                },
            ])
        }
    }
}

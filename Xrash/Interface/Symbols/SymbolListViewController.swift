import UIKit

/// A list of symbol files by UUID, one section per binary: the imported dSYMs,
/// or the images no dSYM covers. Either can run to hundreds of rows — an app
/// that crashed across many builds is a row per build — so they live a page
/// below Symbols rather than on it.
final class SymbolListViewController: UITableViewController, UISearchResultsUpdating {
    struct Entry: Hashable {
        /// The image UUID.
        var id: String
        /// The binary's name, which is the section.
        var group: String
        var text: String
    }

    private let footer: String
    private let symbolName: String
    private let isMonospaced: Bool
    private let entries: () -> [Entry]
    private let delete: ((String) -> Void)?

    private var query = ""
    private var dataSource: SectionedTableDataSource<String, Entry>!

    /// `entries` is asked again after every change; `delete` nil means the
    /// rows are not the user's to remove.
    init(
        title: String,
        footer: String,
        symbolName: String,
        isMonospaced: Bool = false,
        entries: @escaping () -> [Entry],
        delete: ((String) -> Void)? = nil
    ) {
        self.footer = footer
        self.symbolName = symbolName
        self.isMonospaced = isMonospaced
        self.entries = entries
        self.delete = delete
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

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search symbols")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "symbol")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] table, indexPath, entry in
            let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
            guard let self else { return cell }
            var content = cell.defaultContentConfiguration()
            content.text = entry.text
            if isMonospaced {
                // A UUID is read, copied and compared.
                content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            }
            content.image = UIImage(systemName: symbolName)
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
        dataSource.header = { $0 }
        dataSource.footer = { [weak self] section in
            // Once, under the last binary.
            section == self?.dataSource.snapshot().sectionIdentifiers.last ? self?.footer : nil
        }
        dataSource.isEditable = delete != nil
        render()
    }

    private func render() {
        let all = entries()
        // Emptied by its own swipes: nothing left to be a page about.
        if all.isEmpty {
            navigationController?.popViewController(animated: true)
            return
        }
        let shown = query.isEmpty ? all : all.filter { entry in
            [entry.group, entry.id, entry.text].contains { $0.localizedStandardContains(query) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<String, Entry>()
        for group in Set(shown.map(\.group)).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            snapshot.appendSections([group])
            snapshot.appendItems(shown.filter { $0.group == group }, toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)

        tableView.setEmptyState(shown.isEmpty ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "Nothing here matches “\(query)”."),
            actionTitle: nil
        ) : nil)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        render()
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let delete, let entry = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UISwipeActionsConfiguration(actions: [
            UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [weak self] _, _, done in
                delete(entry.id)
                self?.render()
                done(true)
            },
        ])
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let uuid = dataSource.itemIdentifier(for: indexPath)?.id else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy UUID"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = uuid
                },
            ])
        }
    }
}

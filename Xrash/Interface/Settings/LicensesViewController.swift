import SnapKit
import Then
import UIKit

/// One notice out of `Licenses.json`, which the Collect Licenses build phase
/// writes from what the build actually links.
private struct LicenseEntry: Decodable {
    let name: String
    let version: String?
    let license: String
    let url: String
    let text: String

    var summary: String {
        [license, version].compactMap(\.self).joined(separator: " · ")
    }
}

/// Every license this app ships under, a row per notice and its whole text a
/// push away. Copied from Irisin's, which reads the same file this build
/// phase writes.
final class LicensesViewController: UITableViewController, UISearchResultsUpdating {
    private var entries: [LicenseEntry] = []
    private var searchText = ""

    /// Rows by position: two notices may read the same.
    private lazy var dataSource = UITableViewDiffableDataSource<Int, Int>(
        tableView: tableView
    ) { [weak self] tableView, indexPath, index in
        let cell = tableView.dequeueReusableCell(withIdentifier: "license", for: indexPath)
        guard let entry = self?.entries[index] else { return cell }
        var content = UIListContentConfiguration.valueCell()
        content.text = entry.name
        content.textProperties.numberOfLines = 1
        content.secondaryText = entry.summary
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Licenses")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LicenseEntry].self, from: data)
        {
            entries = decoded
        }
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Licenses")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "license")
        tableView.dataSource = dataSource
        render()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text ?? ""
        render()
    }

    private func render() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = entries.indices.filter { entries[$0].name.matches(needle) }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown)
        dataSource.apply(snapshot, animatingDifferences: false)

        if entries.isEmpty {
            tableView.setEmptyState(.message(
                symbolName: "doc.text",
                title: String(localized: "No Licenses"),
                description: String(localized: "This build shipped without its license file."),
                actionTitle: nil
            ))
        } else {
            tableView.setEmptyState(shown.isEmpty ? .message(
                symbolName: "magnifyingglass",
                title: String(localized: "No Results"),
                description: String(localized: "No license matches “\(needle)”."),
                actionTitle: nil
            ) : nil)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let index = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(LicenseTextViewController(entry: entries[index]), animated: true)
    }
}

/// The whole notice, selectable; its address is a link.
private final class LicenseTextViewController: UIViewController {
    private let entry: LicenseEntry

    init(entry: LicenseEntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.name
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        let text = NSMutableAttributedString(string: entry.name + "\n", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .title3),
            .foregroundColor: UIColor.label,
        ])
        text.append(NSAttributedString(string: entry.summary + "\n\n", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.secondaryLabel,
        ]))
        if let url = URL(string: entry.url), ["https", "http"].contains(url.scheme) {
            text.append(NSAttributedString(string: entry.url + "\n\n", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .link: url,
            ]))
        }
        text.append(NSAttributedString(string: entry.text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: UIColor.label,
        ]))

        let textView = UITextView().then {
            $0.isEditable = false
            $0.backgroundColor = .clear
            $0.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 28, right: 16)
            $0.attributedText = text
        }
        view.addSubview(textView)
        textView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }
}

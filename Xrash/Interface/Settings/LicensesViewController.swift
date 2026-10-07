import SnapKit
import Then
import UIKit

/// One notice out of `Licenses.json`, which the Collect Licenses build phase
/// writes from what the build actually links.
private struct LicenseEntry: Decodable {
    let name: String
    let license: String
    let url: String
    let text: String

    var licenseName: String {
        switch license {
        case "MIT": String(localized: "MIT License")
        case "Apache-2.0": String(localized: "Apache 2.0")
        default: license
        }
    }
}

/// Every license this app ships under, a row per notice and its whole text a
/// push away. Copied from Irisin's, which reads the same file this build
/// phase writes.
final class LicensesViewController: UITableViewController {
    private var entries: [LicenseEntry] = []

    /// Rows by position: two notices may read the same.
    private lazy var dataSource = UITableViewDiffableDataSource<Int, Int>(
        tableView: tableView,
    ) { [weak self] tableView, indexPath, index in
        let cell = tableView.dequeueReusableCell(withIdentifier: "license", for: indexPath)
        guard let entry = self?.entries[index] else { return cell }
        var content = UIListContentConfiguration.valueCell()
        content.prefersSideBySideTextAndSecondaryText = false
        content.text = entry.name
        content.secondaryText = entry.licenseName
        content.secondaryTextProperties.color = .secondaryLabel
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
        // Match the list's actual side inset once its rows have been laid out.
        let emptyFrame = CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude)
        tableView.tableHeaderView = UIView(frame: emptyFrame)
        tableView.tableFooterView = UIView(frame: emptyFrame)
        tableView.sectionFooterHeight = .leastNormalMagnitude

        if let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([LicenseEntry].self, from: data)
        {
            entries = decoded
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "license")
        tableView.dataSource = dataSource
        render()
    }

    private func render() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(Array(entries.indices))
        dataSource.apply(snapshot, animatingDifferences: false)

        if entries.isEmpty {
            tableView.setEmptyState(.message(
                symbolName: "doc.text",
                title: String(localized: "No Licenses"),
                description: String(localized: "License information is not available."),
                actionTitle: nil,
            ))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let cell = tableView.visibleCells.first,
              let header = tableView.tableHeaderView,
              let footer = tableView.tableFooterView else { return }
        let inset = cell.convert(cell.bounds, to: tableView).minX - tableView.bounds.minX
        guard inset > 0, header.frame.height != inset else { return }
        header.frame.size.height = inset
        footer.frame.size.height = inset
        tableView.tableHeaderView = header
        tableView.tableFooterView = footer
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
        text.append(NSAttributedString(string: entry.licenseName + "\n\n", attributes: [
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

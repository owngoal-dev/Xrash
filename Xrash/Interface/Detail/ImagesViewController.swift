import SnapKit
import Then
import UIKit
import XrashBlame
import XrashReport

/// Every binary that was mapped into the process. Searchable, because the one
/// question asked here is "was *that* tweak loaded", and there are six hundred
/// of them in a modern process.
final class ImagesViewController: SelectionTableViewController, UISearchResultsUpdating {
    private let crash: CrashReport
    private let packages: DpkgDatabase?
    /// Rows are load addresses: the one thing every report gives every image.
    private var dataSource: SectionedTableDataSource<Int, UInt64>!
    private var shown = [BinaryImage]()
    private var searchText = ""
    private var focus: BinaryImage?

    init(crash: CrashReport, packages: DpkgDatabase?) {
        self.crash = crash
        self.packages = packages
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Opens with one image already found — what "Show Image" on a frame does.
    func focus(on image: BinaryImage) {
        focus = image
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Binary Images")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Images")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(BinaryImageCell.self, forCellReuseIdentifier: "image")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, base in
            let cell = tableView.dequeueReusableCell(withIdentifier: "image", for: indexPath)
            self?.configure(cell, base: base)
            return cell
        }
        dataSource.header = { [weak self] _ in
            String(inflecting: "^[\(self?.shown.count ?? 0) image](inflect: true)")
        }
        if let focus {
            search.searchBar.text = focus.name
            searchText = focus.name
        }
        render()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text ?? ""
        render()
    }

    private func render() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = needle.isEmpty ? crash.images : crash.images.filter { image in
            let owner = packages?.owner(ofPath: image.path)
            return [image.name, image.path, image.uuid, owner?.name, owner?.identifier]
                .compactMap(\.self)
                .contains { $0.matches(needle) }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, UInt64>()
        if !shown.isEmpty {
            snapshot.appendSections([0])
            // Not the UUID: a jailbreak's own reporter lists images without
            // one. Two images at one address would be a corrupt report.
            snapshot.appendItems(shown.map(\.base).removingDuplicates())
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        tableView.setEmptyState(shown.isEmpty ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "No image in this report matches “\(needle)”."),
            actionTitle: nil,
        ) : nil)
    }

    private func configure(_ cell: UITableViewCell, base: UInt64) {
        guard let image = shown.first(where: { $0.base == base }) else { return }
        let owner = packages?.owner(ofPath: image.path)
        (cell as? BinaryImageCell)?.configure(
            with: image,
            package: owner.map { [$0.name ?? $0.identifier, $0.version].compactMap(\.self).joined(separator: " ") },
        )
    }

    private func selectableImage(at indexPath: IndexPath) -> BinaryImage? {
        guard let base = dataSource.itemIdentifier(for: indexPath),
              let image = shown.first(where: { $0.base == base }),
              ReportFormat.imageName(image.name, path: image.path) != nil else { return nil }
        return image
    }

    override func tableView(_: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        selectableImage(at: indexPath) == nil ? nil : indexPath
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let image = selectableImage(at: indexPath) else { return }
        inspectBinary(image)
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let image = selectableImage(at: indexPath) else { return nil }
        let owner = packages?.owner(ofPath: image.path)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var elements: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Inspect Binary"),
                    image: UIImage(systemName: "doc.text.magnifyingglass"),
                ) { _ in
                    self?.inspectBinary(image)
                },
                UIAction(title: String(localized: "Copy Path"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = image.path
                    Toast.show(String(localized: "Path Copied"))
                },
                UIAction(title: String(localized: "Copy UUID"), image: UIImage(systemName: "number")) { _ in
                    UIPasteboard.general.string = image.uuid
                    Toast.show(String(localized: "Copied"))
                },
            ]
            // The sibling apps, each offered only where it is installed.
            if let fila = SiblingApps.revealInFila(path: image.path) {
                elements.append(
                    UIAction(title: String(localized: "Reveal in Fila"), image: UIImage(systemName: "folder")) { _ in
                        SiblingApps.open(fila)
                    },
                )
            }
            if let owner, let irisin = SiblingApps.packageInIrisin(identifier: owner.identifier) {
                elements.append(
                    UIAction(
                        title: String(localized: "Show Package in Irisin"),
                        image: UIImage(systemName: "shippingbox"),
                    ) { _ in
                        SiblingApps.open(irisin)
                    },
                )
            }
            return UIMenu(children: elements)
        }
    }
}

private final class BinaryImageCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let architectureLabel = UILabel()
    private let addressLabel = UILabel()
    private let uuidLabel = UILabel()
    private let packageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isAccessibilityElement = true
        nameLabel.font = DetailTypography.mono()
        for label in [architectureLabel, addressLabel, uuidLabel, packageLabel] {
            label.font = DetailTypography.mono()
            label.textColor = .secondaryLabel
        }
        for label in [nameLabel, architectureLabel, addressLabel, uuidLabel, packageLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        uuidLabel.lineBreakMode = .byCharWrapping

        architectureLabel.numberOfLines = 1
        addressLabel.numberOfLines = 1
        addressLabel.setContentHuggingPriority(.required, for: .horizontal)
        addressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let metadata = UIStackView(arrangedSubviews: [architectureLabel, addressLabel]).then {
            $0.alignment = .firstBaseline
            $0.spacing = 8
        }
        let content = UIStackView(arrangedSubviews: [nameLabel, uuidLabel, metadata, packageLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        contentView.addSubview(content)
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(8)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with image: BinaryImage, package: String?) {
        let name = ReportFormat.imageName(image.name, path: image.path)
        nameLabel.text = name ?? ReportFormat.unknownImageName
        accessoryType = name == nil ? .none : .disclosureIndicator
        selectionStyle = name == nil ? .none : .default
        accessibilityTraits = name == nil ? .staticText : .button
        architectureLabel.text = image.arch
        architectureLabel.isHidden = image.arch?.isEmpty != false
        addressLabel.text = ReportFormat.address(image.base)
        addressLabel.textAlignment = architectureLabel.isHidden ? .natural : .right
        uuidLabel.text = image.uuid
        uuidLabel.isHidden = image.uuid.isEmpty
        packageLabel.text = package
        packageLabel.isHidden = package?.isEmpty != false
        accessibilityLabel = [
            nameLabel.text,
            image.uuid.isEmpty ? nil : String(localized: "UUID") + ": " + image.uuid,
            image.arch,
            String(localized: "Virtual Address") + ": " + ReportFormat.address(image.base),
            package,
        ].compactMap(\.self).joined(separator: ", ")
    }
}

extension Array where Element: Hashable {
    /// A diffable snapshot traps on a repeated identifier, and a report is an
    /// untrusted file that can repeat one.
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

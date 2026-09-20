import QuickLook
import UIKit
import XrashBundle
import XrashReport

/// One saved bundle: what it says about itself, the reports inside it, the
/// files it carries and what can be done with the archive.
///
/// Nothing here unzips to draw a row. The manifest cached beside the archive
/// already holds every member's decoded report, so a member opens straight
/// into the detail screen; only a file the user asks to see is extracted.
final class BundleDetailViewController: UITableViewController, UISearchResultsUpdating {
    private enum Section: Hashable {
        case about, members, files, actions
    }

    private enum Row: Hashable {
        case notes
        case device
        case member(String)
        case pdf
        case binary(String)
        case share
        case exportPDF
    }

    private let bundle: SavedBundleStore.SavedBundle
    private let store: SavedBundleStore
    private var dataSource: SectionedTableDataSource<Section, Row>!
    private var query = ""

    init(bundle: SavedBundleStore.SavedBundle, store: SavedBundleStore) {
        self.bundle = bundle
        self.store = store
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private var members: [BundleManifest.Member] {
        [bundle.manifest.primary] + bundle.manifest.linked
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = bundle.manifest.title
        navigationItem.largeTitleDisplayMode = .never

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search the reports in this bundle")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(BundleReportCell.self, forCellReuseIdentifier: BundleReportCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] table, indexPath, row in
            self?.cell(for: row, at: indexPath, in: table) ?? UITableViewCell()
        }
        dataSource.header = { section in
            switch section {
            case .about, .actions: nil
            case .members: String(localized: "Reports")
            case .files: String(localized: "Files")
            }
        }
        render()
    }

    /// While a search is running the page is only its reports: the notes, the
    /// files and the actions are not what was being looked for.
    private func render() {
        let matching = members.filter { $0.summary.processName.matches(query) }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        if query.isEmpty {
            snapshot.appendSections([.about])
            snapshot.appendItems(
                (bundle.manifest.notes.isEmpty ? [] : [Row.notes]) + [.device],
                toSection: .about
            )
        }
        if !matching.isEmpty {
            snapshot.appendSections([.members])
            snapshot.appendItems(matching.map { Row.member($0.id) }, toSection: .members)
        }
        if query.isEmpty {
            let files = (bundle.manifest.pdfPath == nil ? [] : [Row.pdf])
                + bundle.manifest.binaries.map { Row.binary($0.uuid) }
            if !files.isEmpty {
                snapshot.appendSections([.files])
                snapshot.appendItems(files, toSection: .files)
            }
            snapshot.appendSections([.actions])
            snapshot.appendItems(
                [.share] + (bundle.manifest.pdfPath == nil ? [] : [Row.exportPDF]),
                toSection: .actions
            )
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        tableView.setEmptyState(matching.isEmpty ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "No report in this bundle matches “\(query)”."),
            actionTitle: nil
        ) : nil)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: animated)
        }
    }

    // MARK: Rows

    private func cell(for row: Row, at indexPath: IndexPath, in table: UITableView) -> UITableViewCell {
        switch row {
        case .notes:
            let cell = table.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = bundle.manifest.notes
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell

        case .device:
            let cell = table.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = [bundle.manifest.deviceModel, bundle.manifest.osVersion]
                .compactMap(\.self).joined(separator: " · ")
            content.secondaryText = bundle.manifest.generator
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell

        case let .member(id):
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier, for: indexPath
            ) as! BundleReportCell
            if let member = members.first(where: { $0.id == id }) {
                let detail = member.relation.map(RelationText.label) ?? String(localized: "Primary")
                cell.configure(with: member.summary, detail: detail)
            }
            cell.accessoryType = .disclosureIndicator
            return cell

        case .pdf:
            return action(
                table,
                indexPath,
                title: String(localized: "Report.pdf"),
                symbol: "doc.richtext",
                detail: nil,
                disclosure: true
            )

        case let .binary(uuid):
            let binary = bundle.manifest.binaries.first { $0.uuid == uuid }
            return action(
                table,
                indexPath,
                title: (binary?.archivePath as NSString?)?.lastPathComponent ?? uuid,
                symbol: "cube",
                detail: ReportFormat.byteCount(binary?.byteCount ?? 0),
                disclosure: false
            )

        case .share:
            return action(
                table,
                indexPath,
                title: String(localized: "Share Archive"),
                symbol: "square.and.arrow.up",
                detail: nil,
                disclosure: false,
                tinted: true
            )

        case .exportPDF:
            return action(
                table,
                indexPath,
                title: String(localized: "Export PDF"),
                symbol: "arrow.up.doc",
                detail: nil,
                disclosure: false,
                tinted: true
            )
        }
    }

    private func action(
        _ table: UITableView,
        _ indexPath: IndexPath,
        title: String,
        symbol: String,
        detail: String?,
        disclosure: Bool,
        tinted: Bool = false
    ) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.secondaryText = detail
        content.prefersSideBySideTextAndSecondaryText = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: symbol)
        if tinted {
            content.textProperties.color = view.tintColor
            content.imageProperties.tintColor = view.tintColor
        }
        cell.contentConfiguration = content
        cell.accessoryType = disclosure ? .disclosureIndicator : .none
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = dataSource.itemIdentifier(for: indexPath)
        switch item {
        case let .member(id):
            guard let member = members.first(where: { $0.id == id }) else { return }
            navigationController?.pushViewController(
                ReportDetailViewController(report: member.report, title: member.summary.processName),
                animated: true
            )
        case .pdf, .exportPDF:
            tableView.deselectRow(at: indexPath, animated: true)
            openPDF(exporting: item == .exportPDF,
                    from: tableView.cellForRow(at: indexPath))
        case .share:
            tableView.deselectRow(at: indexPath, animated: true)
            ReportShare.present([bundle.url], from: self, source: tableView.cellForRow(at: indexPath))
        default:
            tableView.deselectRow(at: indexPath, animated: true)
        }
    }

    private func openPDF(exporting: Bool, from source: UIView?) {
        // The manifest says whether there is a PDF, never where: its path came
        // out of someone else's archive, and the writer only ever uses one.
        guard bundle.manifest.pdfPath != nil else { return }
        do {
            let url = try store.extract(bundle).appendingPathComponent(BundleLayout.pdf)
            if exporting {
                ReportShare.present([url], from: self, source: source)
            } else {
                BundlePDFPreview.present(url, title: bundle.manifest.title, from: self)
            }
        } catch {
            presentFailure("Could Not Open the PDF", error)
        }
    }
}

/// QuickLook wants a data source that outlives the presentation, so the one
/// item being previewed keeps it alive.
final class BundlePDFPreview: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let url: URL
    private let itemTitle: String
    private var retained: BundlePDFPreview?

    private init(url: URL, title: String) {
        self.url = url
        itemTitle = title
    }

    static func present(_ url: URL, title: String, from controller: UIViewController) {
        let source = BundlePDFPreview(url: url, title: title)
        source.retained = source
        let preview = QLPreviewController()
        preview.dataSource = source
        preview.delegate = source
        controller.present(preview, animated: true)
    }

    func numberOfPreviewItems(in _: QLPreviewController) -> Int {
        1
    }

    func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
        PreviewItem(previewItemURL: url, previewItemTitle: itemTitle)
    }

    func previewControllerDidDismiss(_: QLPreviewController) {
        retained = nil
    }

    private final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(previewItemURL: URL, previewItemTitle: String) {
            self.previewItemURL = previewItemURL
            self.previewItemTitle = previewItemTitle
        }
    }
}

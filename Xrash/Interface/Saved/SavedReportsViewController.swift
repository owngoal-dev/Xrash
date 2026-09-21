import Combine
import UIKit
import UniformTypeIdentifiers
import XrashBundle
import XrashReport

/// The Saved page: the `.xrashreport` bundles made or imported on this device.
final class SavedReportsViewController: UITableViewController, UIDocumentPickerDelegate, UISearchResultsUpdating {
    private let store: SavedBundleStore
    private var observation: AnyCancellable?
    private var dataSource: SectionedTableDataSource<Int, String>!
    private var shown = [String: SavedBundleStore.SavedBundle]()
    private var query = ""

    init(store: SavedBundleStore = AppEnvironment.shared.savedBundles) {
        self.store = store
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Saved")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.importArchive() }
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Import Report")

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search by title, process or notes")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "bundle")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] table, indexPath, id in
            let cell = table.dequeueReusableCell(withIdentifier: "bundle", for: indexPath)
            guard let bundle = self?.shown[id] else { return cell }
            var content = cell.defaultContentConfiguration()
            content.text = bundle.manifest.title
            content.secondaryText = Self.subtitle(of: bundle)
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "heart.text.square.fill")
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        dataSource.isEditable = true
        observation = store.bundles.sink { [weak self] bundles in self?.render(bundles) }
        store.reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.reload()
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: animated)
        }
    }

    /// Opens a bundle by id — how `ExternalFileRouter` shows what it imported.
    func show(bundleID: String) {
        guard let bundle = shown[bundleID] else { return }
        navigationController?.popToRootViewController(animated: false)
        navigationController?.pushViewController(
            BundleDetailViewController(bundle: bundle, store: store),
            animated: true
        )
    }

    // MARK: Rows

    private func render(_ bundles: [SavedBundleStore.SavedBundle]) {
        shown = Dictionary(bundles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matches = bundles.filter(matches)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(matches.map(\.id), toSection: 0)
        let isFirstLoad = dataSource.snapshot().numberOfItems == 0
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !isFirstLoad)

        if !matches.isEmpty {
            tableView.setEmptyState(nil)
        } else if query.isEmpty {
            tableView.setEmptyState(.message(
                symbolName: "heart.text.square",
                title: String(localized: "No Saved Reports"),
                description: String(localized: """
                Use Report Crash on any report to bundle it with related crashes.
                """),
                actionTitle: nil
            ))
        } else {
            tableView.setEmptyState(.message(
                symbolName: "magnifyingglass",
                title: String(localized: "No Results"),
                description: String(localized: "No saved report matches “\(query)”."),
                actionTitle: nil
            ))
        }
    }

    /// Title, notes and the processes inside — someone looking for "assertiond"
    /// means the crash, not the name they happened to give the bundle.
    private func matches(_ bundle: SavedBundleStore.SavedBundle) -> Bool {
        let manifest = bundle.manifest
        let processes = ([manifest.primary] + manifest.linked).map(\.summary.processName)
        return ([manifest.title, manifest.notes] + processes)
            .contains { $0.matches(query) }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        render(store.bundles.value)
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let bundle = shown[id] else { return }
        navigationController?.pushViewController(
            BundleDetailViewController(bundle: bundle, store: store),
            animated: true
        )
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) {
            [weak self] _, _, done in
            self?.delete(id)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let bundle = shown[id] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIAction]()
            actions.append(UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                self?.share(bundle, from: tableView.cellForRow(at: indexPath))
            })
            if bundle.manifest.pdfPath != nil {
                actions.append(UIAction(
                    title: String(localized: "Open PDF"),
                    image: UIImage(systemName: "doc.richtext")
                ) { [weak self] _ in
                    self?.openPDF(bundle)
                })
            }
            actions.append(UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.delete(id)
            })
            return UIMenu(children: actions)
        }
    }

    // MARK: Actions

    private func delete(_ id: String) {
        guard let bundle = shown[id] else { return }
        do {
            try store.remove(bundle)
        } catch {
            presentFailure("Could Not Delete the Report", error)
        }
    }

    private func share(_ bundle: SavedBundleStore.SavedBundle, from source: UIView?) {
        ReportShare.present(bundle, from: self, source: source)
    }

    private func openPDF(_ bundle: SavedBundleStore.SavedBundle) {
        do {
            let directory = try store.extract(bundle)
            // Whether, not where: see `BundleDetailViewController.openPDF`.
            guard bundle.manifest.pdfPath != nil else { return }
            BundlePDFPreview.present(
                directory.appendingPathComponent(BundleLayout.pdf),
                title: bundle.manifest.title,
                from: self
            )
        } catch {
            presentFailure("Could Not Open the PDF", error)
        }
    }

    private func importArchive() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.xrashReport, .zip],
            asCopy: true
        )
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Importing unzips the whole archive to read its manifest, which is a
    /// wait for a bundle carrying binaries.
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let imported = try await ProgressCard.run(
                    from: self,
                    title: String(localized: "Importing the Report")
                ) { report in
                    var ids = [String]()
                    for (offset, url) in urls.enumerated() {
                        try Task.checkCancellation()
                        report(Double(offset) / Double(urls.count), url.lastPathComponent)
                        try ids.append(self.store.add(archiveAt: url).id)
                    }
                    return ids
                }
                if let last = imported.last {
                    show(bundleID: last)
                }
            } catch is CancellationError {
                return
            } catch {
                presentFailure("Could Not Import the Report", error)
            }
        }
    }

    // MARK: Chrome

    private static func subtitle(of bundle: SavedBundleStore.SavedBundle) -> String {
        let count = 1 + bundle.manifest.linked.count
        let attributes = try? FileManager.default.attributesOfItem(atPath: bundle.url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        var parts = [
            String(inflecting: "^[\(count) report](inflect: true)"),
            ReportFormat.byteCount(size),
            ReportFormat.date(bundle.manifest.created),
        ]
        // Said on the row, not only inside: this is the one thing about a saved
        // bundle worth knowing before it is opened or shared.
        if bundle.manifest.systemFiles?.isEmpty == false {
            parts.append(String(localized: "System State"))
        }
        return parts.joined(separator: " · ")
    }
}

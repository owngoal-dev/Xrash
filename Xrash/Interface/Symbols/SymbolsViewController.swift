import AlertController
import Combine
import UIKit
import UniformTypeIdentifiers
import XrashClient
import XrashReport
import XrashSymbols

/// The Symbols page: extracted system symbols, and the way in to the imported
/// dSYMs and to what is missing.
///
/// System symbols are the reason this page exists. A crash report names system
/// frames by address only, and the cache that could resolve them is replaced
/// by the next OS update — extracting once keeps every report from this build
/// readable afterwards.
final class SymbolsViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Section: Hashable {
        case dsyms, system
    }

    /// The two lists that can run long are a page below, grouped by binary;
    /// what stays here is a count and the things to do.
    private enum Row: Hashable {
        case importedDSYMs
        case missingSymbols
        case importDSYM
        case importFromGitHub
        case symbolSet(String)
        case noSymbolSet
        case extractAll
        case deleteSystem
    }

    private let environment: AppEnvironment
    private var missing = [SymbolListViewController.Entry]()
    private var missingScan: Task<Void, Never>?
    private var isWorking = false
    private var dataSource: SectionedTableDataSource<Section, Row>!

    init(environment: AppEnvironment = .shared) {
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Symbols")
        navigationItem.largeTitleDisplayMode = .always
        // No "+" in the bar: the two import rows sit in the first section,
        // and one affordance beats two.

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "symbol")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] table, indexPath, row in
            self?.cell(for: row, at: indexPath, in: table) ?? UITableViewCell()
        }
        dataSource.header = { section in
            switch section {
            case .dsyms: String(localized: "dSYMs")
            case .system: String(localized: "System Symbols")
            }
        }
        dataSource.footer = { section in
            switch section {
            case .dsyms:
                String(localized: "A dSYM names the addresses in your own code.")
            case .system:
                String(
                    localized: "Extracted once per system version, so system frames have names in every report."
                )
            }
        }
        // Only symbol-set rows answer with a swipe action below.
        dataSource.isEditable = true
    }

    /// The missing-symbols scan decodes reports, so it is the one part of this
    /// page that is not there at once. It gets a short budget before the page
    /// comes up; past it the page appears without that section and the section
    /// is set in place — never animated in — when the scan lands.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        LoadBudget.wait(LoadBudget.page) { [weak self] in await self?.scanForMissingSymbols() }
        render()
    }

    // MARK: Rows

    /// A link row is there only while it has something behind it.
    private func render(animated: Bool = true) {
        let store = environment.systemSymbols
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.dsyms, .system])
        snapshot.appendItems(
            (environment.dsyms.records.isEmpty ? [] : [.importedDSYMs])
                + (missing.isEmpty ? [] : [.missingSymbols])
                + [.importDSYM, .importFromGitHub],
            toSection: .dsyms
        )
        // Extracting again is only worth a row once what is stored is gone.
        snapshot.appendItems(
            (store.sets.isEmpty ? [.noSymbolSet] : store.sets.map { Row.symbolSet($0.id) })
                + (isCurrentSystemExtracted ? [] : [.extractAll])
                + (store.sets.isEmpty ? [] : [.deleteSystem]),
            toSection: .system
        )
        // The counts on the link rows are not part of their identity.
        snapshot.reconfigureItems([.importedDSYMs, .missingSymbols].filter(snapshot.itemIdentifiers.contains))
        let isFirstLoad = dataSource.snapshot().numberOfItems == 0
        dataSource.apply(snapshot, animatingDifferences: animated && !isFirstLoad && view.window != nil)
    }

    // ponytail: a set has no "whole cache" flag, and symbolicating a report
    // tops the running build's set up with a few dozen images. A whole cache is
    // thousands, so the count tells them apart; store a flag in
    // `SystemSymbolSet` if a cache ever comes in under this.
    private var isCurrentSystemExtracted: Bool {
        environment.systemSymbols.sets.contains {
            $0.id == SystemSymbolStore.osBuild() && $0.imageCount >= 1000
        }
    }

    private func link(
        _ table: UITableView,
        _ indexPath: IndexPath,
        title: String,
        count: Int,
        symbol: String
    ) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        content.text = title
        content.secondaryText = count.formatted()
        content.image = UIImage(systemName: symbol)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    private func cell(for row: Row, at indexPath: IndexPath, in table: UITableView) -> UITableViewCell {
        switch row {
        case .importedDSYMs:
            return link(
                table,
                indexPath,
                title: String(localized: "Imported dSYMs"),
                count: environment.dsyms.records.count,
                symbol: "doc.text.magnifyingglass"
            )

        case .missingSymbols:
            return link(
                table,
                indexPath,
                title: String(localized: "Missing Symbols"),
                count: missing.count,
                symbol: "questionmark.square.dashed"
            )

        case .importDSYM:
            return action(
                table,
                indexPath,
                title: String(localized: "Import dSYM…"),
                symbol: "arrow.down.doc"
            )

        case .importFromGitHub:
            return action(
                table,
                indexPath,
                title: String(localized: "Import from GitHub Release…"),
                symbol: "shippingbox"
            )

        case let .symbolSet(build):
            let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
            var content = cell.defaultContentConfiguration()
            if let set = environment.systemSymbols.sets.first(where: { $0.id == build }) {
                content.text = set.id
                content.secondaryText = [
                    String(inflecting: "^[\(set.imageCount) image](inflect: true)"),
                    ReportFormat.byteCount(set.byteCount),
                    ReportFormat.date(set.extracted),
                ].joined(separator: " · ")
            }
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "cpu")
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell

        case .noSymbolSet:
            let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Not extracted")
            content.textProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "cpu")
            content.imageProperties.tintColor = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            return cell

        case .extractAll:
            return action(
                table,
                indexPath,
                title: String(localized: "Extract System Symbols"),
                symbol: "square.and.arrow.down"
            )

        case .deleteSystem:
            return action(
                table,
                indexPath,
                title: String(localized: "Delete System Symbols"),
                symbol: "trash",
                tint: .systemRed
            )
        }
    }

    private func action(
        _ table: UITableView,
        _ indexPath: IndexPath,
        title: String,
        symbol: String,
        tint: UIColor? = nil
    ) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let color = tint ?? view.tintColor ?? .tintColor
        content.text = title
        content.textProperties.color = color
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = color
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .importedDSYMs: showImportedDSYMs()
        case .missingSymbols: showMissingSymbols()
        case .importDSYM: importDSYM()
        case .importFromGitHub: askForRepository()
        case .extractAll: confirmExtractAll()
        case .deleteSystem: confirmDeleteSystemSymbols()
        default: break
        }
    }

    // MARK: The long lists

    private func showImportedDSYMs() {
        let store = environment.dsyms
        navigationController?.pushViewController(SymbolListViewController(
            title: String(localized: "Imported dSYMs"),
            footer: String(localized: "A dSYM names the addresses in your own code."),
            symbolName: "doc.text.magnifyingglass",
            entries: {
                store.records.map { record in
                    .init(id: record.id, group: record.binaryName, text: [
                        record.arch,
                        String(record.id.prefix(8)),
                        ReportFormat.byteCount(record.byteCount),
                        ReportFormat.date(record.imported),
                    ].joined(separator: " · "))
                }
            },
            delete: { try? store.remove(uuid: $0) }
        ), animated: true)
    }

    private func showMissingSymbols() {
        let missing = missing
        navigationController?.pushViewController(SymbolListViewController(
            title: String(localized: "Missing Symbols"),
            footer: String(localized: "Images in recent reports that no dSYM covers."),
            symbolName: "questionmark.square.dashed",
            isMonospaced: true,
            entries: { missing }
        ), animated: true)
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) {
            [weak self] _, _, done in
            guard let self else { return done(false) }
            guard case let .symbolSet(build) = dataSource.itemIdentifier(for: indexPath) else {
                return done(false)
            }
            try? environment.systemSymbols.remove(build: build)
            render()
            done(true)
        }
        guard case .symbolSet = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .importFromGitHub:
            // The repositories asked for before, so the second visit is a tap.
            let recent = GitHubReleaseSymbols.recentRepositories
            guard !recent.isEmpty else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(title: String(localized: "Recent"), children: recent.map { repository in
                    UIAction(title: repository.slug, image: UIImage(systemName: "shippingbox")) { _ in
                        self?.showReleases(in: repository)
                    }
                })
            }
        default:
            return nil
        }
    }

    // MARK: GitHub releases

    private func askForRepository() {
        let alert = AlertInputViewController(
            title: String.LocalizationValue("Import from GitHub Release"),
            message: String.LocalizationValue(
                "Enter the repository whose releases carry the debug symbols, as owner/repo."
            ),
            placeholder: String.LocalizationValue("owner/repo"),
            text: GitHubReleaseSymbols.recentRepositories.first?.slug ?? "",
            doneButtonText: String.LocalizationValue("Continue")
        ) { [weak self] text in
            guard let repository = GitHubReleaseSymbols.repository(from: text) else {
                self?.presentMessage(
                    "Invalid Repository",
                    message: String.LocalizationValue(
                        "Enter it as owner/repo, or paste the repository's GitHub address."
                    )
                )
                return
            }
            self?.showReleases(in: repository)
        }
        present(alert, animated: true)
    }

    private func showReleases(in repository: GitHubReleaseSymbols.Repository) {
        GitHubReleaseSymbols.remember(repository)
        navigationController?.pushViewController(
            GitHubReleasesViewController(repository: repository, store: environment.dsyms) { [weak self] in
                self?.render()
            },
            animated: true
        )
    }

    // MARK: dSYM import

    private func importDSYM() {
        var types: [UTType] = [.folder, .zip, .data]
        if let dsym = UTType("com.apple.xcode.dsym") {
            types.insert(dsym, at: 0)
        }
        // Not `asCopy`: a `.dSYM` is a package, and the store makes its own
        // copy of whichever slices it finds inside one.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Unpacking a dSYM can take a while for a large one, so it goes under the
    /// progress card like every other wait in the app.
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !isWorking else { return }
        isWorking = true
        let store = environment.dsyms
        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                let imported = try await ProgressCard.run(
                    from: self,
                    title: String(localized: "Importing Symbols")
                ) { report in
                    var count = 0
                    for (offset, url) in urls.enumerated() {
                        try Task.checkCancellation()
                        report(Double(offset) / Double(urls.count), url.lastPathComponent)
                        count += try await DSYMImport.runDetached(at: url, into: store)
                    }
                    return count
                }
                render()
                Toast.show(String(inflecting: "Imported ^[\(imported) dSYM file](inflect: true)"))
            } catch is CancellationError {
                render()
            } catch {
                render()
                presentFailure("Unable to Import Symbols", error)
            }
        }
    }

    // MARK: System symbols

    /// The whole cache, which is what this screen offers. Symbolicating a
    /// single report tops the store up with just that report's images on its
    /// own; nobody has to ask for that, so there is no row for it.
    private func extractSystemSymbols() {
        guard !isWorking else { return }
        isWorking = true
        // The extraction is long and the user is watching a bar, not touching
        // the screen: nothing else keeps the device from locking mid-run.
        UIApplication.shared.isIdleTimerDisabled = true

        let backend = environment.backend
        let store = environment.systemSymbols
        Task { [weak self] in
            guard let self else { return }
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                isWorking = false
            }
            do {
                _ = try await ProgressCard.run(
                    from: self,
                    title: String(localized: "Extracting System Symbols")
                ) { report in
                    try await store.extractCurrentSystem(
                        openImage: { try await backend.openImage(at: $0) },
                        progress: { fraction, image in
                            Task { @MainActor in report(fraction, image) }
                        }
                    )
                }
                render()
                Toast.show(String(localized: "System Symbols Extracted"))
            } catch is CancellationError {
                render()
            } catch {
                render()
                presentFailure("Unable to Extract System Symbols", error)
            }
        }
    }

    private func confirmExtractAll() {
        let alert = AlertViewController(
            title: String.LocalizationValue("Extract System Symbols"),
            message: String.LocalizationValue(
                "Extracting every system image takes several minutes and more than a gigabyte of storage."
            )
        ) { [weak self] context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Extract"), attribute: .accent) {
                context.dispose { self?.extractSystemSymbols() }
            }
        }
        present(alert, animated: true)
    }

    private func confirmDeleteSystemSymbols() {
        let builds = environment.systemSymbols.sets.map(\.id)
        guard !builds.isEmpty else { return }
        let alert = AlertViewController(
            title: String.LocalizationValue("Delete System Symbols"),
            message: String.LocalizationValue(
                "System frames go back to addresses until you extract them again."
            )
        ) { [weak self] context in
            context.allowSimpleDispose()
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Delete"), attribute: .accent) {
                context.dispose {
                    guard let self else { return }
                    for build in builds {
                        try? self.environment.systemSymbols.remove(build: build)
                    }
                    self.render()
                }
            }
        }
        present(alert, animated: true)
    }

    // MARK: Missing symbols

    /// What recent reports name that nothing here can resolve. Decoding is the
    /// expensive part, so only the newest handful of reports is looked at and
    /// only when the page comes up.
    private func scanForMissingSymbols() async {
        missingScan?.cancel()
        let library = environment.library
        let store = environment.dsyms
        let scan = Task { [weak self] in
            var found = [SymbolListViewController.Entry]()
            var seen = Set<String>()
            for summary in library.summaries.value.prefix(20) where summary.kind == .crash {
                guard !Task.isCancelled else { return }
                guard let crash = try? await library.report(for: summary.id).crash else { continue }
                for image in crash.images where ReportBundleBuilder.isThirdParty(image) {
                    guard seen.insert(image.uuid).inserted, store.url(forUUID: image.uuid) == nil else { continue }
                    found.append(.init(id: image.uuid, group: image.name, text: image.uuid))
                }
            }
            guard !Task.isCancelled else { return }
            self?.missing = found
            self?.render(animated: false)
        }
        missingScan = scan
        await scan.value
    }
}

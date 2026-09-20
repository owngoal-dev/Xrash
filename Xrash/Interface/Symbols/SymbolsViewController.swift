import AlertController
import Combine
import UIKit
import UniformTypeIdentifiers
import XrashClient
import XrashReport
import XrashSymbols

/// The Symbols page: imported dSYMs, extracted system symbols, what is missing.
///
/// System symbols are the reason this page exists. A crash report names system
/// frames by address only, and the cache that could resolve them is replaced
/// by the next OS update — extracting once keeps every report from this build
/// readable afterwards.
final class SymbolsViewController: UITableViewController, UIDocumentPickerDelegate, UISearchResultsUpdating {
    private enum Section: Hashable {
        case dsyms, system, missing
    }

    private enum Row: Hashable {
        case dsym(String)
        case importDSYM
        case importFromGitHub
        case symbolSet(String)
        case noSymbolSet
        case extractAll
        case deleteSystem
        case missing(MissingImage)
        case showAllMissing(String)
        case noneMissing
    }

    private struct MissingImage: Hashable {
        var uuid: String
        var name: String
    }

    /// Past this, one app's many builds would be the whole section.
    private static let shownPerImageName = 5

    private let environment: AppEnvironment
    private var missing = [MissingImage]()
    private var missingScan: Task<Void, Never>?
    private var expanded = Set<String>()
    private var isWorking = false
    private var query = ""
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

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search symbols by name, UUID or build")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "symbol")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] table, indexPath, row in
            self?.cell(for: row, at: indexPath, in: table) ?? UITableViewCell()
        }
        dataSource.header = { section in
            switch section {
            case .dsyms: String(localized: "dSYMs")
            case .system: String(localized: "System Symbols")
            case .missing: String(localized: "Missing Symbols")
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
            case .missing:
                String(localized: "Images in recent reports that no dSYM covers.")
            }
        }
        // Only dSYM and symbol-set rows answer with a swipe action below.
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

    /// Searching narrows the three lists and takes the action rows away: what
    /// the user is looking for is a symbol file, not a button.
    private func render(animated: Bool = true) {
        let isSearching = !query.isEmpty
        let dsyms = environment.dsyms.records
            .filter { matches($0.binaryName, $0.id, $0.arch) }
            .map { Row.dsym($0.id) }
        let sets = environment.systemSymbols.sets
            .filter { matches($0.id) }
            .map { Row.symbolSet($0.id) }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let dsymRows = dsyms + (isSearching ? [] : [.importDSYM, .importFromGitHub])
        if !dsymRows.isEmpty {
            snapshot.appendSections([.dsyms])
            snapshot.appendItems(dsymRows, toSection: .dsyms)
        }
        if !isSearching || !sets.isEmpty {
            snapshot.appendSections([.system])
            let stored = sets.isEmpty && !isSearching ? [Row.noSymbolSet] : sets
            let actions: [Row] = isSearching
                ? []
                : [.extractAll] + (environment.systemSymbols.sets.isEmpty ? [] : [.deleteSystem])
            snapshot.appendItems(stored + actions, toSection: .system)
        }
        let missingRows = missingRows(isSearching: isSearching)
        if !missingRows.isEmpty {
            snapshot.appendSections([.missing])
            snapshot.appendItems(missingRows, toSection: .missing)
        }
        let isFirstLoad = dataSource.snapshot().numberOfItems == 0
        dataSource.apply(snapshot, animatingDifferences: animated && !isFirstLoad && view.window != nil)

        tableView.setEmptyState(snapshot.numberOfItems == 0 ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "Nothing here matches “\(query)”."),
            actionTitle: nil
        ) : nil)
    }

    /// One row per (name, UUID). An app that crashed across many builds would
    /// otherwise be the whole section, so only its newest few are shown until
    /// the reader asks for the rest.
    private func missingRows(isSearching: Bool) -> [Row] {
        let matching = missing.filter { matches($0.name, $0.uuid) }
        guard !matching.isEmpty else { return isSearching ? [] : [.noneMissing] }

        var rows = [Row]()
        var seenNames = Set<String>()
        for name in matching.map(\.name) where seenNames.insert(name).inserted {
            let images = matching.filter { $0.name == name }
            let shown = expanded.contains(name) || isSearching
                ? images
                : Array(images.prefix(Self.shownPerImageName))
            rows.append(contentsOf: shown.map(Row.missing))
            if shown.count < images.count {
                rows.append(.showAllMissing(name))
            }
        }
        return rows
    }

    /// Case- and diacritic-insensitive, which is what `localizedStandardContains`
    /// already is.
    private func matches(_ fields: String?...) -> Bool {
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        render()
    }

    private func cell(for row: Row, at indexPath: IndexPath, in table: UITableView) -> UITableViewCell {
        switch row {
        case let .dsym(uuid):
            let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
            var content = cell.defaultContentConfiguration()
            if let record = environment.dsyms.records.first(where: { $0.id == uuid }) {
                content.text = record.binaryName
                content.secondaryText = [
                    record.arch,
                    String(record.id.prefix(8)),
                    ReportFormat.byteCount(record.byteCount),
                ].joined(separator: " · ")
            }
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "doc.text.magnifyingglass")
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell

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

        case let .missing(image):
            let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = image.name
            // A UUID is the whole point of the row; it is read, copied and
            // compared, so it is not set in grey.
            content.secondaryText = image.uuid
            content.secondaryTextProperties.color = .label
            content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            content.image = UIImage(systemName: "questionmark.square.dashed")
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell

        case let .showAllMissing(name):
            return action(
                table,
                indexPath,
                title: String(localized: "Show All \(name) Builds"),
                symbol: "ellipsis"
            )

        case .noneMissing:
            let cell = table.dequeueReusableCell(withIdentifier: "symbol", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Nothing is missing symbols.")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
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
        cell.accessoryView = nil
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .importDSYM: importDSYM()
        case .importFromGitHub: askForRepository()
        case .extractAll: confirmExtractAll()
        case .deleteSystem: confirmDeleteSystemSymbols()
        case let .showAllMissing(name):
            expanded.insert(name)
            render()
        default: break
        }
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) {
            [weak self] _, _, done in
            guard let self else { return done(false) }
            switch dataSource.itemIdentifier(for: indexPath) {
            case let .dsym(uuid):
                try? environment.dsyms.remove(uuid: uuid)
            case let .symbolSet(build):
                try? environment.systemSymbols.remove(build: build)
            default:
                return done(false)
            }
            render()
            done(true)
        }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .dsym, .symbolSet: return UISwipeActionsConfiguration(actions: [delete])
        default: return nil
        }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .missing(image):
            let uuid = image.uuid
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [
                    UIAction(title: String(localized: "Copy UUID"), image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.string = uuid
                    },
                ])
            }
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
                    "That Is Not a Repository",
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
                Toast.show(String(inflecting: "Imported ^[\(imported) symbol file](inflect: true)"))
            } catch is CancellationError {
                render()
            } catch {
                render()
                presentFailure("Could Not Import the Symbols", error)
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
                presentFailure("Could Not Extract System Symbols", error)
            }
        }
    }

    private func confirmExtractAll() {
        let alert = AlertViewController(
            title: String.LocalizationValue("Extract System Symbols"),
            message: String.LocalizationValue("""
            Every image in this build's shared cache is read and stored, which takes more than a \
            gigabyte of space and several minutes.
            """)
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
            message: String.LocalizationValue("""
            The stored tables are removed and system frames go back to addresses until they are \
            extracted again.
            """)
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
            var found = [MissingImage]()
            var seen = Set<String>()
            for summary in library.summaries.value.prefix(20) where summary.kind == .crash {
                guard !Task.isCancelled else { return }
                guard let crash = try? await library.report(for: summary.id).crash else { continue }
                for image in crash.images where ReportBundleBuilder.isThirdParty(image) {
                    guard seen.insert(image.uuid).inserted, store.url(forUUID: image.uuid) == nil else { continue }
                    found.append(MissingImage(uuid: image.uuid, name: image.name))
                }
            }
            guard !Task.isCancelled else { return }
            self?.missing = found.sorted { $0.name < $1.name }
            self?.render(animated: false)
        }
        missingScan = scan
        await scan.value
    }
}

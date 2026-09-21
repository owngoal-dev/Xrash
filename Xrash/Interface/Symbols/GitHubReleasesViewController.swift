import UIKit
import XrashSymbols

/// The releases of one GitHub repository, so a dSYM archive published with a
/// build can be imported without leaving the app.
///
/// Releases with no symbol archive are still listed, greyed: seeing that the
/// tag exists and carries nothing is the answer to "why can I not find it".
final class GitHubReleasesViewController: UITableViewController, UISearchResultsUpdating {
    private let repository: GitHubReleaseSymbols.Repository
    private let store: DSYMStore
    private let onImport: () -> Void

    private var releases = [GitHubReleaseSymbols.Release]()
    private var query = ""
    private var isLoading = false
    /// Archives imported while this page has been up, for the checkmarks.
    private var imported = Set<GitHubReleaseSymbols.Asset>()
    private var dataSource: UITableViewDiffableDataSource<Int, String>!

    init(
        repository: GitHubReleaseSymbols.Repository,
        store: DSYMStore,
        onImport: @escaping () -> Void
    ) {
        self.repository = repository
        self.store = store
        self.onImport = onImport
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = repository.name
        navigationItem.largeTitleDisplayMode = .never

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search releases")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "release")
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, indexPath, tag in
            let cell = table.dequeueReusableCell(withIdentifier: "release", for: indexPath)
            guard let self, let release = releases.first(where: { $0.tag == tag }) else { return cell }
            let hasSymbols = !release.symbolAssets.isEmpty
            var content = cell.defaultContentConfiguration()
            content.text = release.tag
            content.textProperties.color = hasSymbols ? .label : .secondaryLabel
            content.secondaryText = Self.subtitle(of: release)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2
            let isImported = hasSymbols && imported.isSuperset(of: release.symbolAssets)
            content.image = UIImage(
                systemName: isImported ? "checkmark.circle.fill" : hasSymbols ? "arrow.down.circle" : "tag"
            )
            content.imageProperties.tintColor = hasSymbols ? view.tintColor : .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = hasSymbols ? .disclosureIndicator : .none
            return cell
        }
        load()
    }

    // MARK: Loading

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        render()
        Task { [weak self] in
            guard let self else { return }
            defer {
                isLoading = false
                refreshControl?.endRefreshing()
            }
            do {
                releases = try await GitHubReleaseSymbols.releases(in: repository)
                render()
            } catch {
                releases = []
                render(failure: error)
            }
        }
    }

    private func render(failure: Error? = nil) {
        let matches = releases.filter { release in
            release.tag.matches(query) || release.name?.matches(query) == true
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(matches.map(\.tag), toSection: 0)
        let isFirstLoad = dataSource.snapshot().numberOfItems == 0
        dataSource.apply(snapshot, animatingDifferences: !isFirstLoad)

        if !matches.isEmpty {
            tableView.setEmptyState(nil)
        } else if isLoading {
            tableView.setEmptyState(.loading(String(localized: "Loading releases…")))
        } else if let failure {
            tableView.setEmptyState(.message(
                symbolName: "exclamationmark.triangle",
                title: String(localized: "Unable to Load Releases"),
                description: failure.localizedDescription,
                actionTitle: String(localized: "Try Again")
            )) { [weak self] in self?.load() }
        } else if !query.isEmpty {
            tableView.setEmptyState(.message(
                symbolName: "magnifyingglass",
                title: String(localized: "No Results"),
                description: String(localized: "No release matches “\(query)”."),
                actionTitle: nil
            ))
        } else {
            tableView.setEmptyState(.message(
                symbolName: "tag",
                title: String(localized: "No Releases"),
                description: String(localized: "That repository has no releases."),
                actionTitle: nil
            ))
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        render()
    }

    private static func subtitle(of release: GitHubReleaseSymbols.Release) -> String {
        var parts = [String]()
        if let name = release.name {
            parts.append(name)
        }
        if let published = release.published {
            parts.append(ReportFormat.date(published))
        }
        if release.isPrerelease {
            parts.append(String(localized: "Pre-release"))
        }
        parts.append(release.symbolAssets.isEmpty
            ? String(localized: "No dSYMs")
            : String(localized: "dSYMs available"))
        return parts.joined(separator: " · ")
    }

    // MARK: Importing

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let tag = dataSource.itemIdentifier(for: indexPath),
              let release = releases.first(where: { $0.tag == tag })
        else { return }
        let assets = release.symbolAssets
        switch assets.count {
        case 0:
            presentFailure("Unable to Import Symbols", GitHubReleaseSymbols.Failure.noSymbolArchive)
        case 1:
            download(assets[0]) {}
        default:
            navigationController?.pushViewController(
                GitHubAssetsViewController(assets: assets, imported: imported) { [weak self] asset, done in
                    self?.download(asset, done: done)
                },
                animated: true
            )
        }
    }

    /// Stays on the page afterwards: a release is often wanted for more than
    /// one of its archives, and the next tag down may be wanted too.
    private func download(_ asset: GitHubReleaseSymbols.Asset, done: @escaping () -> Void) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            // Not the asset's own name: that is the server's to choose, and the
            // directory above this file is deleted afterwards.
            .appendingPathComponent("symbols.zip")
        let store = store
        Task { [weak self] in
            guard let self else { return }
            // Whatever happens, nothing of the download is left behind.
            defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
            do {
                let imported = try await ProgressCard.run(
                    // The archive list may be the page on top.
                    from: navigationController ?? self,
                    title: String(localized: "Importing Symbols")
                ) { report in
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    report(0, String(localized: "Downloading \(asset.name)…"))
                    try await GitHubReleaseSymbols.download(asset, to: destination) { fraction, bytes in
                        Task { @MainActor in
                            report(fraction, String(localized: "Downloaded \(ReportFormat.byteCount(UInt64(bytes)))"))
                        }
                    }
                    report(nil, String(localized: "Unpacking \(asset.name)…"))
                    return try await DSYMImport.runDetached(at: destination, into: store)
                }
                onImport()
                Toast.show(imported > 0
                    ? String(inflecting: "Imported ^[\(imported) dSYM file](inflect: true)")
                    : String(localized: "Every dSYM in that archive was already imported"))
                self.imported.insert(asset)
                done()
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(snapshot.itemIdentifiers)
                await dataSource.apply(snapshot, animatingDifferences: false)
            } catch is CancellationError {
                return
            } catch {
                (navigationController ?? self).presentFailure("Unable to Import Symbols", error)
            }
        }
    }
}

/// The debug symbol archives of one release, when it carries several.
private final class GitHubAssetsViewController: UITableViewController {
    private let assets: [GitHubReleaseSymbols.Asset]
    private var imported: Set<GitHubReleaseSymbols.Asset>
    /// The second argument is called once the archive is in the store.
    private let onPick: (GitHubReleaseSymbols.Asset, @escaping () -> Void) -> Void

    init(
        assets: [GitHubReleaseSymbols.Asset],
        imported: Set<GitHubReleaseSymbols.Asset>,
        onPick: @escaping (GitHubReleaseSymbols.Asset, @escaping () -> Void) -> Void
    ) {
        self.assets = assets
        self.imported = imported
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Choose Archive")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "asset")
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        assets.count
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(localized: "This release has more than one debug symbol archive.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "asset", for: indexPath)
        let asset = assets[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = asset.name
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryText = ReportFormat.byteCount(UInt64(max(asset.byteCount, 0)))
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(
            systemName: imported.contains(asset) ? "checkmark.circle.fill" : "arrow.down.circle"
        )
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let asset = assets[indexPath.row]
        onPick(asset) { [weak self] in
            self?.imported.insert(asset)
            self?.tableView.reloadRows(at: [indexPath], with: .none)
        }
    }
}

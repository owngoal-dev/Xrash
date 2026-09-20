import Combine
import UIKit
import XrashClient
import XrashReport

/// Every report on the device, sectioned, searchable and filtered. The rows
/// are built from names and header lines only — opening a report is what
/// decodes it, and the subtitles fill in behind the scroll.
final class ReportListViewController: UITableViewController, UISearchResultsUpdating {
    /// Set by the split view controller, which owns where a report opens.
    var openReport: (ReportSummary) -> Void = { _ in }

    let library: ReportLibrary
    let settings: AppSettings

    private let backend: ReportBackend
    private(set) var dataSource: SectionedTableDataSource<ReportSection, String>!
    private var groups = [ReportListGroup]()
    /// What each row currently draws, so a refresh reconfigures the rows that
    /// changed rather than every row it republished.
    private var shown = [String: ReportRowState]()
    private var status = BackendStatus.connecting
    private var observers = Set<AnyCancellable>()

    private let searchText = CurrentValueSubject<String, Never>("")
    private let reasons = CurrentValueSubject<[String: String], Never>([:])
    /// Rows on screen whose report has not been decoded yet.
    private var wantsReason = Set<String>()
    private var reasonPass: Task<Void, Never>?

    /// Kept so the row stays highlighted beside its detail column.
    private var selectedID: String?

    init(
        library: ReportLibrary = AppEnvironment.shared.library,
        settings: AppSettings = .shared,
        backend: ReportBackend = AppEnvironment.shared.backend
    ) {
        self.library = library
        self.settings = settings
        self.backend = backend
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Reports")
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItems = [editButtonItem, filterItem]

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Reports")
        navigationItem.searchController = search
        // The one list where the field stays put: it is the app's front door.
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        clearsSelectionOnViewWillAppear = false
        tableView.allowsMultipleSelectionDuringEditing = true
        // Dragging a row out as a file. `dragInteractionEnabled` is left at the
        // platform's own default — on where there is room for it, off on a
        // phone, where the same long press already belongs to the context menu.
        tableView.dragDelegate = self
        tableView.register(ReportRowCell.self, forCellReuseIdentifier: ReportRowCell.reuseIdentifier)
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)

        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ReportRowCell.reuseIdentifier,
                for: indexPath
            )
            if let state = self?.shown[id] {
                (cell as? ReportRowCell)?.configure(with: state)
            }
            return cell
        }
        dataSource.isEditable = true
        dataSource.header = { [weak self] section in self?.headerTitle(for: section) }
        dataSource.footer = { [weak self] section in self?.footerTitle(for: section) }

        // What the launch wait already listed goes up before the first frame;
        // the pipeline below hops through a background queue and would show an
        // empty table for that frame otherwise.
        if !library.summaries.value.isEmpty {
            apply(ReportListArrangement.groups(for: ReportListInput(
                summaries: library.summaries.value,
                unread: library.unreadIDs.value,
                reasons: reasons.value,
                filter: settings.filter.value,
                searchText: ""
            )))
        }
        observe()
        Task { await refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The toolbar is the bulk-selection bar and nothing else, and a pushed
        // screen leaves it behind: re-hide it unless rows are being selected.
        navigationController?.setToolbarHidden(!isEditing, animated: animated)
        // Coming back from a pushed detail: nothing is open any more.
        if splitViewController?.isCollapsed ?? true {
            selectedID = nil
            if let selected = tableView.indexPathForSelectedRow {
                tableView.deselectRow(at: selected, animated: animated)
            }
        }
    }

    // MARK: Data

    private func observe() {
        library.summaries
            .combineLatest(library.unreadIDs, reasons, settings.filter)
            .combineLatest(searchText)
            .map { combined, text in
                ReportListInput(
                    summaries: combined.0,
                    unread: combined.1,
                    reasons: combined.2,
                    filter: combined.3,
                    searchText: text
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map(ReportListArrangement.groups(for:))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &observers)

        library.isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self, !isLoading else { return }
                tableView.refreshControl?.endRefreshing()
                renderEmptyState()
            }
            .store(in: &observers)

        backend.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status != self.status else { return }
                self.status = status
                renderEmptyState()
                // The sandboxed footer hangs off the last section, and only a
                // fresh layout asks for footer titles again. This fires at
                // most twice in a launch: connecting, then the answer.
                dataSource.applySnapshotUsingReloadData(dataSource.snapshot())
                restoreSelection()
            }
            .store(in: &observers)
    }

    private func apply(_ groups: [ReportListGroup]) {
        self.groups = groups
        let states = Dictionary(
            groups.flatMap(\.rows).map { ($0.summary.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var snapshot = NSDiffableDataSourceSnapshot<ReportSection, String>()
        for group in groups {
            snapshot.appendSections([group.section])
            snapshot.appendItems(group.rows.map(\.summary.id), toSection: group.section)
        }
        let changed = states.compactMap { id, state -> String? in
            guard let previous = shown[id], previous != state else { return nil }
            return id
        }
        if !changed.isEmpty {
            snapshot.reconfigureItems(changed)
        }
        shown = states
        // The first load fills an empty table: animating that is every row
        // sliding in at once. Only a change to a list already on screen moves.
        let isFirstLoad = dataSource.snapshot().numberOfItems == 0
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !isFirstLoad)
        refreshVisibleSectionText()
        restoreSelection()
        renderEmptyState()
        scheduleReasonPass()
    }

    /// A header is asked for its title when its section is laid out and never
    /// again, so the counts in "Apps · 12" would freeze at whatever the first
    /// publish of a refresh happened to hold.
    private func refreshVisibleSectionText() {
        for section in 0 ..< tableView.numberOfSections {
            guard let identifier = dataSource.sectionIdentifier(for: section) else { continue }
            if let header = tableView.headerView(forSection: section) {
                header.textLabel?.text = headerTitle(for: identifier)
                header.setNeedsLayout()
            }
            if let footer = tableView.footerView(forSection: section) {
                footer.textLabel?.text = footerTitle(for: identifier)
                footer.setNeedsLayout()
            }
        }
    }

    func summary(for id: String) -> ReportSummary? {
        shown[id]?.summary
    }

    private func restoreSelection() {
        guard let selectedID, let indexPath = dataSource.indexPath(for: selectedID),
              tableView.indexPathForSelectedRow != indexPath else { return }
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    @objc private func pullToRefresh() {
        Task { await refresh() }
    }

    private func refresh() async {
        await library.refresh()
        await ReportPruner.prune(
            library,
            olderThan: settings.preferences.value.retentionDays,
            from: self
        )
    }

    // MARK: Reasons behind the scroll

    /// The subtitle's reason needs the report decoded, and decoding all 66 of
    /// them on launch is a second of nothing happening. Only the rows a finger
    /// actually stopped on are read, a few at a time.
    private func scheduleReasonPass() {
        let wanted = wantsReason.filter { reasons.value[$0] == nil }
        guard !wanted.isEmpty else { return }
        reasonPass?.cancel()
        reasonPass = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350 * NSEC_PER_MSEC)
            guard !Task.isCancelled, let self else { return }
            await readReasons(for: Array(wanted.prefix(8)))
        }
    }

    private func readReasons(for ids: [String]) async {
        var found = reasons.value
        for id in ids {
            guard !Task.isCancelled else { return }
            guard let report = try? await library.report(for: id) else {
                // Remember the failure too, or the next scroll asks again.
                found[id] = ""
                continue
            }
            found[id] = ReportFormat.reason(for: report) ?? ""
        }
        guard !Task.isCancelled else { return }
        reasons.send(found)
    }

    // MARK: Empty and unavailable states

    private func renderEmptyState() {
        guard groups.isEmpty else { return tableView.setEmptyState(nil) }
        if status == .connecting, library.summaries.value.isEmpty {
            return tableView.setEmptyState(.loading(String(localized: "Connecting…")))
        }
        let needle = searchText.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return tableView.setEmptyState(.message(
                symbolName: "magnifyingglass",
                title: String(localized: "No Results"),
                description: String(localized: "No report matches “\(needle)”."),
                actionTitle: nil
            ))
        }
        if !library.summaries.value.isEmpty {
            tableView.setEmptyState(
                .message(
                    symbolName: "line.3.horizontal.decrease.circle",
                    title: String(localized: "Nothing to Show"),
                    description: String(localized: "Every report is hidden by the current filter."),
                    actionTitle: String(localized: "Show All")
                ),
                action: { [weak self] in self?.settings.changeFilter { $0 = ReportFilter() } }
            )
            return
        }
        tableView.setEmptyState(.message(
            symbolName: "checkmark.circle",
            title: String(localized: "No Reports"),
            description: String(
                localized: "Nothing has crashed here, or the system has already cleared the reports."
            ),
            actionTitle: nil
        ))
    }

    private func headerTitle(for section: ReportSection) -> String? {
        guard let group = groups.first(where: { $0.section == section }) else { return nil }
        return String(localized: "\(ReportListArrangement.title(for: section)) · \(group.rows.count)")
    }

    /// Said once, under the last section, and only when the daemon never
    /// arrived: it explains a short list instead of leaving it a mystery.
    private func footerTitle(for section: ReportSection) -> String? {
        guard status == .sandboxed, groups.last?.section == section else { return nil }
        return String(localized: "Showing only the reports this app can read.")
    }

    // MARK: Search

    func updateSearchResults(for searchController: UISearchController) {
        searchText.send(searchController.searchBar.text ?? "")
    }

    // MARK: Table view

    override func tableView(_: UITableView, willDisplay _: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let state = shown[id], state.reason == nil,
              [.crash, .hang, .resource, .panic].contains(state.summary.kind) else { return }
        wantsReason.insert(id)
        scheduleReasonPass()
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isEditing else { return renderSelectionItems() }
        guard let id = dataSource.itemIdentifier(for: indexPath), let summary = summary(for: id) else { return }
        selectedID = id
        openReport(summary)
    }

    override func tableView(_: UITableView, didDeselectRowAt _: IndexPath) {
        if isEditing {
            renderSelectionItems()
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        navigationItem.searchController?.searchBar.isUserInteractionEnabled = !editing
        // Filtering while selecting would change the rows under the selection.
        navigationItem.rightBarButtonItems = editing ? [editButtonItem] : [editButtonItem, filterItem]
        // The tab bar floats over the bottom of the screen and covers the
        // toolbar, which is where Delete, Share and Mark as Read are: while
        // selecting, the toolbar has that place to itself.
        if #available(iOS 18.0, *) {
            tabBarController?.setTabBarHidden(editing, animated: animated)
        } else {
            tabBarController?.tabBar.isHidden = editing
        }
        navigationController?.setToolbarHidden(!editing, animated: animated)
        renderSelectionItems()
    }

    // MARK: Actions the extension implements

    private lazy var filterItem = UIBarButtonItem(
        image: UIImage(systemName: "line.3.horizontal.decrease"),
        menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.filterElements() ?? [])
            },
        ])
    )
}

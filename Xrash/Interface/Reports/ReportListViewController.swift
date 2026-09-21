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
    /// The same seam for an inbox row: a page listing that process only.
    var openProcess: (String) -> Void = { _ in }

    /// Non-nil on a process page: one process, flat, and no grouping menu.
    let lockedProcessName: String?
    let library: ReportLibrary
    let settings: AppSettings

    private let backend: ReportBackend
    private(set) var dataSource: SectionedTableDataSource<ReportSection, String>!
    private var groups = [ReportListGroup]()
    /// Non-empty only while the inbox is what the list shows.
    private var processes = [ProcessInboxRow]()
    /// What each row currently draws, so a refresh reconfigures the rows that
    /// changed rather than every row it republished.
    private var shown = [String: ReportRowState]()
    private var shownProcesses = [String: ProcessInboxRow]()
    /// Where the sandboxed footer hangs, whichever arrangement is up.
    private var lastSection: ReportSection?
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
        lockedProcessName: String? = nil,
        library: ReportLibrary = AppEnvironment.shared.library,
        backend: ReportBackend = AppEnvironment.shared.backend
    ) {
        self.lockedProcessName = lockedProcessName
        self.library = library
        // Not a default argument: those are evaluated off the main actor.
        settings = .shared
        self.backend = backend
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The process page: this same list locked to one name, with its reports
    /// opening in whatever navigation stack it is put into — pushed on a
    /// phone, the secondary column's root on a wide window, so Back from a
    /// report is the process again rather than the whole table.
    static func processPage(for name: String) -> ReportListViewController {
        let page = ReportListViewController(lockedProcessName: name)
        page.openReport = { [weak page] summary in
            page?.navigationController?.pushViewController(
                ReportDetailViewController(reportID: summary.id),
                animated: true
            )
        }
        return page
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        #if DEBUG
            assert(ReportListArrangement.inboxSelfCheckPassed)
        #endif
        if let lockedProcessName {
            // The bar title is the process; the page is its reports and
            // nothing else, so it carries no search field of its own.
            title = lockedProcessName
            navigationItem.largeTitleDisplayMode = .never
            navigationItem.backButtonDisplayMode = .minimal
        } else {
            title = String(localized: "Reports")
            navigationItem.largeTitleDisplayMode = .always
            navigationController?.navigationBar.prefersLargeTitles = true
            installSearch()
        }
        navigationItem.rightBarButtonItems = [editButtonItem, accessoryItem]

        clearsSelectionOnViewWillAppear = false
        tableView.allowsMultipleSelectionDuringEditing = true
        // Dragging a row out as a file. `dragInteractionEnabled` is left at the
        // platform's own default — on where there is room for it, off on a
        // phone, where the same long press already belongs to the context menu.
        tableView.dragDelegate = self
        tableView.register(ReportRowCell.self, forCellReuseIdentifier: ReportRowCell.reuseIdentifier)
        tableView.register(ProcessInboxCell.self, forCellReuseIdentifier: ProcessInboxCell.reuseIdentifier)
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)

        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            // A process name and a report's path never share a snapshot, so
            // which of the two dictionaries answers is which row this is.
            if let row = self?.shownProcesses[id] {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: ProcessInboxCell.reuseIdentifier,
                    for: indexPath
                )
                (cell as? ProcessInboxCell)?.configure(with: row)
                return cell
            }
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
            apply(ReportListArrangement.content(for: input))
        }
        observe()
        Task { await refresh() }
    }

    private func installSearch() {
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Reports")
        navigationItem.searchController = search
        // The one list where the field stays put: it is the app's front door.
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
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

    /// What the pipeline is fed, for the two places that need it outside the
    /// pipeline: the first frame, and acting on a whole process.
    var input: ReportListInput {
        ReportListInput(
            summaries: library.summaries.value,
            unread: library.unreadIDs.value,
            reasons: reasons.value,
            filter: settings.filter.value,
            searchText: searchText.value,
            lockedProcessName: lockedProcessName
        )
    }

    private func observe() {
        library.summaries
            .combineLatest(library.unreadIDs, reasons, settings.filter)
            .combineLatest(searchText)
            .map { [locked = lockedProcessName] combined, text in
                ReportListInput(
                    summaries: combined.0,
                    unread: combined.1,
                    reasons: combined.2,
                    filter: combined.3,
                    searchText: text,
                    lockedProcessName: locked
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map(ReportListArrangement.content(for:))
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

    private func apply(_ content: ReportListContent) {
        switch content {
        case let .groups(groups): apply(groups: groups)
        case let .processes(rows): apply(processes: rows)
        }
    }

    private func apply(groups: [ReportListGroup]) {
        self.groups = groups
        processes = []
        shownProcesses = [:]
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
        shown = states
        commit(snapshot, reconfiguring: changed)
    }

    /// The inbox: one section, one row per process, the process name as the
    /// row's identity so a new report under a known name moves nothing.
    private func apply(processes rows: [ProcessInboxRow]) {
        groups = []
        shown = [:]
        processes = rows
        let states = Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<ReportSection, String>()
        snapshot.appendSections([.inbox])
        snapshot.appendItems(rows.map(\.name), toSection: .inbox)
        let changed = states.compactMap { name, row -> String? in
            guard let previous = shownProcesses[name], previous != row else { return nil }
            return name
        }
        shownProcesses = states
        commit(snapshot, reconfiguring: changed)
    }

    private func commit(
        _ snapshot: NSDiffableDataSourceSnapshot<ReportSection, String>,
        reconfiguring changed: [String]
    ) {
        var snapshot = snapshot
        if !changed.isEmpty {
            snapshot.reconfigureItems(changed)
        }
        lastSection = snapshot.sectionIdentifiers.last
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

    /// Non-nil when the row is a process rather than a report.
    func process(for id: String) -> ProcessInboxRow? {
        shownProcesses[id]
    }

    /// Every report the list is showing: the rows under the headers, or every
    /// report of every process the inbox has a row for.
    var shownReportIDs: [String] {
        guard processes.isEmpty else {
            let names = Set(processes.map(\.name))
            return ReportListArrangement.admitted(for: input)
                .filter { names.contains($0.summary.processName) }
                .map(\.summary.id)
        }
        return groups.flatMap(\.rows).map(\.summary.id)
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
        guard groups.isEmpty, processes.isEmpty else { return tableView.setEmptyState(nil) }
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

    /// A process page is one process and the inbox one row per process:
    /// neither of them has anything to put in a header.
    private func headerTitle(for section: ReportSection) -> String? {
        guard lockedProcessName == nil,
              let group = groups.first(where: { $0.section == section }) else { return nil }
        return String(localized: "\(ReportListArrangement.title(for: section)) · \(group.rows.count)")
    }

    /// Said once, under the last section, and only when the daemon never
    /// arrived: it explains a short list instead of leaving it a mystery.
    private func footerTitle(for section: ReportSection) -> String? {
        guard status == .sandboxed, lastSection == section else { return nil }
        return String(localized: "Showing only the reports this app can read.")
    }

    // MARK: Search

    func updateSearchResults(for searchController: UISearchController) {
        searchText.send(searchController.searchBar.text ?? "")
    }

    // MARK: Table view

    override func tableView(_: UITableView, willDisplay _: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        // An inbox row's subtitle is its newest report's reason, read the same
        // way a report row's is.
        if let row = shownProcesses[id] {
            guard row.latestReason == nil, Self.hasReason(row.latest) else { return }
            wantsReason.insert(row.latest.id)
            return scheduleReasonPass()
        }
        guard let state = shown[id], state.reason == nil, Self.hasReason(state.summary) else { return }
        wantsReason.insert(id)
        scheduleReasonPass()
    }

    private static func hasReason(_ summary: ReportSummary) -> Bool {
        [.crash, .hang, .resource, .panic].contains(summary.kind)
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isEditing else { return renderSelectionItems() }
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        selectedID = id
        if let row = shownProcesses[id] {
            return openProcess(row.name)
        }
        guard let summary = summary(for: id) else { return }
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
        navigationItem.rightBarButtonItems = editing ? [editButtonItem] : [editButtonItem, accessoryItem]
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

    /// The filter menu on the list, the trash on a process page: that page is
    /// one process, so there is nothing left to group or filter there.
    private var accessoryItem: UIBarButtonItem {
        lockedProcessName == nil ? filterItem : deleteProcessItem
    }

    private lazy var filterItem = UIBarButtonItem(
        image: UIImage(systemName: "line.3.horizontal.decrease"),
        menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.filterElements() ?? [])
            },
        ])
    )

    private lazy var deleteProcessItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            primaryAction: UIAction { [weak self] _ in
                guard let self, let lockedProcessName else { return }
                confirmDeleteProcess(lockedProcessName)
            }
        )
        item.tintColor = .systemRed
        item.accessibilityLabel = String(localized: "Delete All Reports")
        return item
    }()
}

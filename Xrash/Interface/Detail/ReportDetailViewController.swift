import Combine
import SnapKit
import Then
import UIKit
import XrashBlame
import XrashReport

/// One report, three ways of looking at the same file, switched in place by
/// the first group of the ••• menu rather than by pushing a second screen that
/// says the same thing again.
///
/// Two flavours, and the difference is ownership. A report *in the library*
/// can be symbolicated, deleted and turned into a crash report to send. A
/// report that came out of a saved bundle is shown as it was filed and none of
/// those verbs apply to it.
final class ReportDetailViewController: UIViewController {
    enum Segment {
        /// The table: what died, who is suspected, the crashed stack.
        case summary
        /// The whole report rendered as the `.crash` text everyone knows.
        case details
        /// The file as it sits on disk.
        case raw
    }

    private let settings: AppSettings

    private let library: ReportLibrary?
    private let reportID: String?
    private let fixedTitle: String?

    private var content: DetailContent?
    private var summary: ReportSummary?
    private var isSymbolicating = false
    private var hasSymbolicated = false
    private var loadTask: Task<Void, Never>?

    private let summaryChild = ReportSummaryViewController()
    private var detailsChild: ReportTextViewController?
    private var rawChild: ReportTextViewController?
    private var shownChild: UIViewController?
    private var segment = Segment.summary

    /// The first group of the ••• menu: the three views, the current one
    /// checked. The bar's title is the process, not a control.
    var segmentElements: [UIMenuElement] {
        let choices: [(Segment, String, String)] = [
            (.summary, String(localized: "Summary"), "list.bullet.rectangle"),
            (.details, String(localized: "Details"), "doc.plaintext"),
            (.raw, String(localized: "Raw"), "curlybraces"),
        ]
        return choices.map { choice, title, symbol in
            UIAction(
                title: title,
                image: UIImage(systemName: symbol),
                state: choice == segment ? .on : .off,
            ) { [weak self] _ in self?.select(choice) }
        }
    }

    /// A report in the library: decoded, symbolicated and marked read here.
    init(reportID: String) {
        library = AppEnvironment.shared.library
        settings = .shared
        self.reportID = reportID
        fixedTitle = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// A report that lives elsewhere — a member of a saved bundle. Shown as it
    /// is; library actions (delete, Report Crash) are absent.
    init(report: Report, title: String) {
        library = nil
        settings = .shared
        reportID = nil
        fixedTitle = title
        super.init(nibName: nil, bundle: nil)
        content = DetailContent(report: report)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// What the bar menus render from. Nil until the file has been decoded.
    var decodedReport: Report? {
        content?.report
    }

    /// Set only for a report the library owns — the flavour that can be
    /// deleted, re-symbolicated and turned into a crash report to send.
    var libraryReportID: String? {
        reportID
    }

    /// `Fila-2026-09-08-191717`, the stem every share attachment is named for.
    var shareStem: String? {
        summary.map { ReportFormat.fileStem(for: $0.processName, date: $0.date) }
    }

    /// The text viewer's own menu, offered only while one is on screen.
    var textViewerElements: [UIMenuElement] {
        (shownChild as? ReportTextViewController)?.menuElements() ?? []
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        title = fixedTitle ?? String(localized: "Report")

        summaryChild.show(content, summary: summary)
        select(.summary)
        renderBarItems()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Every verb of this screen lives in the ••• menu; there is no toolbar.
        navigationController?.setToolbarHidden(true, animated: animated)
        reportID.map { library?.markRead($0) }
    }

    deinit {
        loadTask?.cancel()
    }

    // MARK: Segments

    /// The Raw segment, for the rows that used to open a second screen.
    func showRawSegment() {
        select(.raw)
    }

    private func select(_ segment: Segment) {
        self.segment = segment
        show(textChild(for: segment) ?? summaryChild)
        renderBarItems()
    }

    /// Built once and kept: re-rendering a megabyte of crash text on every
    /// flick between the segments is the one thing that would make them slow.
    private func textChild(for segment: Segment) -> ReportTextViewController? {
        guard let report = content?.report else { return nil }
        switch segment {
        case .summary:
            return nil
        case .details:
            if let detailsChild {
                return detailsChild
            }
            let child = makeTextChild(text: ReportRenderer.crashText(report), language: .plain)
            detailsChild = child
            return child
        case .raw:
            if let rawChild {
                return rawChild
            }
            let isJSON = report.rawText.hasPrefix("{")
            let child = makeTextChild(text: report.rawText, language: isJSON ? .json : .plain)
            if isJSON {
                child.formattedText = { ReportRenderer.prettyJSON(report) }
            }
            rawChild = child
            return child
        }
    }

    private func makeTextChild(text: String, language: ReportTextViewController.Language) -> ReportTextViewController {
        let child = ReportTextViewController(
            title: title ?? String(localized: "Report"),
            text: text,
            language: language,
        )
        // The container owns the bar; a child that installed its own would
        // fight it for the same navigation item.
        child.installsBarItems = false
        return child
    }

    private func show(_ child: UIViewController) {
        guard shownChild !== child else { return }
        shownChild?.willMove(toParent: nil)
        shownChild?.view.removeFromSuperview()
        shownChild?.removeFromParent()
        addChild(child)
        view.addSubview(child.view)
        child.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        child.didMove(toParent: self)
        shownChild = child
    }

    // MARK: Loading

    private func load() {
        guard let reportID, let library else {
            // A bundle member arrives decoded, so the only work left is the
            // summary it has no library row for — and handing it down, which
            // `viewDidLoad` did before there was one to hand.
            summarise()
            refreshChildren()
            return
        }
        summary = library.summaries.value.first { $0.id == reportID }
        title = summary?.processName ?? String(localized: "Report")
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await library.report(for: reportID)
                content = DetailContent(report: report)
                summarise()
                refreshChildren()
                select(Segment(settings.preferences.value.defaultView))
                renderBarItems()
            } catch {
                summaryChild.showFailure()
                return
            }
            await loadSuspects()
            await symbolicate(force: false)
            await loadSimilar()
        }
    }

    private func summarise() {
        guard let report = content?.report else { return }
        let name = report.crash?.process.name
        title = (name?.isEmpty == false ? name : nil) ?? fixedTitle ?? summary?.processName
            ?? String(localized: "Report")
        if summary == nil {
            // A bundle member has no library row; one is made so the header
            // cell and the icon lookup have the same input either way.
            var made = ReportSummary(
                id: reportID ?? report.header.incidentID ?? UUID().uuidString,
                fileName: "",
                processName: title ?? "",
                kind: report.kind,
                group: report.crash?.process.bundleID == nil ? .service : .app,
                date: report.header.timestamp ?? Date(),
                byteCount: UInt64(report.rawText.utf8.count),
                isSynced: false,
            )
            made.bundleID = report.crash?.process.bundleID ?? report.header.bundleID
            made.appVersion = report.header.appVersion
            summary = made
        }
    }

    /// Hands every child the report as it now stands. Details is re-rendered
    /// because symbolication is exactly what changes it.
    private func refreshChildren() {
        summaryChild.show(content, summary: summary)
        if let report = content?.report, let detailsChild {
            detailsChild.replaceText(ReportRenderer.crashText(report))
        }
    }

    private func loadSuspects() async {
        guard let crash = content?.report.crash else { return }
        let packages = AppEnvironment.shared.packages
        let suspects = await Task.detached(priority: .userInitiated) {
            Blame.suspects(in: crash, packages: packages)
        }.value
        guard !Task.isCancelled else { return }
        content?.suspects = suspects
        refreshChildren()
    }

    /// Other reports that are the same bug. Only reports of the same process
    /// are candidates, and only those are decoded — comparing signatures over
    /// the whole device would mean decoding every file on it.
    private func loadSimilar() async {
        guard let library, let reportID, let crash = content?.report.crash,
              let processName = summary?.processName else { return }
        let signature = ReportExplainer.signature(of: crash)
        let candidates = library.summaries.value
            .filter { $0.id != reportID && $0.processName == processName && $0.kind == .crash }
            .prefix(30)
        var matches = [ReportSummary]()
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            guard let other = try? await library.report(for: candidate.id), let otherCrash = other.crash,
                  ReportExplainer.signature(of: otherCrash) == signature else { continue }
            matches.append(candidate)
        }
        guard !Task.isCancelled, !matches.isEmpty else { return }
        content?.similar = matches
        refreshChildren()
    }

    // MARK: Symbolication

    // ponytail: a spinner in the bar, no count; move to ProgressCard.run if
    // symbolicating a report ever needs a way to be cancelled.
    /// `announces` is the button: a pass the reader asked for says when it is
    /// done, the one that runs by itself on open stays quiet.
    private func symbolicate(force: Bool, announces: Bool = false) async {
        guard let library, let reportID else { return }
        isSymbolicating = true
        renderBarItems()
        let report = try? await library.symbolicatedReport(for: reportID, force: force) { _ in }
        isSymbolicating = false
        guard let report else { return renderBarItems() }
        hasSymbolicated = true
        content?.report = report
        refreshChildren()
        renderBarItems()
        if announces {
            Toast.show(String(localized: "Symbolicated"))
        }
    }

    // MARK: Bar items

    /// The ••• menu's first item. Nil for a report that has no stack to name,
    /// or while a pass is already running.
    var symbolicateAction: UIAction? {
        guard reportID != nil, content?.report.crash != nil, !isSymbolicating else { return nil }
        return UIAction(
            title: hasSymbolicated ? String(localized: "Re-symbolicate") : String(localized: "Symbolicate"),
            image: UIImage(systemName: "function"),
        ) { [weak self] _ in
            Task { await self?.symbolicate(force: self?.hasSymbolicated == true, announces: true) }
        }
    }

    private lazy var spinnerItem = UIBarButtonItem(customView: UIActivityIndicatorView(style: .medium).then {
        $0.startAnimating()
    })

    func renderBarItems() {
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.moreElements() ?? [])
                },
            ]),
        )
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItems = isSymbolicating ? [more, spinnerItem] : [more]
    }
}

extension ReportDetailViewController.Segment {
    init(_ preference: ReportPreferences.DefaultView) {
        switch preference {
        case .summary: self = .summary
        case .details: self = .details
        case .raw: self = .raw
        }
    }
}

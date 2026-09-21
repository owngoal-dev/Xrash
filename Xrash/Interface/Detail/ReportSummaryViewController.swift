import AlertController
import UIKit
import XrashBlame
import XrashReport

/// The Summary segment of a report: what died, who is suspected, the crashed
/// stack, and a way into the threads and images. It owns no loading — the
/// container hands it a decoded report and hands it a new one after
/// symbolication.
final class ReportSummaryViewController: UITableViewController {
    private var content: DetailContent?
    private var summary: ReportSummary?

    private var dataSource: SectionedTableDataSource<DetailSection, DetailItem>!

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(ReportHeaderCell.self, forCellReuseIdentifier: ReportHeaderCell.reuseIdentifier)
        tableView.register(FrameCell.self, forCellReuseIdentifier: FrameCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "value")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            self?.cell(for: item, at: indexPath, in: tableView) ?? UITableViewCell()
        }
        tableView.register(
            CollapsibleSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: CollapsibleSectionHeaderView.reuseIdentifier
        )
        rebuild()
    }

    // MARK: Folding

    /// Remembered for this screen only: the next report opens unfolded.
    private var collapsed = Set<DetailSection>()

    override func tableView(_ tableView: UITableView, viewForHeaderInSection index: Int) -> UIView? {
        guard let section = dataSource.sectionIdentifier(for: index), let title = section.title else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: CollapsibleSectionHeaderView.reuseIdentifier
        ) as? CollapsibleSectionHeaderView
        header?.configure(title: title, isCollapsed: collapsed.contains(section))
        header?.onToggle = { [weak self, weak header] in
            guard let self else { return }
            collapsed.formSymmetricDifference([section])
            header?.configure(title: title, isCollapsed: collapsed.contains(section))
            rebuild(animated: true)
        }
        return header
    }

    override func tableView(_: UITableView, heightForHeaderInSection index: Int) -> CGFloat {
        dataSource.sectionIdentifier(for: index)?.title == nil ? 0 : UITableView.automaticDimension
    }

    /// The whole state of this screen, replaced rather than patched: a
    /// symbolicated report is a new value, not an edit of the old one.
    func show(_ content: DetailContent?, summary: ReportSummary?) {
        self.content = content
        self.summary = summary
        guard isViewLoaded else { return }
        rebuild()
    }

    func showFailure() {
        loadViewIfNeeded()
        tableView.setEmptyState(.message(
            symbolName: "exclamationmark.triangle",
            title: String(localized: "Unable to Read This Report"),
            description: String(localized: "The file could not be opened or understood."),
            actionTitle: nil
        ))
    }

    private func rebuild(animated: Bool = false) {
        guard let content else { return }
        tableView.setEmptyState(nil)
        var snapshot = NSDiffableDataSourceSnapshot<DetailSection, DetailItem>()
        for entry in DetailLayout.sections(for: content) {
            snapshot.appendSections([entry.section])
            // A folded section keeps its header and gives up its rows.
            if !collapsed.contains(entry.section) {
                snapshot.appendItems(entry.items, toSection: entry.section)
            }
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: Cells

    private func cell(for item: DetailItem, at indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        guard let content else { return UITableViewCell() }
        switch item {
        case .header:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ReportHeaderCell.reuseIdentifier,
                for: indexPath
            )
            if let summary {
                (cell as? ReportHeaderCell)?.configure(with: content.report, summary: summary)
            }
            return cell
        case let .frame(list, index):
            let cell = tableView.dequeueReusableCell(withIdentifier: FrameCell.reuseIdentifier, for: indexPath)
            if let crash = content.report.crash, let frame = frame(list, index, in: crash) {
                (cell as? FrameCell)?.configure(
                    with: frame,
                    index: index,
                    in: crash,
                    emphasis: emphasis(of: frame, in: crash)
                )
                (cell as? FrameCell)?.menuProvider = { [weak self] in self?.frameMenu(frame, in: crash) ?? [] }
            }
            return cell
        default:
            let cell = tableView.dequeueReusableCell(withIdentifier: "value", for: indexPath)
            configureValueCell(cell, item: item, content: content)
            return cell
        }
    }

    private static let rowInset: CGFloat = 11

    private func configureValueCell(_ cell: UITableViewCell, item: DetailItem, content: DetailContent) {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryType = .none
        cell.selectionStyle = .none

        let report = content.report
        switch item {
        case .explanation:
            configuration.text = String(localized: "What Happened")
            configuration.secondaryText = report.crash.map(ReportExplainer.explanation(for:))
        case .exception:
            configuration.text = String(localized: "Exception")
            configuration.secondaryText = [
                ReportFormat.reason(for: report),
                report.crash?.exception?.subtype,
                report.crash?.exception?.message,
            ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
            configuration.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.smallSystemFontSize, weight: .regular
            )
        case .termination:
            configuration.text = String(localized: "Termination")
            let termination = report.crash?.termination
            configuration.secondaryText = ([
                [termination?.namespace, termination?.indicator].compactMap(\.self).joined(separator: " "),
                termination?.byProcess.map { String(localized: "Ended by \($0)") },
            ].compactMap(\.self) + (termination?.reasons ?? []))
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case .date:
            configuration.text = String(localized: "Date")
            configuration.secondaryText = ReportFormat.fullDate(
                report.header.timestamp ?? summary?.date ?? Date()
            )
        case .system:
            configuration.text = String(localized: "System")
            configuration.secondaryText = [
                report.crash?.device.model,
                report.crash?.device.osTrain ?? report.header.osVersion,
                report.crash?.device.osBuild.map { "(\($0))" },
            ].compactMap(\.self).joined(separator: " · ")
        case .incident:
            configuration.text = String(localized: "Incident")
            configuration.secondaryText = report.header.incidentID
            configuration.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.smallSystemFontSize, weight: .regular
            )
        case let .applicationInfo(index):
            configuration.text = report.crash?.applicationInfo[index]
            configuration.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.smallSystemFontSize, weight: .regular
            )
        case let .suspect(id):
            let suspect = content.suspects.first { $0.id == id }
            configuration.text = suspect?.imageName
            configuration.secondaryText = suspect.map(describe(_:))
            configuration.image = UIImage(systemName: "exclamationmark.circle")
            configuration.imageProperties.tintColor = .systemOrange
            cell.selectionStyle = .default
            // One thing to do happens on the tap; several open as a list, and
            // the row says so.
            if suspect.map({ suspectActions($0).count > 1 }) == true {
                cell.accessoryType = .disclosureIndicator
            }
        case .showAllFrames:
            configuration.text = String(localized: "Show All Frames")
            configuration.textProperties.color = .tintColor
            cell.selectionStyle = .default
        case let .thread(index):
            let thread = report.crash?.threads[index]
            configuration.text = threadTitle(thread)
            configuration.secondaryText = thread.flatMap(threadSubtitle(_:))
            configuration.secondaryTextProperties.numberOfLines = 1
            configuration.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .binaryImages:
            configuration.text = String(localized: "Binary Images")
            configuration.secondaryText = String(
                inflecting: "^[\(report.crash?.images.count ?? 0) image](inflect: true)"
            )
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .linkedReports:
            configuration.text = String(localized: "Similar Reports")
            configuration.secondaryText = String(localized: "\(content.linkedCount) more of the same crash")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case let .jetsamProcess(index):
            let process = report.jetsam?.processes[index]
            let pages = process?.residentPages ?? 0
            let bytes = pages * (report.jetsam?.pageSize ?? 16384)
            configuration.text = process?.name
            configuration.secondaryText = [
                ReportFormat.byteCount(bytes),
                process?.reason,
            ].compactMap(\.self).joined(separator: " · ")
            configuration.secondaryTextProperties.color = process?.reason == nil ? .secondaryLabel : .systemOrange
        case .panicText:
            configuration.text = report.panic?.panicString
            configuration.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.smallSystemFontSize, weight: .regular
            )
        case .viewContents:
            configuration.text = String(localized: "View Contents")
            configuration.textProperties.color = .tintColor
            cell.selectionStyle = .default
        case .header, .frame:
            break
        }
        // A tap copies what the row shows, so a row showing nothing is inert.
        if item.isCopyable, displayedText(of: configuration)?.isEmpty == false {
            cell.selectionStyle = .default
        }
        // The system's own margins follow the fonts and the line count, so a
        // monospaced row, a wrapped row and a one-line row each came out a
        // different height apart. One inset for every row of this table.
        configuration.directionalLayoutMargins.top = Self.rowInset
        configuration.directionalLayoutMargins.bottom = Self.rowInset
        configuration.textToSecondaryTextVerticalPadding = 3
        cell.contentConfiguration = configuration
    }

    // MARK: Reading the model

    private func frame(_ list: DetailFrameList, _ index: Int, in crash: CrashReport) -> Frame? {
        let frames = list == .crashedThread ? (crash.faultingThread?.frames ?? []) : crash.lastExceptionBacktrace
        return frames.indices.contains(index) ? frames[index] : nil
    }

    /// Only the frames worth looking at first are marked. Everything else
    /// stays at full contrast — a stack nobody can read is not a stack.
    private func emphasis(of frame: Frame, in crash: CrashReport) -> FrameCell.Emphasis {
        guard let index = frame.imageIndex, crash.images.indices.contains(index) else { return .ordinary }
        let image = crash.images[index]
        if content?.suspects.contains(where: { $0.id == image.path }) == true {
            return .suspect
        }
        if image.path == crash.process.path {
            return .own
        }
        return FrameCell.isSystem(image) ? .ordinary : .own
    }

    private func threadTitle(_ thread: ReportThread?) -> String? {
        guard let thread else { return nil }
        return thread.isTriggered
            ? String(localized: "Thread \(thread.index) · Crashed")
            : String(localized: "Thread \(thread.index)")
    }

    /// What tells one thread from the next: its name, its queue, and — since
    /// most threads have neither — what it was doing, which is its top frame.
    private func threadSubtitle(_ thread: ReportThread) -> String? {
        let labels = [thread.name, thread.queue].compactMap(\.self).filter { !$0.isEmpty }
        // Unsymbolicated, the top frame is still its program counter.
        let top = thread.frames.first.map { $0.symbol ?? ReportFormat.address($0.address) }
        let named = labels.isEmpty ? [top].compactMap(\.self) : labels
        let parts = NSOrderedSet(array: named).array.compactMap { $0 as? String }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func describe(_ suspect: Suspect) -> String {
        let reasons = suspect.reasons.map(reasonLabel(_:)).joined(separator: " · ")
        guard let owner = suspect.owner else { return reasons }
        let package = [owner.name ?? owner.identifier, owner.version].compactMap(\.self).joined(separator: " ")
        return [package, reasons].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func reasonLabel(_ reason: Suspect.Reason) -> String {
        switch reason {
        case .onFaultingStack: String(localized: "On the crashed stack")
        case .inExceptionBacktrace: String(localized: "In the exception backtrace")
        case .injectedTweak: String(localized: "Injected tweak")
        case .thirdPartyImage: String(localized: "Not Apple’s code")
        case .recentlyInstalled: String(localized: "Installed recently")
        }
    }

    // MARK: Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath), let content else { return }
        switch item {
        case let .showAllFrames(list):
            self.content?.expanded.insert(list)
            rebuild()
        case let .thread(index):
            guard let crash = content.report.crash, crash.threads.indices.contains(index) else { return }
            push(ThreadViewController(thread: crash.threads[index], crash: crash))
        case .binaryImages:
            guard let crash = content.report.crash else { return }
            push(ImagesViewController(crash: crash, packages: AppEnvironment.shared.packages))
        case .linkedReports:
            push(RelatedReportsViewController(summaries: content.similar))
        case .viewContents:
            (parent as? ReportDetailViewController)?.showRawSegment()
        case let .suspect(id):
            guard let suspect = content.suspects.first(where: { $0.id == id }) else { return }
            let actions = suspectActions(suspect)
            // One thing to do is done, not asked about: the row that only
            // copies its path still copies it on the tap.
            guard actions.count > 1 else {
                actions.first?.run()
                return
            }
            presentSuspectActions(suspect, actions)
        case _ where item.isCopyable:
            guard let text = displayedText(at: indexPath), !text.isEmpty else { return }
            UIPasteboard.general.string = text
            Toast.show(String(localized: "Copied"))
        default:
            break
        }
    }

    /// What the row is showing: its value if it has one, else the line itself —
    /// a line of application information and a panic string *are* the line.
    private func displayedText(of configuration: UIListContentConfiguration) -> String? {
        configuration.secondaryText ?? configuration.text
    }

    /// Read back off the cell, so what lands on the clipboard is what the
    /// reader is looking at rather than a second assembly of it.
    private func displayedText(at indexPath: IndexPath) -> String? {
        guard let configuration = tableView.cellForRow(at: indexPath)?
            .contentConfiguration as? UIListContentConfiguration else { return nil }
        return displayedText(of: configuration)
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath), let content else { return nil }
        let elements: [UIMenuElement]
        switch item {
        case let .suspect(id):
            guard let suspect = content.suspects.first(where: { $0.id == id }) else { return nil }
            elements = suspectActions(suspect).map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { _ in action.run() }
            }
        case .panicText:
            // A tap copies the panic string; the whole file is one screen away.
            elements = [
                UIAction(title: String(localized: "View Raw"), image: UIImage(systemName: "curlybraces")) {
                    [weak self] _ in
                    (self?.parent as? ReportDetailViewController)?.showRawSegment()
                },
            ]
        default:
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: elements) }
    }

    // MARK: Suspects

    /// One list of what a suspect row offers, so the tap, the card and the
    /// context menu cannot come to different answers. Copy Path is always
    /// there; the rest depend on what dpkg knows and which sibling apps are
    /// installed.
    private struct SuspectAction {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    private func suspectActions(_ suspect: Suspect) -> [SuspectAction] {
        var actions = [SuspectAction]()
        if let owner = suspect.owner, owner.maintainerAddress != nil {
            actions.append(SuspectAction(title: String(localized: "Mail Maintainer"), symbol: "envelope") {
                [weak self] in
                guard let self, let report = content?.report,
                      let stem = (parent as? ReportDetailViewController)?.shareStem else { return }
                MaintainerMail.present(owner: owner, report: report, stem: stem, from: self)
            })
        }
        if let owner = suspect.owner, let irisin = SiblingApps.packageInIrisin(identifier: owner.identifier) {
            actions.append(SuspectAction(title: String(localized: "Show Package in Irisin"), symbol: "shippingbox") {
                SiblingApps.open(irisin)
            })
        }
        if let fila = SiblingApps.revealInFila(path: suspect.id) {
            actions.append(SuspectAction(title: String(localized: "Reveal in Fila"), symbol: "folder") {
                SiblingApps.open(fila)
            })
        }
        actions.append(SuspectAction(title: String(localized: "Copy Path"), symbol: "doc.on.doc") {
            UIPasteboard.general.string = suspect.id
            Toast.show(String(localized: "Path Copied"))
        })
        return actions
    }

    /// The card of them. Alerts go through `AlertController` in this app, which
    /// presents in the middle of the window and needs no popover anchor — an
    /// action sheet without one raises on an iPad.
    private func presentSuspectActions(_ suspect: Suspect, _ actions: [SuspectAction]) {
        let alert = AlertViewController(title: suspect.imageName, message: suspect.id) { context in
            for action in actions {
                context.addAction(title: action.title) { context.dispose { action.run() } }
            }
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
        }
        present(alert, animated: true)
    }

    /// A child is inside the container's navigation stack, so pushing from
    /// here lands in the same place a push from the container would.
    private func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }
}

extension UIViewController {
    /// The menu a frame row opens on a tap: what the frame names, and the
    /// image it came out of.
    func frameMenu(_ frame: Frame, in crash: CrashReport) -> [UIMenuElement] {
        var elements = [UIMenuElement]()
        if let symbol = frame.symbol {
            elements.append(UIAction(
                title: String(localized: "Copy Symbol"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = symbol
                Toast.show(String(localized: "Copied"))
            })
        }
        elements.append(UIAction(
            title: String(localized: "Copy Address"),
            image: UIImage(systemName: "number")
        ) { _ in
            UIPasteboard.general.string = ReportFormat.address(frame.address)
            Toast.show(String(localized: "Copied"))
        })
        if let index = frame.imageIndex, crash.images.indices.contains(index) {
            let image = crash.images[index]
            elements.append(UIAction(
                title: String(localized: "Show Image"),
                image: UIImage(systemName: "shippingbox")
            ) { [weak self] _ in
                guard let self else { return }
                let images = ImagesViewController(crash: crash, packages: AppEnvironment.shared.packages)
                images.focus(on: image.uuid)
                navigationController?.pushViewController(images, animated: true)
            })
        }
        return elements
    }
}

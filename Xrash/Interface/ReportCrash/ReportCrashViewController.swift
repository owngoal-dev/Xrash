import Combine
import Then
import UIKit
import XrashBlame
import XrashBundle
import XrashReport
import XrashSymbols
import XrashSystemState

/// The "Report Crash" form: a primary report, the crashes linked to it, notes
/// and what to include — one `.xrashreport` out. Presented as a form sheet
/// inside a navigation controller.
///
/// The point of the screen is the linking. A system crash rarely happens in
/// one process on its own, and a bug report that carries only the process the
/// user happened to tap on throws away the half that explains it.
final class ReportCrashViewController: UITableViewController {
    private enum Section: Hashable {
        case primary, linked, suggestions, details, include
    }

    private enum Row: Hashable {
        case primary
        case linked(String)
        case suggestion(String)
        case addOther
        case title
        case notes
        case include(Include)
        case reviewSystemState
    }

    /// `reports` is one switch over all three forms of a report — the original
    /// file, the rendered crash text and the JSON. Three switches asked the
    /// person to pick a file format for a reader they have never met.
    private enum Include: Hashable, CaseIterable {
        case reports, pdf, binaries, dsyms, systemState
    }

    private let primaryID: String
    private let environment: AppEnvironment

    private var primarySummary: ReportSummary?
    private var primaryReport: Report?
    private var linked = [ReportBundleBuilder.LinkedReport]()
    private var suggestions = [LinkSuggestion]()
    private var bundleTitle = ""
    private var notes = ""
    private var options = BundleOptions()
    private var includesDSYMs = false
    private var hasMatchingDSYM = false
    private var binaryByteCount: UInt64 = 0
    /// Collected once, on the first need, and kept for the life of the form:
    /// what the Review screen showed is what the archive ships.
    private var systemFiles: [SystemStateFile]?
    private var openingCollection: Task<Void, Never>?
    private let systemStateDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SystemState", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    private var dataSource: SectionedTableDataSource<Section, Row>!

    /// `primaryID` is the `ReportSummary.id` of a report in the library.
    init(primaryID: String, environment: AppEnvironment = .shared) {
        self.primaryID = primaryID
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The collection outlives the archive write and nothing else; the form
    /// closing is the last thing that could want it.
    deinit {
        try? FileManager.default.removeItem(at: systemStateDirectory)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Report Crash")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        let create = UIBarButtonItem(
            title: String(localized: "Create"),
            primaryAction: UIAction { [weak self] _ in self?.create() },
        )
        create.style = .done
        create.isEnabled = false
        navigationItem.rightBarButtonItem = create

        tableView.register(BundleReportCell.self, forCellReuseIdentifier: BundleReportCell.reuseIdentifier)
        tableView.register(FormTextFieldCell.self, forCellReuseIdentifier: FormTextFieldCell.reuseIdentifier)
        tableView.register(FormTextViewCell.self, forCellReuseIdentifier: FormTextViewCell.reuseIdentifier)
        tableView.register(FormSwitchCell.self, forCellReuseIdentifier: FormSwitchCell.reuseIdentifier)
        // Every row is dequeued: reconfiguring a row whose provider answers
        // with a cell the table did not hand out raises in UIKit.
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.actionCellIdentifier)
        tableView.keyboardDismissMode = .interactive

        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] table, indexPath, row in
            self?.cell(for: row, at: indexPath, in: table) ?? UITableViewCell()
        }
        dataSource.header = { [weak self] in self?.header(for: $0) }
        dataSource.footer = { [weak self] in self?.footer(for: $0) }
        // Only linked rows offer a swipe action; the rest answer nil below.
        dataSource.isEditable = true
        render()
        Task { await load() }
        collectSystemStateOnOpening()
    }

    // MARK: Loading

    private func load() async {
        let library = environment.library
        guard let summary = library.summaries.value.first(where: { $0.id == primaryID }) else { return }
        primarySummary = summary
        bundleTitle = String(localized: "\(summary.processName) crash on \(ReportFormat.fullDate(summary.date))")
        navigationItem.rightBarButtonItem?.isEnabled = true
        // The rows themselves already exist; only what they say has changed,
        // and an identical snapshot would never redraw them.
        reconfigure([.primary, .title])

        primaryReport = try? await library.report(for: primaryID)
        suggestions = CrashCorrelation.suggestions(
            for: summary,
            primaryCrash: primaryReport?.crash,
            among: library.summaries.value,
        )
        if let crash = primaryReport?.crash {
            hasMatchingDSYM = crash.images.contains { environment.dsyms.url(forUUID: $0.uuid) != nil }
            let images = ReportBundleBuilder.includedImages(in: crash)
            binaryByteCount = await Task.detached { ReportBundleBuilder.estimatedByteCount(of: images) }.value
        }
        render()
        reconfigure([.primary])
    }

    private func reconfigure(_ rows: [Row]) {
        var snapshot = dataSource.snapshot()
        let present = rows.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Rendering

    private func render() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.primary])
        snapshot.appendItems([.primary], toSection: .primary)

        snapshot.appendSections([.linked])
        snapshot.appendItems(linked.map { Row.linked($0.id) } + [.addOther], toSection: .linked)

        let unlinked = suggestions.filter { suggestion in
            suggestion.id != primaryID && !linked.contains { $0.id == suggestion.id }
        }
        if !unlinked.isEmpty {
            snapshot.appendSections([.suggestions])
            snapshot.appendItems(unlinked.map { Row.suggestion($0.id) }, toSection: .suggestions)
        }

        snapshot.appendSections([.details])
        snapshot.appendItems([.title, .notes], toSection: .details)

        snapshot.appendSections([.include])
        // A switch nothing on this machine could answer is not offered at all.
        var includes = Include.allCases
            .filter { $0 != .dsyms || hasMatchingDSYM }
            .filter { $0 != .systemState || SystemState.isAvailable }
            .map { Row.include($0) }
        if options.includesSystemState, SystemState.isAvailable {
            includes.append(.reviewSystemState)
        }
        snapshot.appendItems(includes, toSection: .include)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static let actionCellIdentifier = "action"

    private func cell(for row: Row, at indexPath: IndexPath, in table: UITableView) -> UITableViewCell {
        switch row {
        case .primary:
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier,
                for: indexPath,
            ) as! BundleReportCell
            if let primarySummary {
                let reason = primaryReport.flatMap(ReportFormat.reason)
                cell.configure(
                    with: primarySummary,
                    detail: ReportFormat.subtitle(for: primarySummary, reason: reason),
                )
            }
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell

        case let .linked(id):
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier,
                for: indexPath,
            ) as! BundleReportCell
            let relation = linked.first { $0.id == id }?.relation ?? .manual
            if let summary = summary(for: id) {
                cell.configure(with: summary, detail: RelationText.label(for: relation))
            }
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell

        case let .suggestion(id):
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier,
                for: indexPath,
            ) as! BundleReportCell
            let suggestion = suggestions.first { $0.id == id }
            if let suggestion {
                cell.configure(
                    with: suggestion.summary,
                    detail: RelationText.label(for: suggestion.relation),
                )
                // The plus is the whole of what the row offers and an image
                // view says nothing: the cell's own line has to carry it.
                // `configure` has just written that line, so this reads it
                // once rather than piling onto a recycled row's.
                cell.accessibilityLabel = [cell.accessibilityLabel, String(localized: "Add")]
                    .compactMap(\.self).joined(separator: ", ")
            }
            cell.accessoryView = UIImageView(image: UIImage(systemName: "plus.circle.fill")).then {
                $0.tintColor = view.tintColor
                $0.sizeToFit()
                $0.isAccessibilityElement = false
            }
            return cell

        case .addOther:
            let cell = table.dequeueReusableCell(withIdentifier: Self.actionCellIdentifier, for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Add Other Report…")
            content.textProperties.color = view.tintColor
            content.image = UIImage(systemName: "plus")
            content.imageProperties.tintColor = view.tintColor
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell

        case .title:
            let cell = table.dequeueReusableCell(
                withIdentifier: FormTextFieldCell.reuseIdentifier,
                for: indexPath,
            ) as! FormTextFieldCell
            cell.textField.text = bundleTitle
            cell.textField.placeholder = String(localized: "Title")
            // A placeholder names the field only while it is empty, and a text
            // field in a row takes no name from the row.
            cell.textField.accessibilityLabel = String(localized: "Title")
            cell.textField.removeTarget(self, action: nil, for: .editingChanged)
            cell.textField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
            return cell

        case .notes:
            let cell = table.dequeueReusableCell(
                withIdentifier: FormTextViewCell.reuseIdentifier,
                for: indexPath,
            ) as! FormTextViewCell
            cell.configure(
                text: notes,
                placeholder: String(localized: "What were you doing when it happened?"),
            )
            cell.onChange = { [weak self] text in
                guard let self else { return }
                notes = text
                // Grow the row without rebuilding the snapshot, which would
                // take the keyboard's first responder away mid-sentence.
                tableView.performBatchUpdates(nil)
            }
            return cell

        case let .include(include):
            let cell = table.dequeueReusableCell(
                withIdentifier: FormSwitchCell.reuseIdentifier,
                for: indexPath,
            ) as! FormSwitchCell
            cell.configure(
                title: title(for: include),
                detail: detail(for: include),
                isOn: isOn(include),
            )
            cell.onChange = { [weak self] isOn in self?.set(include, to: isOn) }
            return cell

        case .reviewSystemState:
            let cell = table.dequeueReusableCell(withIdentifier: Self.actionCellIdentifier, for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Review Collected Files")
            content.textProperties.color = view.tintColor
            content.image = UIImage(systemName: "list.bullet.rectangle")
            content.imageProperties.tintColor = view.tintColor
            content.secondaryText = systemFiles.map { ReportFormat.byteCount(collectedByteCount($0)) }
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    private func header(for section: Section) -> String? {
        switch section {
        case .primary: String(localized: "Primary Crash")
        case .linked: String(localized: "Linked Crashes")
        case .suggestions: String(localized: "Suggestions")
        case .details: String(localized: "Details")
        case .include: String(localized: "Include")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .suggestions:
            String(localized: "Crashes that look like part of the same incident.")
        case .include:
            includeFooter
        default:
            nil
        }
    }

    /// Two warnings and a running total. System State is the one switch whose
    /// contents are about the machine rather than the crash, so the footer says
    /// what it names and leaves the decision where it belongs.
    private var includeFooter: String {
        var paragraphs = [String(localized: """
        Binaries add the crashed executable and the third-party libraries on the crashing stack. \
        They can be large and may not be yours to share.
        """)]
        if SystemState.isAvailable {
            paragraphs.append(String(localized: """
            System State lists every app, package, tweak, process and service installed and running. \
            Review the files before you share them.
            """))
        }
        paragraphs.append(String(localized: "Estimated size: \(estimatedSizeText)"))
        return paragraphs.joined(separator: "\n\n")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .suggestion(id):
            guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
            linked.append(.init(id: id, relation: suggestion.relation))
            render()
        case .addOther:
            presentPicker()
        case .reviewSystemState:
            Task { await reviewSystemState() }
        default:
            break
        }
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .linked(id) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) {
            [weak self] _, _, done in
            self?.linked.removeAll { $0.id == id }
            self?.render()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    // MARK: Actions

    @objc private func titleChanged(_ field: UITextField) {
        bundleTitle = field.text ?? ""
    }

    private func presentPicker() {
        var excluded = Set(linked.map(\.id))
        excluded.insert(primaryID)
        let picker = ReportPickerViewController(
            candidates: environment.library.summaries.value,
            excluding: excluded,
        ) { [weak self] ids in
            guard let self else { return }
            linked.append(contentsOf: ids.map { .init(id: $0, relation: .manual) })
            render()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    /// Pushes the list of what was collected, collecting first if the switch
    /// was turned on and nothing has needed the files yet.
    private func reviewSystemState() async {
        guard let files = await collectedSystemFiles() else { return }
        navigationController?.pushViewController(
            SystemStateViewController(files: files),
            animated: true,
        )
    }

    /// The one collection, made on the first need and kept. Nil when the person
    /// cancelled it, which turns the switch back off: a switch left on with
    /// nothing behind it would ship a bundle nobody reviewed.
    private func collectedSystemFiles() async -> [SystemStateFile]? {
        // The collection the sheet started on its own may still be running;
        // a second one would write the same files under it.
        if let openingCollection {
            await openingCollection.value
        }
        if let systemFiles {
            return systemFiles
        }
        let directory = systemStateDirectory
        let packages = environment.packages
        do {
            let collected = try await ProgressCard.run(
                from: self,
                title: String(localized: "Collecting System State…"),
            ) { report in
                await Self.collect(into: directory, packages: packages) { name in
                    Task { @MainActor in report(nil, name) }
                }
            }
            systemFiles = collected
            render()
            reconfigure([.include(.systemState), .reviewSystemState])
            refreshIncludeFooter()
            return collected
        } catch {
            options.includesSystemState = false
            render()
            refreshIncludeFooter()
            return nil
        }
    }

    /// The switch is on when the sheet opens, and a switch that is on has
    /// files behind it: the size beside Review and the estimate under the
    /// section are wrong until they exist. Collected once, without the card —
    /// nobody asked for anything yet, so nothing is put in front of them.
    private func collectSystemStateOnOpening() {
        guard openingCollection == nil, systemFiles == nil,
              options.includesSystemState, SystemState.isAvailable else { return }
        let directory = systemStateDirectory
        let packages = environment.packages
        openingCollection = Task { [weak self] in
            let collected = await Self.collect(into: directory, packages: packages) { _ in }
            guard let self else { return }
            systemFiles = collected
            reconfigure([.include(.systemState), .reviewSystemState])
            refreshIncludeFooter()
        }
    }

    /// `SystemState.collect` is synchronous and reads files, so it runs off the
    /// main actor; the line naming the file it is on comes back to it.
    @concurrent private nonisolated static func collect(
        into directory: URL,
        packages: DpkgDatabase?,
        progress: @escaping @Sendable (String) -> Void,
    ) async -> [SystemStateFile] {
        SystemState.collect(into: directory, packages: packages, progress: progress)
    }

    private func collectedByteCount(_ files: [SystemStateFile]) -> UInt64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    /// The disabled Create button is what says a build is in flight; nothing
    /// else reaches this.
    private func create() {
        view.endEditing(true)
        isModalInPresentation = true
        navigationItem.rightBarButtonItem?.isEnabled = false

        Task { [weak self] in
            guard let self else { return }
            defer {
                isModalInPresentation = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            // The same collection the Review screen showed, collected now if
            // nothing has asked for it yet. A cancelled collection turns the
            // switch off, and the bundle is built without it.
            let collected = options.includesSystemState ? await collectedSystemFiles() ?? [] : []
            let request = ReportBundleBuilder.Request(
                primaryID: primaryID,
                linked: linked,
                title: bundleTitle,
                notes: notes,
                options: options,
                includesDSYMs: includesDSYMs,
                systemFiles: collected,
            )
            do {
                let bundle = try await ProgressCard.run(
                    from: self,
                    title: String(localized: "Creating Report…"),
                ) { report in
                    try await ReportBundleBuilder.build(request, environment: self.environment) { fraction, stage in
                        report(fraction, stage)
                    }
                }
                finish(with: bundle)
            } catch is CancellationError {
                return
            } catch {
                presentFailure("Unable to Create Report", error)
            }
        }
    }

    private func finish(with bundle: SavedBundleStore.SavedBundle) {
        let presenter = presentingViewController
        dismiss(animated: true) {
            Toast.show(String(localized: "Report Created"))
            guard let presenter else { return }
            ReportShare.present(bundle, from: presenter, source: nil)
        }
    }

    // MARK: Include switches

    private func title(for include: Include) -> String {
        switch include {
        case .reports: String(localized: "Original Reports")
        case .pdf: String(localized: "PDF Summary")
        case .binaries: String(localized: "Binaries")
        case .dsyms: String(localized: "Matching dSYMs")
        case .systemState: String(localized: "System State")
        }
    }

    private func detail(for include: Include) -> String? {
        switch include {
        case .binaries:
            guard options.includesBinaries, binaryByteCount > 0 else { return nil }
            return ReportFormat.byteCount(binaryByteCount)
        case .systemState:
            return String(localized: "Services, apps, packages, tweaks and processes")
        default:
            return nil
        }
    }

    private func isOn(_ include: Include) -> Bool {
        switch include {
        case .reports: options.includesReports
        case .pdf: options.includesPDF
        case .binaries: options.includesBinaries
        case .dsyms: includesDSYMs
        case .systemState: options.includesSystemState
        }
    }

    private func set(_ include: Include, to isOn: Bool) {
        switch include {
        case .reports: options.includesReports = isOn
        case .pdf: options.includesPDF = isOn
        case .binaries: options.includesBinaries = isOn
        case .dsyms: includesDSYMs = isOn
        case .systemState: options.includesSystemState = isOn
        }
        if include == .systemState {
            // The Review row comes and goes with the switch, and turning it on
            // is the first need: collect now rather than at the Create button,
            // so the files can be read before the bundle exists.
            render()
            if isOn {
                Task { _ = await collectedSystemFiles() }
            }
        } else {
            reconfigure([.include(include)])
        }
        refreshIncludeFooter()
    }

    /// The footer carries the running estimate, and nothing redraws a section's
    /// footer on its own.
    private func refreshIncludeFooter() {
        guard let section = dataSource.snapshot().indexOfSection(.include) else { return }
        let view = tableView.footerView(forSection: section)
        view?.textLabel?.text = footer(for: .include)
        view?.sizeToFit()
    }

    // MARK: Text

    private var estimatedSizeText: String {
        var bytes = UInt64(0)
        if options.includesReports {
            let members = [primarySummary].compactMap(\.self) + linked.compactMap { summary(for: $0.id) }
            for member in members {
                // The original file and the JSON each come out about the size
                // of the report; the rendered crash text about half of it.
                bytes += member.byteCount * 2 + member.byteCount / 2
            }
        }
        if options.includesPDF {
            bytes += 60 * 1024
        }
        if options.includesBinaries {
            bytes += binaryByteCount
        }
        if options.includesSystemState, let systemFiles {
            bytes += collectedByteCount(systemFiles)
        }
        return ReportFormat.byteCount(bytes)
    }

    private func summary(for id: String) -> ReportSummary? {
        environment.library.summaries.value.first { $0.id == id }
    }
}

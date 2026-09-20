import Combine
import Then
import UIKit
import XrashBundle
import XrashReport
import XrashSymbols

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
    }

    private enum Include: Hashable, CaseIterable {
        case rawReports, crashText, json, pdf, binaries, dsyms
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

    private var isBuilding = false

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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Report Crash")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Cancel"),
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        let create = UIBarButtonItem(
            title: String(localized: "Create"),
            primaryAction: UIAction { [weak self] _ in self?.create() }
        )
        create.style = .done
        create.isEnabled = false
        navigationItem.rightBarButtonItem = create

        tableView.register(BundleReportCell.self, forCellReuseIdentifier: BundleReportCell.reuseIdentifier)
        tableView.register(FormTextFieldCell.self, forCellReuseIdentifier: FormTextFieldCell.reuseIdentifier)
        tableView.register(FormTextViewCell.self, forCellReuseIdentifier: FormTextViewCell.reuseIdentifier)
        tableView.register(FormSwitchCell.self, forCellReuseIdentifier: FormSwitchCell.reuseIdentifier)
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
            among: library.summaries.value
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
        snapshot.appendItems(
            Include.allCases.filter { $0 != .dsyms || hasMatchingDSYM }.map { Row.include($0) },
            toSection: .include
        )
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func cell(for row: Row, at indexPath: IndexPath, in table: UITableView) -> UITableViewCell {
        switch row {
        case .primary:
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier, for: indexPath
            ) as! BundleReportCell
            if let primarySummary {
                let reason = primaryReport.flatMap(ReportFormat.reason)
                cell.configure(
                    with: primarySummary,
                    detail: ReportFormat.subtitle(for: primarySummary, reason: reason)
                )
            }
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell

        case let .linked(id):
            let cell = table.dequeueReusableCell(
                withIdentifier: BundleReportCell.reuseIdentifier, for: indexPath
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
                withIdentifier: BundleReportCell.reuseIdentifier, for: indexPath
            ) as! BundleReportCell
            let suggestion = suggestions.first { $0.id == id }
            if let suggestion {
                cell.configure(
                    with: suggestion.summary,
                    detail: RelationText.label(for: suggestion.relation)
                )
            }
            cell.accessoryView = UIImageView(image: UIImage(systemName: "plus.circle.fill")).then {
                $0.tintColor = view.tintColor
                $0.sizeToFit()
            }
            return cell

        case .addOther:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
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
                withIdentifier: FormTextFieldCell.reuseIdentifier, for: indexPath
            ) as! FormTextFieldCell
            cell.textField.text = bundleTitle
            cell.textField.placeholder = String(localized: "Title")
            cell.textField.removeTarget(self, action: nil, for: .editingChanged)
            cell.textField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
            return cell

        case .notes:
            let cell = table.dequeueReusableCell(
                withIdentifier: FormTextViewCell.reuseIdentifier, for: indexPath
            ) as! FormTextViewCell
            cell.configure(
                text: notes,
                placeholder: String(localized: "What were you doing when it happened?")
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
                withIdentifier: FormSwitchCell.reuseIdentifier, for: indexPath
            ) as! FormSwitchCell
            cell.configure(
                title: title(for: include),
                detail: detail(for: include),
                isOn: isOn(include)
            )
            cell.onChange = { [weak self] isOn in self?.set(include, to: isOn) }
            return cell
        }
    }

    private func header(for section: Section) -> String? {
        switch section {
        case .primary: String(localized: "Primary")
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
            String(localized: """
            Binaries add the crashed executable and the third-party libraries on the crashing stack. \
            They can be large and may not be yours to share.
            """) + "\n\n" + String(localized: "Estimated size: \(estimatedSizeText)")
        default:
            nil
        }
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
        default:
            break
        }
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
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
            excluding: excluded
        ) { [weak self] ids in
            guard let self else { return }
            linked.append(contentsOf: ids.map { .init(id: $0, relation: .manual) })
            render()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func create() {
        guard !isBuilding else { return }
        isBuilding = true
        view.endEditing(true)
        isModalInPresentation = true
        navigationItem.rightBarButtonItem?.isEnabled = false

        let request = ReportBundleBuilder.Request(
            primaryID: primaryID,
            linked: linked,
            title: bundleTitle,
            notes: notes,
            options: options,
            includesDSYMs: includesDSYMs && hasMatchingDSYM
        )
        Task { [weak self] in
            guard let self else { return }
            defer {
                isBuilding = false
                isModalInPresentation = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                let bundle = try await ProgressCard.run(
                    from: self,
                    title: String(localized: "Creating the Report")
                ) { report in
                    try await ReportBundleBuilder.build(request, environment: self.environment) { fraction, stage in
                        report(fraction, stage)
                    }
                }
                finish(with: bundle)
            } catch is CancellationError {
                return
            } catch {
                presentFailure("Could Not Create the Report", error)
            }
        }
    }

    private func finish(with bundle: SavedBundleStore.SavedBundle) {
        let presenter = presentingViewController
        dismiss(animated: true) {
            Toast.show(String(localized: "Report Created"))
            guard let presenter else { return }
            ReportShare.present([bundle.url], from: presenter, source: nil)
        }
    }

    // MARK: Include switches

    private func title(for include: Include) -> String {
        switch include {
        case .rawReports: String(localized: "Original Reports")
        case .crashText: String(localized: "Crash Text")
        case .json: String(localized: "JSON")
        case .pdf: String(localized: "PDF Summary")
        case .binaries: String(localized: "Binaries")
        case .dsyms: String(localized: "Matching dSYMs")
        }
    }

    private func detail(for include: Include) -> String? {
        guard include == .binaries, options.includesBinaries, binaryByteCount > 0 else { return nil }
        return ReportFormat.byteCount(binaryByteCount)
    }

    private func isOn(_ include: Include) -> Bool {
        switch include {
        case .rawReports: options.includesRawReports
        case .crashText: options.includesCrashText
        case .json: options.includesJSON
        case .pdf: options.includesPDF
        case .binaries: options.includesBinaries
        case .dsyms: includesDSYMs
        }
    }

    private func set(_ include: Include, to isOn: Bool) {
        switch include {
        case .rawReports: options.includesRawReports = isOn
        case .crashText: options.includesCrashText = isOn
        case .json: options.includesJSON = isOn
        case .pdf: options.includesPDF = isOn
        case .binaries: options.includesBinaries = isOn
        case .dsyms: includesDSYMs = isOn
        }
        reconfigure([.include(include)])
        // The footer carries the running estimate, and nothing redraws a
        // section's footer on its own.
        if let section = dataSource.snapshot().indexOfSection(.include) {
            let view = tableView.footerView(forSection: section)
            view?.textLabel?.text = footer(for: .include)
            view?.sizeToFit()
        }
    }

    // MARK: Text

    private var estimatedSizeText: String {
        var bytes = UInt64(0)
        let members = [primarySummary].compactMap(\.self) + linked.compactMap { summary(for: $0.id) }
        for member in members {
            if options.includesRawReports {
                bytes += member.byteCount
            }
            if options.includesCrashText {
                bytes += member.byteCount / 2
            }
            if options.includesJSON {
                bytes += member.byteCount
            }
        }
        if options.includesPDF {
            bytes += 60 * 1024
        }
        if options.includesBinaries {
            bytes += binaryByteCount
        }
        return ReportFormat.byteCount(bytes)
    }

    private func summary(for id: String) -> ReportSummary? {
        environment.library.summaries.value.first { $0.id == id }
    }
}

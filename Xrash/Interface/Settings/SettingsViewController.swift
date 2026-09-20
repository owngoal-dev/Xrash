import AlertController
import Combine
import UIKit
import XrashClient
import XrashReport

/// The Settings page. A plain grouped table: the rows are fixed, so a snapshot
/// would only be a second place to keep the same list.
final class SettingsViewController: UITableViewController {
    private enum Row {
        case status
        case symbolicateOnOpen
        case defaultView
        case formatJSON
        case showAnalytics
        case retention
        case deleteAll
        case storage
        case version
        case source
        case licenses
    }

    private struct Section {
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    private let library: ReportLibrary
    private let settings: AppSettings
    private let backend: ReportBackend
    private var status = BackendStatus.connecting
    /// What the Mac's bundled LaunchAgent is waiting for, if anything. Off a
    /// Mac this stays `.notApplicable` and nothing below reads differently —
    /// the row is told by data, not by a compilation condition.
    private var agentStatus = MacLaunchAgent.Status.notApplicable
    private var observers = Set<AnyCancellable>()

    private var sections: [Section] {
        [
            Section(
                title: String(localized: "Service"),
                footer: String(
                    localized: "The helper runs only while the app asks it something, and exits when idle."
                ),
                rows: [.status]
            ),
            Section(
                title: String(localized: "Reports"),
                footer: String(
                    localized: "Most of what the system writes is analytics and logs, not crashes."
                ),
                rows: [.symbolicateOnOpen, .defaultView, .formatJSON, .showAnalytics]
            ),
            Section(
                title: String(localized: "Cleanup"),
                footer: String(
                    localized: "Auto-delete removes every report older than the age you pick, read or not."
                ),
                rows: [.retention, .deleteAll, .storage]
            ),
            Section(title: String(localized: "About"), footer: nil, rows: [.version, .source, .licenses]),
        ]
    }

    init(
        library: ReportLibrary = AppEnvironment.shared.library,
        backend: ReportBackend = AppEnvironment.shared.backend
    ) {
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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")

        backend.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.status = $0
                self?.tableView.reloadData()
            }
            .store(in: &observers)
        MacLaunchAgent.shared.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.agentStatus = $0
                self?.tableView.reloadData()
            }
            .store(in: &observers)
        settings.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &observers)
        settings.filter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &observers)
        library.summaries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &observers)
    }

    // MARK: Table

    override func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none
        var configuration = UIListContentConfiguration.valueCell()
        configuration.secondaryTextProperties.color = .secondaryLabel

        switch row {
        case .status:
            configuration = UIListContentConfiguration.subtitleCell()
            configuration.text = statusTitle
            // What the helper is waiting for beats what the connection is
            // doing: "Connecting…" forever is what an unapproved Login Item
            // looks like from here.
            configuration.secondaryText = agentDetail ?? statusDetail
            configuration.secondaryTextProperties.color = .secondaryLabel
            configuration.image = UIImage(systemName: statusSymbol)
            configuration.imageProperties.tintColor = statusTint
            if agentOpensLoginItems {
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }
        case .symbolicateOnOpen:
            configuration.text = String(localized: "Symbolicate on Open")
            cell.accessoryView = toggle(
                isOn: settings.preferences.value.symbolicatesOnOpen,
                action: #selector(toggleSymbolicate)
            )
        case .formatJSON:
            configuration.text = String(localized: "Format JSON Automatically")
            cell.accessoryView = toggle(
                isOn: settings.preferences.value.formatsJSON,
                action: #selector(toggleFormatJSON)
            )
        case .defaultView:
            configuration.text = String(localized: "Default View")
            configuration.secondaryText = label(for: settings.preferences.value.defaultView)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .showAnalytics:
            configuration.text = String(localized: "Show Analytics & Logs")
            cell.accessoryView = toggle(
                isOn: settings.filter.value.showsAnalytics,
                action: #selector(toggleAnalytics)
            )
        case .retention:
            configuration.text = String(localized: "Auto-Delete Reports")
            configuration.secondaryText = retentionLabel(settings.preferences.value.retentionDays)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .deleteAll:
            configuration.text = String(localized: "Delete All Reports…")
            configuration.textProperties.color = .systemRed
            cell.selectionStyle = .default
        case .storage:
            configuration.text = String(localized: "Storage Used")
            configuration.secondaryText = ReportFormat.byteCount(
                library.summaries.value.reduce(0) { $0 + $1.byteCount }
            )
        case .version:
            configuration.text = String(localized: "Version")
            configuration.secondaryText = Self.versionText
        case .source:
            configuration.text = String(localized: "Source Code")
            configuration.secondaryText = "github.com/owngoal-dev/Xrash"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .licenses:
            configuration.text = String(localized: "Licenses")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .status:
            if agentOpensLoginItems {
                MacLaunchAgent.shared.openLoginItemsSettings()
            }
        case .defaultView:
            navigationController?.pushViewController(defaultViewChooser(), animated: true)
        case .retention:
            navigationController?.pushViewController(retentionChooser(), animated: true)
        case .deleteAll:
            confirmDeleteAll()
        case .source:
            URL(string: "https://github.com/owngoal-dev/Xrash").map { UIApplication.shared.open($0) }
        case .licenses:
            navigationController?.pushViewController(LicensesViewController(), animated: true)
        default:
            break
        }
    }

    // MARK: Rows

    private func toggle(isOn: Bool, action: Selector) -> UISwitch {
        let control = UISwitch()
        control.isOn = isOn
        control.addTarget(self, action: action, for: .valueChanged)
        return control
    }

    @objc private func toggleSymbolicate(_ control: UISwitch) {
        settings.changePreferences { $0.symbolicatesOnOpen = control.isOn }
    }

    @objc private func toggleFormatJSON(_ control: UISwitch) {
        settings.changePreferences { $0.formatsJSON = control.isOn }
    }

    @objc private func toggleAnalytics(_ control: UISwitch) {
        settings.changeFilter { $0.showsAnalytics = control.isOn }
    }

    private var statusTitle: String {
        switch status {
        case .connecting: String(localized: "Connecting…")
        // Not "Connected as root": on a Mac the helper is a per-user
        // LaunchAgent, and root is exactly what it is not there. What both
        // platforms share is how much of the directory it opens.
        case .privileged: String(localized: "Full access")
        case .sandboxed: String(localized: "Limited access")
        }
    }

    private var statusDetail: String? {
        switch status {
        case .connecting: String(localized: "Waiting for the helper to start.")
        case .privileged: String(localized: "Every report can be opened.")
        case .sandboxed: String(localized: "Reading only the reports the app can open without the helper.")
        }
    }

    /// What the Mac's helper is waiting for, when it is waiting for a person.
    /// Nil on every other platform and in every settled state.
    private var agentDetail: String? {
        switch agentStatus {
        case .needsApproval:
            String(localized: "Allow Xrash in Login Items to let the helper start.")
        case .needsRelocation:
            String(localized: "Move Xrash to the Applications folder to let the helper start.")
        case .failed:
            // Spelled here as well as in `MacLaunchAgent`: that one compiles
            // on Catalyst only, and the catalogue is checked against the keys
            // the iOS build extracts.
            String(
                localized: "Unable to turn on the Xrash helper. Open Login Items in System Settings to allow it."
            )
        default:
            nil
        }
    }

    /// Whether tapping the row has somewhere to go. Relocation does not: that
    /// is a move in Finder, not a switch in System Settings.
    private var agentOpensLoginItems: Bool {
        switch agentStatus {
        case .needsApproval, .failed: true
        default: false
        }
    }

    private var statusSymbol: String {
        switch status {
        case .connecting: "ellipsis.circle"
        case .privileged: "checkmark.seal"
        case .sandboxed: "lock"
        }
    }

    private var statusTint: UIColor {
        switch status {
        case .connecting: .secondaryLabel
        case .privileged: .systemGreen
        case .sandboxed: .systemOrange
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info[kCFBundleVersionKey as String] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func label(for view: ReportPreferences.DefaultView) -> String {
        switch view {
        case .summary: String(localized: "Summary")
        case .details: String(localized: "Details")
        case .raw: String(localized: "Raw")
        }
    }

    private func retentionLabel(_ days: Int) -> String {
        days == 0 ? String(localized: "Never") : String(localized: "After \(days) days")
    }

    // MARK: Choosers

    private func defaultViewChooser() -> UIViewController {
        ChoiceViewController(
            title: String(localized: "Default View"),
            choices: ReportPreferences.DefaultView.allCases.map { (label(for: $0), $0) },
            selected: settings.preferences.value.defaultView
        ) { [weak self] choice in
            self?.settings.changePreferences { $0.defaultView = choice }
        }
    }

    private func retentionChooser() -> UIViewController {
        ChoiceViewController(
            title: String(localized: "Auto-Delete Reports"),
            choices: [0, 7, 30, 90].map { (retentionLabel($0), $0) },
            selected: settings.preferences.value.retentionDays,
            footer: String(localized: "Older reports are deleted after the list refreshes.")
        ) { [weak self] days in
            self?.settings.changePreferences { $0.retentionDays = days }
        }
    }

    private func confirmDeleteAll() {
        let ids = library.summaries.value.map(\.id)
        guard !ids.isEmpty else {
            return presentMessage(
                String.LocalizationValue("Nothing to Delete"),
                message: String.LocalizationValue("There are no reports to delete.")
            )
        }
        let alert = AlertViewController(
            title: String.LocalizationValue("Delete All Reports?"),
            message: String.LocalizationValue(
                "Every report file is removed. This cannot be undone."
            )
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Delete All"), attribute: .accent) {
                context.dispose { [weak self] in
                    guard let self else { return }
                    guard let failed = await ReportDeletion.delete(ids, from: self, library: library) else {
                        return
                    }
                    if failed.isEmpty {
                        Toast.show(String(localized: "Reports Deleted"))
                    } else {
                        presentMessage(
                            String.LocalizationValue("Some Reports Remain"),
                            message: String.LocalizationValue("\(failed.count) of them could not be deleted.")
                        )
                    }
                }
            }
        }
        present(alert, animated: true)
    }
}

/// A pushed list of choices with a checkmark on the current one — the shape
/// every Settings row of this kind has on iOS.
private final class ChoiceViewController<Choice: Equatable>: UITableViewController {
    private let choices: [(title: String, value: Choice)]
    private var selected: Choice
    private let footer: String?
    private let onChoose: (Choice) -> Void

    init(
        title: String,
        choices: [(String, Choice)],
        selected: Choice,
        footer: String? = nil,
        onChoose: @escaping (Choice) -> Void
    ) {
        self.choices = choices.map { (title: $0.0, value: $0.1) }
        self.selected = selected
        self.footer = footer
        self.onChoose = onChoose
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "choice")
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        choices.count
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "choice", for: indexPath)
        var configuration = UIListContentConfiguration.cell()
        configuration.text = choices[indexPath.row].title
        cell.contentConfiguration = configuration
        cell.accessoryType = choices[indexPath.row].value == selected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selected = choices[indexPath.row].value
        onChoose(selected)
        tableView.reloadData()
    }
}

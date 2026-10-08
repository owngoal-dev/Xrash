import AlertController
import Combine
import SafariServices
import UIKit
import XrashReport

/// The Settings page. A plain grouped table: the rows are fixed, so a snapshot
/// would only be a second place to keep the same list.
final class SettingsViewController: SelectionTableViewController {
    private enum Row {
        case defaultView
        case hiddenProcesses
        case reportNotifications
        case notificationCategories
        case deleteAll
        case storage
        case version
        case source
        case licenses
        case welcome
    }

    private struct Section {
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    private let library: ReportLibrary
    private let settings: AppSettings
    private var observers = Set<AnyCancellable>()

    /// No row for the helper, whatever state it is in: how reports get opened
    /// is not a setting, and the welcome's Helper stage is where it is told.
    private var sections: [Section] {
        [
            Section(
                title: String(localized: "Reports"),
                footer: nil,
                rows: [.defaultView, .hiddenProcesses],
            ),
            Section(
                title: String(localized: "Notifications"),
                footer: ReportFormat.announcementSummary,
                rows: [.reportNotifications, .notificationCategories],
            ),
            Section(
                title: String(localized: "Cleanup"),
                footer: nil,
                rows: [.storage, .deleteAll],
            ),
            Section(
                title: String(localized: "About"),
                footer: nil,
                rows: [.version, .source, .licenses, .welcome],
            ),
        ]
    }

    init(library: ReportLibrary = AppEnvironment.shared.library) {
        self.library = library
        // Not a default argument: those are evaluated off the main actor.
        settings = .shared
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

        settings.preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reconfigureRows(at: self?.tableView.indexPathsForVisibleRows ?? []) }
            .store(in: &observers)
        CrashNotice.shared.daemonAnnounces
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reconfigureRows(at: self?.tableView.indexPathsForVisibleRows ?? []) }
            .store(in: &observers)
        settings.filter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reconfigureRows(at: self?.tableView.indexPathsForVisibleRows ?? []) }
            .store(in: &observers)
        library.summaries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reconfigureRows(at: self?.tableView.indexPathsForVisibleRows ?? []) }
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
        case .defaultView:
            configuration.text = String(localized: "Default View")
            configuration.secondaryText = label(for: settings.preferences.value.defaultView)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .hiddenProcesses:
            configuration.text = String(localized: "Hidden Processes")
            let hidden = settings.filter.value.hiddenProcessNames.count
            configuration.secondaryText = hidden == 0 ? String(localized: "None") : hidden.formatted()
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .reportNotifications:
            configuration.text = String(localized: "Allow Notifications")
            cell.accessoryView = toggle(
                isOn: settings.preferences.value.notifiesOnNewReports,
                action: #selector(toggleNotifications),
            )
        case .notificationCategories:
            configuration.text = String(localized: "Notification Categories")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .deleteAll:
            configuration.text = String(localized: "Delete All Reports…")
            configuration.textProperties.color = .systemRed
            cell.selectionStyle = .default
        case .storage:
            configuration.text = String(localized: "Storage Used")
            configuration.secondaryText = ReportFormat.byteCount(
                library.summaries.value.reduce(0) { $0 + $1.byteCount },
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
        case .welcome:
            configuration.text = String(localized: "Show Welcome Screen")
            configuration.textProperties.color = view.tintColor ?? .tintColor
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .defaultView:
            navigationController?.pushViewController(defaultViewChooser(), animated: true)
        case .hiddenProcesses:
            navigationController?.pushViewController(HiddenProcessesViewController(), animated: true)
        case .notificationCategories:
            navigationController?.pushViewController(NotificationCategoriesViewController(), animated: true)
        case .deleteAll:
            confirmDeleteAll()
        case .source:
            if let url = URL(string: "https://github.com/owngoal-dev/Xrash") {
                present(SFSafariViewController(url: url), animated: true)
            }
        case .licenses:
            navigationController?.pushViewController(LicensesViewController(), animated: true)
        case .welcome:
            WelcomeController.present(from: self)
        default:
            deselectFinishedAction()
        }
    }

    // MARK: Rows

    private func toggle(isOn: Bool, action: Selector) -> UISwitch {
        let control = UISwitch()
        control.isOn = isOn
        control.addTarget(self, action: action, for: .valueChanged)
        return control
    }

    /// Turning it on is where the OS is asked. A refusal is not a state the
    /// app can hold: the switch goes back and says where to change it.
    @objc private func toggleNotifications(_ control: UISwitch) {
        guard control.isOn else {
            return settings.changePreferences { $0.notifiesOnNewReports = false }
        }
        Task { [weak self] in
            guard let self else { return }
            guard await CrashNotice.shared.requestAuthorization() else {
                control.setOn(false, animated: true)
                return presentNotificationsRefused()
            }
            settings.changePreferences { $0.notifiesOnNewReports = true }
        }
    }

    private func presentNotificationsRefused() {
        let alert = AlertViewController(
            title: String.LocalizationValue("Notifications Are Turned Off"),
            message: String.LocalizationValue(
                "Allow notifications for Xrash in Settings to know when a new report arrives.",
            ),
        ) { context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Open Settings"), attribute: .accent) {
                context.dispose {
                    URL(string: UIApplication.openSettingsURLString).map { UIApplication.shared.open($0) }
                }
            }
        }
        present(alert, animated: true)
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

    // MARK: Choosers

    private func defaultViewChooser() -> UIViewController {
        ChoiceViewController(
            title: String(localized: "Default View"),
            choices: ReportPreferences.DefaultView.allCases.map { (label(for: $0), $0) },
            selected: settings.preferences.value.defaultView,
        ) { [weak self] choice in
            self?.settings.changePreferences { $0.defaultView = choice }
        }
    }

    private func confirmDeleteAll() {
        let ids = library.summaries.value.map(\.id)
        guard !ids.isEmpty else {
            return presentMessage(
                String.LocalizationValue("Nothing to Delete"),
                message: String.LocalizationValue("There are no reports to delete."),
            )
        }
        let alert = AlertViewController(
            title: String.LocalizationValue("Delete All Reports?"),
            message: String.LocalizationValue(
                "All reports are deleted. This cannot be undone.",
            ),
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Delete All"), attribute: .accent) {
                context.dispose {
                    guard let self else { return }
                    guard let failed = await ReportDeletion.delete(ids, from: self, library: self.library) else {
                        return
                    }
                    if failed.isEmpty {
                        Toast.show(String(localized: "Reports Deleted"))
                    } else {
                        self.presentMessage(
                            String.LocalizationValue("Unable to Delete Some Reports"),
                            message: String.LocalizationValue("\(failed.count) of the reports could not be deleted."),
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
    private let onChoose: (Choice) -> Void

    init(
        title: String,
        choices: [(String, Choice)],
        selected: Choice,
        onChoose: @escaping (Choice) -> Void,
    ) {
        self.choices = choices.map { (title: $0.0, value: $0.1) }
        self.selected = selected
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

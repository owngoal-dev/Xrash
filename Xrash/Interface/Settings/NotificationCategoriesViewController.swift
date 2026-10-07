import Combine
import UIKit
import XrashNotice
import XrashReport

/// Category choices stay editable with the master switch off and are kept
/// when it is turned back on. They never change which reports the list shows.
final class NotificationCategoriesViewController: UITableViewController {
    private let settings = AppSettings.shared
    private var observer: AnyCancellable?
    private let sections: [(title: String, categories: [NoticeCategory])] = [
        (String(localized: "Crash"), [.crash, .jetsam, .panic]),
        (String(localized: "Hang"), [.hang]),
        (String(localized: "Resource Limit"), [.cpu, .wakeups, .diskWrites, .resource]),
        (String(localized: "Analytics & Logs"), [.analytics, .other]),
    ]

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Notification Categories")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "category")
        observer = settings.preferences.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
    }

    override func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].categories.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == sections.count - 1 else { return nil }
        return String(localized: "Notifications require Allow Notifications to be on. Hidden reports stay silent.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let category = sections[indexPath.section].categories[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "category", for: indexPath)
        let label = label(for: category)
        var content = UIListContentConfiguration.cell()
        content.text = label
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let control = UISwitch()
        control.isOn = settings.preferences.value.notificationCategories.contains(category)
        control.accessibilityLabel = label
        control.addAction(UIAction { [weak self, weak control] _ in
            guard let control else { return }
            self?.settings.changePreferences {
                if control.isOn {
                    $0.notificationCategories.insert(category)
                } else {
                    $0.notificationCategories.remove(category)
                }
            }
        }, for: .valueChanged)
        cell.accessoryView = control
        return cell
    }

    private func label(for category: NoticeCategory) -> String {
        switch category {
        case .crash: ReportFormat.kindLabel(.crash)
        case .jetsam: ReportFormat.kindLabel(.jetsam)
        case .panic: ReportFormat.kindLabel(.panic)
        case .hang: ReportFormat.kindLabel(.hang)
        case .cpu: String(localized: "CPU Usage")
        case .wakeups: String(localized: "Wakeups")
        case .diskWrites: String(localized: "Disk Writes")
        case .resource: String(localized: "Other Resource Limits")
        case .analytics: ReportFormat.kindLabel(.analytics)
        case .other: ReportFormat.kindLabel(.other)
        }
    }
}

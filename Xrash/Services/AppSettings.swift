import Combine
import Foundation
import XrashReport

/// How the list is filtered and arranged. One value, so the list's menu and
/// the Settings page cannot drift apart — "Show Analytics & Logs" there is the
/// same switch as the "Analytics & Logs" kind here.
struct ReportFilter: Codable, Equatable, Sendable {
    enum Grouping: String, Codable, Sendable, CaseIterable {
        case category, process, day
    }

    enum Order: String, Codable, Sendable, CaseIterable {
        case newest, oldest, name
    }

    /// The kinds shown under one menu item, because nobody asks for a `313`.
    static let analyticsKinds: Set<ReportKind> = [.analytics, .other]

    var unreadOnly = false
    /// Analytics is out of the box off: 25 of the 66 files on the test device
    /// were Siri analytics payloads and not one of them was a crash.
    var kinds: Set<ReportKind> = [.crash, .hang, .resource, .jetsam, .panic]
    var grouping = Grouping.category
    var order = Order.newest
    /// Case-sensitive, matched against `ReportSummary.processName`. A view
    /// filter: the reports stay on disk and nothing stops being written.
    var hiddenProcessNames = Set<String>()

    init() {}

    /// Every field is optional on the way in, for the reason
    /// `ReportPreferences` gives: one new field must not reset the others.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        unreadOnly = try values.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? unreadOnly
        kinds = try values.decodeIfPresent(Set<ReportKind>.self, forKey: .kinds) ?? kinds
        grouping = try values.decodeIfPresent(Grouping.self, forKey: .grouping) ?? grouping
        order = try values.decodeIfPresent(Order.self, forKey: .order) ?? order
        hiddenProcessNames = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenProcessNames)
            ?? hiddenProcessNames
    }

    /// Whether a report is shown at all, before unread-only and search. The
    /// list, the icon badge and the crash notification all ask this, so a
    /// hidden process is hidden from every one of them.
    func admits(_ summary: ReportSummary) -> Bool {
        kinds.contains(summary.kind) && !hiddenProcessNames.contains(summary.processName)
    }

    var showsAnalytics: Bool {
        get { !kinds.isDisjoint(with: Self.analyticsKinds) }
        set { newValue ? kinds.formUnion(Self.analyticsKinds) : kinds.subtract(Self.analyticsKinds) }
    }
}

/// The choices that are not about the list.
struct ReportPreferences: Codable, Equatable, Sendable {
    /// Which of the detail screen's three segments a report opens on.
    enum DefaultView: String, Codable, Sendable, CaseIterable {
        case summary, details, raw

        /// The two segments used to be separate pushed screens called
        /// "Crash Text" and "JSON"; a preference written then still decodes.
        init(from decoder: Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "crashText": self = .details
            case "json": self = .raw
            case let stored: self = DefaultView(rawValue: stored) ?? .summary
            }
        }
    }

    var symbolicatesOnOpen = true
    var defaultView = DefaultView.summary
    /// Reports older than this are deleted after a refresh. Zero never prunes.
    var retentionDays = 0
    // The text viewer's two, remembered across reports rather than per file.
    /// Off: a wrapped stack frame reads as two frames.
    var wrapsLines = false
    var textScale = 1.0
    /// The Raw view opens indented rather than as the two long lines on disk.
    var formatsJSON = true
    /// A notification for a report that arrives while the app is running.
    /// Nothing is injected anywhere, so that is the whole of what it can see.
    var notifiesOnNewReports = true

    init() {}

    /// Every field is optional on the way in. The synthesized decoder throws
    /// on a missing key, so adding one choice would otherwise reset all the
    /// others on the first launch after an update.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        symbolicatesOnOpen = try values.decodeIfPresent(Bool.self, forKey: .symbolicatesOnOpen) ?? symbolicatesOnOpen
        defaultView = try values.decodeIfPresent(DefaultView.self, forKey: .defaultView) ?? defaultView
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays
        wrapsLines = try values.decodeIfPresent(Bool.self, forKey: .wrapsLines) ?? wrapsLines
        textScale = try values.decodeIfPresent(Double.self, forKey: .textScale) ?? textScale
        formatsJSON = try values.decodeIfPresent(Bool.self, forKey: .formatsJSON) ?? formatsJSON
        notifiesOnNewReports = try values.decodeIfPresent(Bool.self, forKey: .notifiesOnNewReports)
            ?? notifiesOnNewReports
    }
}

/// Everything the interface remembers between launches, as two Combine
/// subjects the screens observe and write back through. Stored as JSON under
/// two defaults keys rather than a key per field: adding a choice then costs
/// one property and no migration.
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    let filter: CurrentValueSubject<ReportFilter, Never>
    let preferences: CurrentValueSubject<ReportPreferences, Never>

    private static let filterKey = "AppSettings.filter"
    private static let preferencesKey = "AppSettings.preferences"

    private var writes = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        filter = CurrentValueSubject(Self.read(from: defaults, key: Self.filterKey) ?? ReportFilter())
        preferences = CurrentValueSubject(
            Self.read(from: defaults, key: Self.preferencesKey) ?? ReportPreferences()
        )
        filter.dropFirst().sink { Self.write($0, to: defaults, key: Self.filterKey) }.store(in: &writes)
        preferences.dropFirst()
            .sink { Self.write($0, to: defaults, key: Self.preferencesKey) }
            .store(in: &writes)
    }

    /// Reads, changes and publishes in one step, so a caller never has to
    /// remember that `value` is a copy.
    func changeFilter(_ change: (inout ReportFilter) -> Void) {
        var value = filter.value
        change(&value)
        if value != filter.value {
            filter.send(value)
        }
    }

    func changePreferences(_ change: (inout ReportPreferences) -> Void) {
        var value = preferences.value
        change(&value)
        if value != preferences.value {
            preferences.send(value)
        }
    }

    private static func read<Value: Decodable>(from defaults: UserDefaults, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func write(_ value: some Encodable, to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

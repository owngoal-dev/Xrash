import Foundation
import XrashReport

/// Which header a row sits under. The list is sectioned however the user asked
/// for it; the identifier carries enough to sort and title the section.
enum ReportSection: Hashable {
    case group(ReportGroup)
    case process(String)
    case day(Date)
    /// The one section the process inbox has, which wears no header.
    case inbox
}

/// Everything a row draws. Kept as one value so the list can tell which rows
/// actually changed: a refresh republishes every summary as its header is
/// read, and reconfiguring all of them makes the list flicker under a finger.
struct ReportRowState: Hashable {
    var summary: ReportSummary
    var isUnread: Bool
    /// `EXC_CRASH (SIGABRT)`, once this report has been decoded once.
    var reason: String?
}

struct ReportListGroup: Equatable {
    var section: ReportSection
    var rows: [ReportRowState]
}

/// One line of the process inbox: a process, its newest report, and how many
/// reports are filed under that name.
struct ProcessInboxRow: Hashable {
    /// Case-sensitive, as the report says it — `ReportSummary.processName`.
    var name: String
    var latest: ReportSummary
    /// The newest report's `EXC_CRASH (SIGABRT)`, once it has been decoded.
    var latestReason: String?
    var count: Int
    var hasUnread: Bool
}

/// What the list draws: reports under headers, or one row per process. One
/// value, so both arrangements come down the one pipeline.
enum ReportListContent: Equatable {
    case groups([ReportListGroup])
    case processes([ProcessInboxRow])
}

/// What the list is computed from. Equatable so an identical recomputation is
/// dropped before it reaches a background queue.
struct ReportListInput: Equatable {
    var summaries: [ReportSummary]
    var unread: Set<String>
    var reasons: [String: String]
    var filter: ReportFilter
    var searchText: String
    /// Set on a process page: that one process, flat, whatever the menu says.
    var lockedProcessName: String?
}

/// Filtering, sorting and sectioning — a pure function, so it runs off the
/// main thread and can be reasoned about without a table in the way.
enum ReportListArrangement {
    /// The list's whole answer for one input.
    static func content(for input: ReportListInput) -> ReportListContent {
        guard input.lockedProcessName == nil, input.filter.grouping == .process else {
            return .groups(groups(for: input))
        }
        return .processes(inbox(for: input))
    }

    static func groups(for input: ReportListInput) -> [ReportListGroup] {
        let needle = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = admitted(for: input).filter {
            needle.isEmpty || matches($0.summary, reason: $0.reason, needle: needle)
        }

        var bySection = [ReportSection: [ReportRowState]]()
        for row in rows {
            bySection[section(for: row.summary, input: input), default: []].append(row)
        }
        return bySection
            .map { ReportListGroup(section: $0.key, rows: $0.value.sorted { isBefore($0, $1, input.filter.order) }) }
            .sorted { isBefore($0.section, $1.section, input.filter.order) }
    }

    /// One row per process name. A search keeps a process when its name, its
    /// bundle id or any one of its reports' reasons matches — the count stays
    /// the whole process either way, because that is what Delete All removes.
    static func inbox(for input: ReportListInput) -> [ProcessInboxRow] {
        let needle = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var byName = [String: [ReportRowState]]()
        for row in admitted(for: input) {
            byName[row.summary.processName, default: []].append(row)
        }
        return byName.compactMap { name, rows -> ProcessInboxRow? in
            guard let latest = rows.max(by: { $0.summary.date < $1.summary.date }) else { return nil }
            guard needle.isEmpty || rows.contains(where: {
                matches($0.summary, reason: $0.reason, needle: needle)
            }) else { return nil }
            return ProcessInboxRow(
                name: name,
                latest: latest.summary,
                latestReason: latest.reason,
                count: rows.count,
                hasUnread: rows.contains(where: \.isUnread)
            )
        }
        .sorted { isBefore($0, $1, input.filter.order) }
    }

    /// Every report the list would show before the search field: the kinds,
    /// the hidden names, unread-only, and a process page's one name. The
    /// inbox counts these, and deleting a whole process removes them.
    static func admitted(for input: ReportListInput) -> [ReportRowState] {
        input.summaries.compactMap { summary -> ReportRowState? in
            guard input.filter.admits(summary) else { return nil }
            guard input.lockedProcessName == nil || input.lockedProcessName == summary.processName else {
                return nil
            }
            let isUnread = input.unread.contains(summary.id)
            guard !input.filter.unreadOnly || isUnread else { return nil }
            return ReportRowState(summary: summary, isUnread: isUnread, reason: input.reasons[summary.id])
        }
    }

    static func title(for section: ReportSection) -> String {
        switch section {
        case let .group(group): ReportFormat.groupTitle(group)
        case let .process(name): name
        case let .day(day): ReportFormat.date(day)
        // Never asked for: the inbox's one section carries no header.
        case .inbox: ""
        }
    }

    // MARK: Pieces

    private static func matches(_ summary: ReportSummary, reason: String?, needle: String) -> Bool {
        [summary.processName, summary.bundleID, reason]
            .compactMap(\.self)
            .contains { $0.matches(needle) }
    }

    private static func section(for summary: ReportSummary, input: ReportListInput) -> ReportSection {
        if let locked = input.lockedProcessName {
            return .process(locked)
        }
        switch input.filter.grouping {
        case .category: return .group(summary.group)
        case .process: return .process(summary.processName)
        case .day: return .day(Calendar.current.startOfDay(for: summary.date))
        }
    }

    private static func isBefore(_ lhs: ProcessInboxRow, _ rhs: ProcessInboxRow, _ order: ReportFilter.Order) -> Bool {
        switch order {
        case .newest: lhs.latest.date > rhs.latest.date
        case .oldest: lhs.latest.date < rhs.latest.date
        case .name: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func isBefore(_ lhs: ReportRowState, _ rhs: ReportRowState, _ order: ReportFilter.Order) -> Bool {
        switch order {
        case .newest: lhs.summary.date > rhs.summary.date
        case .oldest: lhs.summary.date < rhs.summary.date
        case .name: lhs.summary.processName.localizedStandardCompare(rhs.summary.processName) == .orderedAscending
        }
    }

    /// Categories keep their written order; processes read alphabetically
    /// whatever the row order is, and days follow the rows.
    private static func isBefore(_ lhs: ReportSection, _ rhs: ReportSection, _ order: ReportFilter.Order) -> Bool {
        switch (lhs, rhs) {
        case let (.group(left), .group(right)):
            let all = ReportGroup.allCases
            return (all.firstIndex(of: left) ?? 0) < (all.firstIndex(of: right) ?? 0)
        case let (.process(left), .process(right)):
            return left.localizedStandardCompare(right) == .orderedAscending
        case let (.day(left), .day(right)):
            return order == .oldest ? left < right : left > right
        default:
            return false
        }
    }
}

#if DEBUG
    extension ReportListArrangement {
        /// The inbox's counting, sorting and searching, checked against three
        /// reports the first time a list comes up in a debug build — a table is
        /// a slow way to find out that one of them broke, and the arrangement
        /// lives in the app target, where the package tests cannot reach it.
        /// A `static let` runs its closure exactly once.
        static let inboxSelfCheckPassed: Bool = {
            func report(_ name: String, minutesAgo: Int, bundleID: String? = nil) -> ReportSummary {
                var summary = ReportSummary(
                    id: "/\(name)-\(minutesAgo).ips",
                    fileName: "\(name)-\(minutesAgo).ips",
                    processName: name,
                    kind: .crash,
                    group: .app,
                    date: Date(timeIntervalSinceReferenceDate: Double(-minutesAgo) * 60),
                    byteCount: 1,
                    isSynced: false
                )
                summary.bundleID = bundleID
                return summary
            }
            var input = ReportListInput(
                summaries: [
                    report("Fila", minutesAgo: 1, bundleID: "wiki.qaq.fila"),
                    report("Fila", minutesAgo: 30),
                    report("SpringBoard", minutesAgo: 10),
                ],
                unread: ["/SpringBoard-10.ips"],
                reasons: ["/Fila-30.ips": "EXC_BAD_ACCESS"],
                filter: ReportFilter(),
                searchText: ""
            )
            input.filter.grouping = .process

            let newest = inbox(for: input)
            assert(newest.map(\.name) == ["Fila", "SpringBoard"], "newest sorts on the latest report's date")
            assert(newest.first?.latest.id == "/Fila-1.ips", "the row's report is the newest of its process")
            assert(newest.first?.count == 2, "the count is every report of the process")
            assert(newest.first?.hasUnread == false, "no unread report, no unread row")
            assert(newest.last?.hasUnread == true, "an unread report makes the row unread")

            input.filter.order = .oldest
            assert(inbox(for: input).map(\.name) == ["SpringBoard", "Fila"], "oldest turns the inbox around")
            input.filter.order = .name
            assert(inbox(for: input).map(\.name) == ["Fila", "SpringBoard"], "name sorts on the process name")

            input.searchText = "exc_bad"
            assert(inbox(for: input).map(\.name) == ["Fila"], "a search reads every report's reason")
            input.searchText = "wiki.qaq"
            assert(inbox(for: input).map(\.name) == ["Fila"], "a search reads the bundle id")
            input.searchText = "nothing here"
            assert(inbox(for: input).isEmpty, "a search that matches nothing keeps nothing")

            input.searchText = ""
            input.filter.hiddenProcessNames = ["Fila"]
            assert(inbox(for: input).map(\.name) == ["SpringBoard"], "a hidden process is not in the inbox")
            return true
        }()
    }
#endif

import Foundation
import XrashReport

/// Which header a row sits under. The list is sectioned however the user asked
/// for it; the identifier carries enough to sort and title the section.
enum ReportSection: Hashable {
    case group(ReportGroup)
    case process(String)
    case day(Date)
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

/// What the list is computed from. Equatable so an identical recomputation is
/// dropped before it reaches a background queue.
struct ReportListInput: Equatable {
    var summaries: [ReportSummary]
    var unread: Set<String>
    var reasons: [String: String]
    var filter: ReportFilter
    var searchText: String
}

/// Filtering, sorting and sectioning — a pure function, so it runs off the
/// main thread and can be reasoned about without a table in the way.
enum ReportListArrangement {
    static func groups(for input: ReportListInput) -> [ReportListGroup] {
        let needle = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = input.summaries.compactMap { summary -> ReportRowState? in
            guard input.filter.kinds.contains(summary.kind) else { return nil }
            let isUnread = input.unread.contains(summary.id)
            guard !input.filter.unreadOnly || isUnread else { return nil }
            let reason = input.reasons[summary.id]
            guard needle.isEmpty || matches(summary, reason: reason, needle: needle) else { return nil }
            return ReportRowState(summary: summary, isUnread: isUnread, reason: reason)
        }

        var bySection = [ReportSection: [ReportRowState]]()
        for row in rows {
            bySection[section(for: row.summary, grouping: input.filter.grouping), default: []].append(row)
        }
        return bySection
            .map { ReportListGroup(section: $0.key, rows: $0.value.sorted { isBefore($0, $1, input.filter.order) }) }
            .sorted { isBefore($0.section, $1.section, input.filter.order) }
    }

    static func title(for section: ReportSection) -> String {
        switch section {
        case let .group(group): ReportFormat.groupTitle(group)
        case let .process(name): name
        case let .day(day): ReportFormat.date(day)
        }
    }

    // MARK: Pieces

    private static func matches(_ summary: ReportSummary, reason: String?, needle: String) -> Bool {
        [summary.processName, summary.bundleID, reason]
            .compactMap(\.self)
            .contains { $0.matches(needle) }
    }

    private static func section(for summary: ReportSummary, grouping: ReportFilter.Grouping) -> ReportSection {
        switch grouping {
        case .category: .group(summary.group)
        case .process: .process(summary.processName)
        case .day: .day(Calendar.current.startOfDay(for: summary.date))
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

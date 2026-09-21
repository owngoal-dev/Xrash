import Foundation
import Then
import UIKit
import XrashReport

extension String {
    /// What every search field in this app means by "contains": case- and
    /// diacritic-insensitive, and an empty needle matches everything.
    func matches(_ needle: String) -> Bool {
        needle.isEmpty || localizedStandardContains(needle)
    }

    /// A counted phrase — `"^[\(n) item](inflect: true)"` — with its noun
    /// agreeing with the number. Only `AttributedString` reads that markup;
    /// `String(localized:)` would put it on screen as written. A translation
    /// that carries no markup comes through unchanged.
    init(inflecting phrase: String.LocalizationValue) {
        self.init(AttributedString(localized: phrase).characters)
    }
}

/// The words and glyphs a report is shown with. One place, so the list, the
/// detail header and a share sheet's file name never disagree about what a
/// `313` is called.
enum ReportFormat {
    // MARK: Names

    static func kindLabel(_ kind: ReportKind) -> String {
        switch kind {
        case .crash: String(localized: "Crash")
        case .jetsam: String(localized: "Out of Memory")
        case .panic: String(localized: "Kernel Panic")
        case .hang: String(localized: "Hang")
        case .resource: String(localized: "Resource Limit")
        case .analytics: String(localized: "Analytics")
        case .other: String(localized: "Log")
        }
    }

    static func groupTitle(_ group: ReportGroup) -> String {
        switch group {
        case .app: String(localized: "Apps")
        case .service: String(localized: "Services")
        case .jetsam: String(localized: "Out of Memory")
        case .other: String(localized: "Other")
        }
    }

    /// The colour of the badge on a report's icon, which is the only place a
    /// kind is a colour: a row's tile is artwork, never a tinted symbol.
    static func tint(for summary: ReportSummary) -> UIColor {
        switch summary.kind {
        case .crash: .systemRed
        case .panic: .systemPurple
        case .jetsam: .systemOrange
        case .hang: .systemYellow
        case .resource: .systemTeal
        case .analytics, .other: .secondaryLabel
        }
    }

    // MARK: Rows

    /// `EXC_CRASH (SIGABRT)`. Decided in the Kit, where the daemon's
    /// notification says the same words.
    static func reason(for report: Report) -> String? {
        report.reason
    }

    /// `EXC_CRASH (SIGABRT) · 0.3.7 (58)`. Falls back to the kind while the
    /// report is still just a name on disk.
    static func subtitle(for summary: ReportSummary, reason: String?) -> String {
        [reason ?? kindLabel(summary.kind), summary.appVersion]
            .compactMap(\.self)
            .joined(separator: " · ")
    }

    // MARK: Values

    /// Relative inside a week ("2 hours ago"), an actual date beyond it —
    /// "5 months ago" tells a reader nothing they can line up with a release.
    static func date(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 7 * 24 * 60 * 60 {
            return relativeFormatter.localizedString(for: date, relativeTo: now)
        }
        return shortDateFormatter.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    /// `Fila-2026-09-08-191717` — a share attachment's name, never a title.
    static func fileStem(for processName: String, date: Date) -> String {
        let name = processName
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined()
        return "\(name.isEmpty ? "Report" : name)-\(stampFormatter.string(from: date))"
    }

    static func byteCount(_ count: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: count))
    }

    static func address(_ value: UInt64) -> String {
        "0x" + String(format: "%016llx", value)
    }

    // MARK: Formatters

    /// Built once: a table asks for a hundred of these while a finger moves.
    /// Abbreviated, because the row's subtitle is the interesting half and
    /// "14 hours ago" spelled out eats the width the reason needs.
    private static let relativeFormatter = RelativeDateTimeFormatter().then {
        $0.unitsStyle = .abbreviated
    }

    private static let shortDateFormatter = DateFormatter().then {
        // The day only: with the time as well the date took half the row and
        // the reason beside it was cut to "EXC_CRASH (SIGA…". The detail
        // screen has the full timestamp.
        $0.dateStyle = .medium
        $0.timeStyle = .none
    }

    private static let fullDateFormatter = DateFormatter().then {
        $0.dateStyle = .long
        $0.timeStyle = .medium
    }

    private static let stampFormatter = DateFormatter().then {
        $0.locale = Locale(identifier: "en_US_POSIX")
        $0.dateFormat = "yyyy-MM-dd-HHmmss"
    }

    private static let byteFormatter = ByteCountFormatter().then {
        $0.countStyle = .file
    }
}

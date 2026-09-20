import Foundation

// Small helpers the decoders share. A report is untrusted input — it arrives
// as a file descriptor from a daemon that never looked inside it — so nothing
// here may trap on nonsense.

/// Turning report bytes into a string, or refusing them.
enum ReportText {
    /// How much of a file is inspected before calling it text. A report that
    /// starts with 64 KB of clean text and turns binary later is still worth
    /// showing; scanning all of a 900 KB panic log to decide is not.
    private static let inspectionLimit = 64 * 1024

    /// UTF-8 first, Latin-1 for logs an older tool wrote. Binary files come
    /// back nil so the caller can say "not a report" instead of showing
    /// mojibake.
    static func decode(_ data: Data) -> String? {
        guard isPrintable(data) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// No NUL anywhere, and under 2% other control bytes. Tabs, newlines and
    /// carriage returns are text.
    private static func isPrintable(_ data: Data) -> Bool {
        let head = data.prefix(inspectionLimit)
        var control = 0
        for byte in head {
            if byte == 0 {
                return false
            }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) {
                control += 1
            }
        }
        return control * 50 <= head.count
    }
}

/// The date spellings reports use: `2026-09-08 19:17:17.00 +0900` in the
/// header, four fractional digits in `captureTime`, none at all in some logs.
enum ReportDates {
    private static let formatters: [DateFormatter] = [stamp] + [
        "yyyy-MM-dd HH:mm:ss.SSS Z",
        "yyyy-MM-dd HH:mm:ss.SS Z",
        "yyyy-MM-dd HH:mm:ss Z",
    ].map(make)

    /// `2026-09-08 19:17:17.0000 +0900` — the header's spelling, and the one
    /// the classic report prints back.
    static let stamp = make("yyyy-MM-dd HH:mm:ss.SSSS Z")

    /// `Fila-2026-09-08-191717.ips`. The name is stamped in the device's local
    /// time, so it is read back in the current zone — the formatter's default.
    static let fileNameStamp = make("yyyy-MM-dd-HHmmss")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}

extension NSRegularExpression {
    /// The pattern is a literal in this module; a bad one is a bug caught by
    /// the first test that runs, never something a report can cause.
    convenience init(literal pattern: String) {
        try! self.init(pattern: pattern, options: []) // swiftlint:disable:this force_try
    }

    /// Every capture group of the first match, group 0 first. An unmatched
    /// optional group comes back as an empty string.
    func groups(in text: String) -> [String]? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = firstMatch(in: text, options: [], range: whole) else { return nil }
        return (0 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

import Foundation

/// Text forms of a decoded report. Pure functions; the PDF and the viewers
/// are built on these.
public enum ReportRenderer {
    /// The classic `.crash` layout Xcode and every issue tracker know.
    public static func crashText(_ report: Report) -> String {
        CrashTextRenderer.render(report)
    }

    /// The raw file as indented JSON: header object, blank line, body object.
    /// Non-JSON reports come back unchanged.
    public static func prettyJSON(_ report: Report) -> String {
        let parts = report.rawText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let header = indented(parts[0]), let body = indented(parts[1]) else {
            return report.rawText
        }
        return header + "\n\n" + body
    }

    /// A short issue-tracker summary: what died, why, the faulting stack.
    public static func markdown(_ report: Report) -> String {
        MarkdownRenderer.render(report)
    }

    /// The decoded model as JSON — the symbolicated export.
    public static func modelJSON(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    /// `JSONSerialization` keeps a `UInt64` larger than `Int64.max` exact —
    /// a panic log's kernel image bases depend on it.
    private static func indented(_ text: some StringProtocol) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Plain-words explanations for the summary section.
public enum ReportExplainer {
    /// "The app called abort(), usually after an uncaught exception or a failed assertion."
    public static func explanation(for crash: CrashReport) -> String {
        ExceptionExplainer.explanation(for: crash)
    }

    /// Groups crashes that are the same bug: exception + top non-system frames.
    public static func signature(of crash: CrashReport) -> String {
        CrashSignature.signature(of: crash)
    }
}

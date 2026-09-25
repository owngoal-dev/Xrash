import Foundation
import XrashReport

/// What a report says about itself, in the list row's words: the process by
/// the name its header gives, and `EXC_CRASH (SIGABRT) · 0.2.0 (43)`.
///
/// Reading a report is parsing, and `xrashd` does not parse as root. The
/// daemon opens the file and hands the descriptor to a child that has given
/// its privileges away; this is what that child sends back, and the parent
/// treats it as text from a stranger — see `clamped`.
public struct NoticeDetail: Codable, Equatable, Sendable {
    /// A report larger than this is announced by its name alone.
    public static let maximumReportByteCount = 8 * 1024 * 1024
    /// What one encoded detail may weigh on its way back to the parent.
    public static let maximumEncodedByteCount = 4096
    private static let maximumFieldLength = 120

    public var processName: String
    public var reason: String?
    public var appVersion: String?

    /// `EXC_CRASH (SIGABRT) · 0.2.0 (43)`; nil when the report gave neither.
    public var line: String? {
        let parts = [reason, appVersion].compactMap(\.self).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Decodes `data`, the whole of the file called `fileName`.
    public init?(report data: Data, fileName: String) {
        guard let report = try? ReportDecoder.decode(data, fileName: fileName) else { return nil }
        let row = ReportDecoder.enrich(
            ReportDecoder.summary(path: fileName, byteCount: UInt64(data.count), modified: Date()),
            header: report.header,
            executablePath: report.crash?.process.path,
        )
        processName = row.processName
        reason = report.reason
        appVersion = row.appVersion
    }

    /// One line per field and no longer than a banner shows.
    public var clamped: NoticeDetail {
        var copy = self
        copy.processName = Self.clamp(processName)
        copy.reason = reason.map(Self.clamp)
        copy.appVersion = appVersion.map(Self.clamp)
        return copy
    }

    private static func clamp(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first?.prefix(maximumFieldLength) ?? "")
    }
}

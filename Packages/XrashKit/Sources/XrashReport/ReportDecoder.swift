import Foundation

/// Bytes that are not text, and text with nothing in it, are the same answer to
/// the one caller that asks — there is no report here — so they are one case.
public enum ReportDecodingError: Error, Equatable, Sendable {
    case unreadable
}

/// `.ips` (a header JSON line, then a body JSON object), a jailbreak's basebin
/// log, the legacy text `.crash`, and anything else as `.other` with its text
/// kept.
public enum ReportDecoder {
    /// A row for the list from the name alone — no file is opened.
    /// `Fila-2026-09-08-191717.ips.synced` → process `Fila`, that date, synced.
    public static func summary(path: String, byteCount: UInt64, modified: Date) -> ReportSummary {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        let parsed = ReportFileName(fileName)
        return ReportSummary(
            id: path,
            fileName: fileName,
            processName: parsed.processName,
            kind: parsed.kind,
            // Nothing has been opened yet, so nothing yet says "this is an app".
            group: group(for: parsed.kind, isApp: false),
            date: parsed.date ?? modified,
            byteCount: byteCount,
            isSynced: parsed.isSynced,
        )
    }

    /// The same row once the first line of the file is known. `executablePath`
    /// decides app versus service and comes from a full decode when available.
    public static func enrich(
        _ summary: ReportSummary,
        header: ReportHeader,
        executablePath: String?,
    ) -> ReportSummary {
        var row = summary
        row.kind = BugType.kind(of: header.bugType)
        row.processName = header.appName ?? header.name ?? summary.processName
        row.date = header.timestamp ?? summary.date
        row.bundleID = header.bundleID ?? summary.bundleID
        row.appVersion = headerVersion(header) ?? summary.appVersion
        row.osVersion = header.osVersion ?? summary.osVersion
        row.incidentID = header.incidentID ?? summary.incidentID
        row.group = group(
            for: row.kind,
            isApp: isApp(header: header, executablePath: executablePath, processName: row.processName),
        )
        return row
    }

    /// The header object alone, from the first bytes of a file.
    public static func header(fromPrefix data: Data) -> ReportHeader? {
        IPSDecoder.header(fromPrefix: data)
    }

    public static func decode(_ data: Data, fileName: String) throws -> Report {
        guard let text = ReportText.decode(data), text.contains(where: { !$0.isWhitespace }) else {
            throw ReportDecodingError.unreadable
        }
        if let report = IPSDecoder.decode(text: text) {
            return report
        }
        let name = ReportFileName(fileName)
        if let report = BasebinCrashDecoder.decode(text: text, fileName: name) {
            return report
        }
        return LegacyCrashDecoder.decode(text: text, kind: name.kind)
    }

    // MARK: Grouping

    private static func group(for kind: ReportKind, isApp: Bool) -> ReportGroup {
        switch kind {
        case .jetsam: .jetsam
        case .crash, .hang, .resource: isApp ? .app : .service
        case .panic, .analytics, .other: .other
        }
    }

    /// The executable's path is the answer when we have it. Before a full
    /// decode we only have the header, where a bundle identifier on something
    /// that is not named like a daemon is the best evidence there is.
    private static func isApp(header: ReportHeader, executablePath: String?, processName: String) -> Bool {
        if let executablePath {
            return executablePath.contains(".app/")
        }
        return header.bundleID != nil && !looksLikeDaemon(processName)
    }

    private static func looksLikeDaemon(_ name: String) -> Bool {
        let lower = name.lowercased()
        // launchd, backboardd, mediaserverd: all lowercase and ending in d.
        if lower == name, lower.hasSuffix("d") {
            return true
        }
        return ["daemon", "helper", "agent", "xpcservice"].contains { lower.contains($0) }
    }

    private static func headerVersion(_ header: ReportHeader) -> String? {
        guard let version = header.appVersion else { return nil }
        guard let build = header.buildVersion else { return version }
        return "\(version) (\(build))"
    }
}

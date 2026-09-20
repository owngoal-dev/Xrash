import Foundation

/// Everything the file name alone tells us. The list shows rows before any
/// file is opened, and four reports in five have a `.synced` suffix hiding the
/// extension that would otherwise classify them.
struct ReportFileName {
    /// `Fila` for `Fila-2026-09-08-191717.ips.synced`.
    var processName: String
    /// The stamp in the name, read in the local zone it was written in. Nil
    /// when the name carries no stamp — the caller falls back to `modified`.
    var date: Date?
    var kind: ReportKind
    var isSynced: Bool

    /// Packaging, not identity: peeled off the end in any order, along with a
    /// numeric `.0002` de-duplication counter.
    private static let strippable: Set<String> = ["synced", "ca", "ips", "crash", "log", "txt", "beta"]

    /// `Foo.cpu_resource-2026-…` — the marker classifies, the process is `Foo`.
    private static let resourceMarkers = ["cpu_resource", "wakeups_resource", "diskwrites_resource"]

    private static let stamp = NSRegularExpression(literal: "^(.*?)[-_](\\d{4}-\\d{2}-\\d{2}-\\d{6})")

    init(_ fileName: String) {
        var stem = fileName
        var suffixes = Set<String>()
        while let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            let ext = String(stem[stem.index(after: dot)...]).lowercased()
            let isCounter = !ext.isEmpty && ext.allSatisfy(\.isNumber)
            guard Self.strippable.contains(ext) || isCounter else { break }
            suffixes.insert(ext)
            stem = String(stem[..<dot])
        }

        isSynced = suffixes.contains("synced")
        kind = Self.kind(of: stem.lowercased(), suffixes: suffixes)

        if let groups = Self.stamp.groups(in: stem), groups.count == 3 {
            processName = groups[1]
            date = ReportDates.fileNameStamp.date(from: groups[2])
        } else {
            processName = stem
            date = nil
        }
        for marker in Self.resourceMarkers where processName.hasSuffix(".\(marker)") {
            processName = String(processName.dropLast(marker.count + 1))
        }
    }

    private static func kind(of stem: String, suffixes: Set<String>) -> ReportKind {
        if stem.contains("jetsamevent") {
            return .jetsam
        }
        if stem.contains("panic") {
            return .panic
        }
        if stem.contains("analytics") || stem.contains("sirisearchfeedback") || suffixes.contains("ca") {
            return .analytics
        }
        if stem.contains("stacks") || stem.contains("hang") || stem.contains("spin") {
            return .hang
        }
        if resourceMarkers.contains(where: { stem.contains($0) }) {
            return .resource
        }
        if suffixes.contains("ips") || suffixes.contains("crash") {
            return .crash
        }
        return .other
    }
}

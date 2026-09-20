import Foundation

/// An `.ips` is two JSON documents: the header object on the first line, the
/// body on the rest. Analytics payloads put several objects on several lines,
/// so a body that will not parse is normal and never an error.
enum IPSDecoder {
    /// What the list reads to classify a row. The header is always the first
    /// line; anything past this is the body and not our business here.
    private static let headerPrefixLimit = 8 * 1024

    static func header(fromPrefix data: Data) -> ReportHeader? {
        let prefix = data.prefix(headerPrefixLimit)
        let line = prefix.firstIndex(of: 0x0A).map { prefix[..<$0] } ?? prefix
        guard let object = json(Data(line)) else { return nil }
        return header(from: object)
    }

    private static func header(from object: [String: Any]) -> ReportHeader? {
        // A string on disk, but a couple of agents write it as a number.
        let bugType = object.string("bug_type") ?? object.uint64("bug_type").map(String.init)
        guard let bugType else { return nil }
        var header = ReportHeader(bugType: bugType)
        header.name = object.string("name")
        header.appName = object.string("app_name")
        header.appVersion = object.string("app_version")
        header.buildVersion = object.string("build_version")
        header.bundleID = object.string("bundleID")
        header.incidentID = object.string("incident_id")
        header.osVersion = object.string("os_version")
        header.timestamp = ReportDates.date(from: object.string("timestamp"))
        header.sliceUUID = object.string("slice_uuid")
        if let firstParty = object["is_first_party"] as? NSNumber {
            header.isFirstParty = firstParty.boolValue
        }
        return header
    }

    /// Nil when the first line is not a header object — the caller then tries
    /// the legacy text format.
    static func decode(text: String) -> Report? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first,
              let object = json(Data(first.utf8)),
              let header = header(from: object) else { return nil }

        let kind = BugType.kind(of: header.bugType)
        var report = Report(header: header, kind: kind, rawText: text)
        guard parts.count > 1, let body = json(Data(parts[1].utf8)) else { return report }

        switch kind {
        case .crash:
            report.crash = CrashBodyDecoder.decode(body)
        case .hang, .resource:
            // Some carry a full stackshot, some are a bare counter. Only the
            // shapes we recognise become a crash report.
            if body["threads"] != nil || body["usedImages"] != nil {
                report.crash = CrashBodyDecoder.decode(body)
            }
        case .jetsam:
            report.jetsam = jetsam(from: body)
        case .panic:
            report.panic = panic(from: body)
        case .analytics, .other:
            break
        }
        return report
    }

    private static func jetsam(from body: [String: Any]) -> JetsamReport? {
        guard let status = body.object("memoryStatus") else { return nil }
        var report = JetsamReport(pageSize: status.uint64("pageSize") ?? 16384)
        report.largestProcess = body.string("largestProcess")
        report.processes = body.objects("processes").map { entry in
            var process = JetsamProcess(
                name: entry.string("name") ?? "",
                residentPages: entry.uint64("rpages") ?? 0
            )
            process.pid = entry.int32("pid")
            process.reason = entry.string("reason")
            process.states = entry.strings("states")
            return process
        }
        return report
    }

    private static func panic(from body: [String: Any]) -> PanicReport? {
        guard let text = body.string("panicString") else { return nil }
        var report = PanicReport(panicString: text)
        report.product = body.string("product")
        report.build = body.string("build")
        return report
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

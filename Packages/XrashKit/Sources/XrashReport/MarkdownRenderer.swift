import Foundation

/// What gets pasted into an issue: the headline, the few facts that identify
/// the build, a sentence of explanation and the stack that matters.
enum MarkdownRenderer {
    /// Past this a stack is scrolling, not reading.
    private static let frameLimit = 25

    static func render(_ report: Report) -> String {
        var blocks = [title(report)]
        if let facts = facts(report) {
            blocks.append(facts)
        }
        if let crash = report.crash {
            blocks.append(ExceptionExplainer.explanation(for: crash))
        }
        if let panic = report.panic {
            blocks.append(fenced(panic.panicString))
        }
        if let stack = faultingStack(report) {
            blocks.append(stack)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func title(_ report: Report) -> String {
        let name = report.crash.flatMap { $0.process.name.isEmpty ? nil : $0.process.name }
            ?? report.header.appName ?? report.header.name
        if let exception = report.crash?.exception {
            return "## \(name ?? "A process") crashed — \(exception.typeAndSignal)"
        }
        if let jetsam = report.jetsam {
            guard let largest = jetsam.largestProcess else { return "## Out of Memory" }
            return "## Out of Memory — \(largest)"
        }
        if report.panic != nil {
            return "## Kernel Panic"
        }
        return "## \(name ?? "Report") — \(kindLabel(report.kind))"
    }

    /// What the app calls a kind, spelled here so pasted markdown and the
    /// screen it was copied from agree. The words match `ReportFormat.kindLabel`.
    private static func kindLabel(_ kind: ReportKind) -> String {
        switch kind {
        case .crash: "Crash"
        case .jetsam: "Out of Memory"
        case .panic: "Kernel Panic"
        case .hang: "Hang"
        case .resource: "Resource Limit"
        case .analytics: "Analytics"
        case .other: "Log"
        }
    }

    private static func facts(_ report: Report) -> String? {
        let rows = [
            ("Version", report.crash.flatMap { CrashTextRenderer.version($0.process) }
                ?? report.header.appVersion),
            ("OS", report.crash.flatMap(CrashTextRenderer.osVersion) ?? report.header.osVersion),
            ("Device", report.crash?.device.model),
            ("Date", CrashTextRenderer.stamp(report.crash?.device.captureDate ?? report.header.timestamp)),
            ("Incident", report.crash?.device.incidentID ?? report.header.incidentID),
        ].compactMap { label, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "| \(label) | \(value) |"
        }
        guard !rows.isEmpty else { return nil }
        return (["| | |", "| --- | --- |"] + rows).joined(separator: "\n")
    }

    private static func faultingStack(_ report: Report) -> String? {
        guard let crash = report.crash, let thread = crash.faultingThread else { return nil }
        let frames = thread.frames.prefix(frameLimit)
        guard !frames.isEmpty else { return nil }
        let heading = "Thread \(thread.index)\(thread.isTriggered ? " Crashed" : ""):"
        let lines = frames.enumerated().map { index, frame -> String in
            let image = crash.images.image(for: frame)
            let symbol = frame.symbol ?? String(format: "0x%llx", frame.address)
            let offset = frame.symbol == nil ? "" : " + \(frame.symbolLocation ?? 0)"
            return "\(index)\t\(image?.name ?? "???")\t\(symbol)\(offset)"
        }
        return fenced(([heading] + lines).joined(separator: "\n"))
    }

    private static func fenced(_ text: String) -> String {
        "```\n\(text)\n```"
    }
}

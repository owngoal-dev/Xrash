import Foundation

/// The classic `.crash` layout. Xcode, every issue tracker and every engineer
/// reading a bug report already knows it, so the exact spelling of the labels
/// matters more than any improvement we could make to them.
enum CrashTextRenderer {
    static func render(_ report: Report) -> String {
        if let crash = report.crash {
            return crashText(crash, header: report.header)
        }
        if let jetsam = report.jetsam {
            return jetsamText(jetsam)
        }
        if let panic = report.panic {
            return panic.panicString
        }
        return report.rawText
    }

    // MARK: A process that died

    private static func crashText(_ crash: CrashReport, header: ReportHeader) -> String {
        var blocks = [String]()
        blocks.append(identity(crash, header: header))
        blocks.append(timing(crash, header: header))
        blocks.append(failure(crash))
        if !crash.applicationInfo.isEmpty {
            blocks.append((["Application Specific Information:"] + crash.applicationInfo).joined(separator: "\n"))
        }
        if !crash.lastExceptionBacktrace.isEmpty {
            blocks.append((["Last Exception Backtrace:"]
                    + numbered(crash.lastExceptionBacktrace, images: crash.images)).joined(separator: "\n"))
        }
        for thread in crash.threads {
            blocks.append(([threadHeading(thread)] + numbered(thread.frames, images: crash.images))
                .joined(separator: "\n"))
        }
        if let faulting = crash.faultingThread, !faulting.registers.isEmpty {
            blocks.append(registerBlock(faulting, cpuType: crash.process.cpuType))
        }
        blocks.append((["Binary Images:"] + crash.images.map(imageLine)).joined(separator: "\n"))
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private static func identity(_ crash: CrashReport, header: ReportHeader) -> String {
        [
            field("Incident Identifier", crash.device.incidentID ?? header.incidentID),
            field("CrashReporter Key", crash.device.crashReporterKey),
            field("Hardware Model", crash.device.model),
            field("Process", withPID(crash.process.name, crash.process.pid)),
            field("Path", crash.process.path),
            field("Identifier", crash.process.bundleID ?? header.bundleID),
            field("Version", version(crash.process)),
            field("Code Type", crash.process.cpuType),
            field("Role", crash.process.role),
            field("Parent Process", withPID(crash.process.parentName, crash.process.parentPID)),
            field("Coalition", crash.process.coalitionName),
        ].compactMap(\.self).joined(separator: "\n")
    }

    private static func timing(_ crash: CrashReport, header: ReportHeader) -> String {
        [
            field("Date/Time", stamp(crash.device.captureDate ?? header.timestamp)),
            field("Launch Time", stamp(crash.process.launchDate)),
            field("OS Version", osVersion(crash) ?? header.osVersion),
        ].compactMap(\.self).joined(separator: "\n")
    }

    private static func failure(_ crash: CrashReport) -> String {
        var lines = [String]()
        if let exception = crash.exception {
            lines.append("Exception Type:  \(exception.typeAndSignal)")
            if let subtype = exception.subtype {
                lines.append("Exception Subtype: \(subtype)")
            }
            if let codes = exception.codes {
                lines.append("Exception Codes: \(codes)")
            }
            if let message = exception.message {
                lines.append("Exception Message: \(message)")
            }
        }
        if let termination = crash.termination {
            let reason = [termination.namespace, termination.code.map(String.init), termination.indicator]
                .compactMap(\.self).joined(separator: " ")
            if !reason.isEmpty {
                lines.append("Termination Reason: \(reason)")
            }
            for detail in termination.reasons {
                lines.append("Termination Description: \(detail)")
            }
            if let process = withPID(termination.byProcess, termination.byPID) {
                lines.append("Terminating Process: \(process)")
            }
        }
        if let index = crash.faultingThreadIndex {
            lines.append("Triggered by Thread:  \(index)")
        }
        return lines.joined(separator: "\n")
    }

    /// `Thread 0 Crashed::  Dispatch queue: com.apple.main-thread` — the
    /// doubled colon is what the system's own translation prints.
    private static func threadHeading(_ thread: ReportThread) -> String {
        let descriptor = thread.name ?? thread.queue.map { "Dispatch queue: \($0)" }
        let crashed = thread.isTriggered ? " Crashed" : ""
        guard let descriptor else { return "Thread \(thread.index)\(crashed):" }
        return "Thread \(thread.index)\(crashed)::  \(descriptor)"
    }

    private static func numbered(_ frames: [Frame], images: [BinaryImage]) -> [String] {
        frames.enumerated().map { index, frame in frameLine(index, frame, images: images) }
    }

    private static func frameLine(_ index: Int, _ frame: Frame, images: [BinaryImage]) -> String {
        let image = images.image(for: frame)
        var line = column(String(index), 3) + " " + column(image?.name ?? "???", 30)
        line += String(format: "\t0x%016llx ", frame.address)
        if let symbol = frame.symbol {
            line += "\(symbol) + \(frame.symbolLocation ?? 0)"
        } else {
            line += String(format: "0x%llx + %llu", image?.base ?? 0, frame.imageOffset)
        }
        if let file = frame.sourceFile, let number = frame.sourceLine {
            line += " (\(file):\(number))"
        }
        return line
    }

    private static func registerBlock(_ thread: ReportThread, cpuType: String?) -> String {
        let flavour = (cpuType ?? "ARM-64").hasPrefix("ARM-64") ? "ARM Thread State (64-bit)" : "Thread State"
        var lines = ["Thread \(thread.index) crashed with \(flavour):"]
        for row in stride(from: 0, to: thread.registers.count, by: 4) {
            let cells = thread.registers[row ..< min(row + 4, thread.registers.count)].map {
                rightAlign($0.name, 4) + String(format: ": 0x%016llx", $0.value)
            }
            lines.append("    " + cells.joined(separator: "   "))
        }
        return lines.joined(separator: "\n")
    }

    private static func imageLine(_ image: BinaryImage) -> String {
        let last = image.base &+ image.size &- (image.size > 0 ? 1 : 0)
        let range = rightAlign(hex(image.base), 18) + " - " + rightAlign(hex(last), 18)
        let arch = image.arch.map { " \($0)" } ?? ""
        return "\(range) \(image.name)\(arch)  <\(image.uuid.lowercased())> \(image.path)"
    }

    // MARK: Memory pressure kills

    private static func jetsamText(_ jetsam: JetsamReport) -> String {
        var lines = ["Jetsam Event", ""]
        if let largest = jetsam.largestProcess {
            lines.append("Largest process: \(largest)")
        }
        lines.append("Page size: \(jetsam.pageSize)")
        lines.append("")
        lines.append(column("Process", 32) + column("PID", 8) + column("Resident", 12) + "Reason")
        let sorted = jetsam.processes.sorted { $0.residentPages > $1.residentPages }
        for process in sorted {
            let megabytes = process.residentPages &* jetsam.pageSize / (1024 * 1024)
            lines.append(
                column(process.name, 32)
                    + column(process.pid.map(String.init) ?? "", 8)
                    + column("\(megabytes) MB", 12)
                    + (process.reason ?? process.states.joined(separator: ", ")),
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Spelling

    /// The classic report puts every header value in the same column.
    private static func field(_ key: String, _ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let label = key + ":"
        return label + String(repeating: " ", count: max(1, 21 - label.count)) + value
    }

    /// A left-aligned column: padded to `width`, and always at least one
    /// space wide at the end so an over-long value still separates.
    private static func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func rightAlign(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llx", value)
    }

    private static func withPID(_ name: String?, _ pid: Int32?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return pid.map { "\(name) [\($0)]" } ?? name
    }

    /// `0.3.8 (62)`. Shared with the Markdown renderer, as `stamp` is.
    static func version(_ process: ProcessDetails) -> String? {
        guard let version = process.version else { return process.build }
        return process.build.map { "\(version) (\($0))" } ?? version
    }

    /// `iPhone OS 26.6.1 (23G83)`.
    static func osVersion(_ crash: CrashReport) -> String? {
        guard let train = crash.device.osTrain else { return nil }
        return crash.device.osBuild.map { "\(train) (\($0))" } ?? train
    }

    static func stamp(_ date: Date?) -> String? {
        date.map(ReportDates.stamp.string(from:))
    }
}

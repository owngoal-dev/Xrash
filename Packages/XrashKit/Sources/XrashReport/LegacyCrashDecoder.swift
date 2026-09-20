import Foundation

/// The plain-text `.crash` Apple wrote before iOS 14 and that symbolicators
/// still emit. Anything unrecognised falls out as `nil` and the file is kept
/// as text — this format has no version and every tool bends it a little.
///
/// This file is the bookkeeping: which section of the report a line is in, and
/// what a header field means. `LegacyCrashLines` reads the lines themselves.
///
// ponytail: line-oriented and forgiving rather than a grammar. It handles the
// shapes we have seen; a report it cannot parse still opens as text.
enum LegacyCrashDecoder {
    static func decode(text: String, kind: ReportKind) -> Report {
        var parser = Parser()
        parser.run(over: text)
        guard let crash = parser.finish() else {
            return Report(header: ReportHeader(bugType: ""), kind: kind, rawText: text)
        }
        // 109 is what this format's header line would have said.
        var header = ReportHeader(bugType: "109")
        header.name = crash.process.name
        header.appName = crash.process.name
        header.appVersion = crash.process.version
        header.buildVersion = crash.process.build
        header.bundleID = crash.process.bundleID
        header.incidentID = crash.device.incidentID
        header.osVersion = CrashTextRenderer.osVersion(crash) ?? ""
        header.timestamp = crash.device.captureDate
        var report = Report(header: header, kind: kind == .other ? .crash : kind, rawText: text)
        report.crash = crash
        return report
    }

    // MARK: The line parser

    private enum Mode {
        case fields
        case frames(Int)
        case registers(Int)
        case images
        case applicationInfo
    }

    private static let threadState = NSRegularExpression(literal: "^Thread (\\d+) crashed with .*:$")
    private static let threadNamed = NSRegularExpression(literal: "^Thread (\\d+) name:[ \t]*(.*)$")
    private static let threadStart = NSRegularExpression(literal: "^Thread (\\d+)( Crashed)?::?[ \t]*(.*)$")
    private static let fieldPattern = NSRegularExpression(literal: "^([A-Za-z][A-Za-z0-9 /_-]*):[ \t]*(.*)$")

    private struct Parser {
        private var mode = Mode.fields
        private var crash = CrashReport()
        private var exceptionType: String?
        private var exceptionSignal: String?
        private var exceptionSubtype: String?
        private var exceptionCodes: String?
        private var exceptionMessage: String?
        private var termination = TerminationDetails()
        private var sawTermination = false
        private var sawHeader = false

        mutating func run(over text: String) {
            for line in text.components(separatedBy: .newlines) {
                consume(line)
            }
        }

        /// Nil when the text held no recognisable crash header at all.
        mutating func finish() -> CrashReport? {
            guard sawHeader else { return nil }
            if let type = exceptionType {
                var exception = ExceptionDetails(type: type)
                exception.signal = exceptionSignal
                exception.subtype = exceptionSubtype
                exception.codes = exceptionCodes
                exception.message = exceptionMessage
                crash.exception = exception
            }
            if sawTermination {
                crash.termination = termination
            }
            // "Triggered by Thread:" is read before any thread block exists, so
            // it is only now that it can be checked — and some tools omit it
            // and mark the thread instead.
            if let index = crash.faultingThreadIndex, !crash.threads.indices.contains(index) {
                crash.faultingThreadIndex = nil
            }
            if crash.faultingThreadIndex == nil {
                crash.faultingThreadIndex = crash.threads.firstIndex { $0.isTriggered }
            }
            resolveFrames()
            return crash
        }

        private mutating func consume(_ line: String) {
            // The line patterns are lazy captures beside optional whitespace,
            // quadratic on a long run of spaces: 16 KB of them costs a second.
            // No line a crash reporter writes is this long; the raw text keeps it.
            guard line.utf8.count <= 4096 else { return }
            guard !beginsSection(line) else { return }
            switch mode {
            case let .frames(index):
                if let frame = LegacyCrashDecoder.frame(from: line) {
                    crash.threads[index].frames.append(frame)
                } else {
                    mode = .fields
                    field(line)
                }
            case let .registers(index):
                let registers = LegacyCrashDecoder.registers(from: line)
                if registers.isEmpty {
                    mode = .fields
                    field(line)
                } else {
                    crash.threads[index].registers.append(contentsOf: registers)
                }
            case .images:
                if let image = LegacyCrashDecoder.image(from: line) {
                    crash.images.append(image)
                }
            case .applicationInfo:
                crash.applicationInfo.append(line.trimmingCharacters(in: .whitespaces))
            case .fields:
                field(line)
            }
        }

        /// The lines that only change which section we are in: a blank line
        /// closes a block, a thread or section heading opens one. True when
        /// the line was one of those and there is nothing left to read from it.
        private mutating func beginsSection(_ line: String) -> Bool {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                switch mode {
                case .registers, .applicationInfo, .frames: mode = .fields
                default: break
                }
                return true
            }
            if let groups = threadState.groups(in: line), let index = thread(at: groups[1]) {
                mode = .registers(index)
                return true
            }
            if let groups = threadNamed.groups(in: line), let index = thread(at: groups[1]) {
                describe(thread: index, with: groups[2])
                return true
            }
            if let groups = threadStart.groups(in: line), let index = thread(at: groups[1]) {
                crash.threads[index].isTriggered = !groups[2].isEmpty
                describe(thread: index, with: groups[3])
                mode = .frames(index)
                return true
            }
            if line.hasPrefix("Binary Images:") {
                mode = .images
                return true
            }
            if line.hasPrefix("Application Specific Information:") {
                mode = .applicationInfo
                return true
            }
            return false
        }

        // MARK: Header fields

        private mutating func field(_ line: String) {
            guard let groups = LegacyCrashDecoder.fieldPattern.groups(in: line) else { return }
            let value = groups[2].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            switch groups[1] {
            case "Incident Identifier": crash.device.incidentID = value
            case "CrashReporter Key": crash.device.crashReporterKey = value
            case "Hardware Model": crash.device.model = value
            case "Process":
                let (name, pid) = LegacyCrashDecoder.nameAndPID(value)
                crash.process.name = name
                crash.process.pid = pid
                sawHeader = true
            case "Path":
                crash.process.path = value
                sawHeader = true
            case "Identifier": crash.process.bundleID = value
            case "Version":
                let (version, build) = LegacyCrashDecoder.nameAndDetail(value)
                crash.process.version = version
                crash.process.build = build
            case "Code Type": crash.process.cpuType = LegacyCrashDecoder.nameAndDetail(value).0
            case "Role": crash.process.role = value
            case "Parent Process":
                let (name, pid) = LegacyCrashDecoder.nameAndPID(value)
                crash.process.parentName = name
                crash.process.parentPID = pid
            case "Responsible Process": crash.process.responsibleName = LegacyCrashDecoder.nameAndPID(value).0
            case "Coalition": crash.process.coalitionName = LegacyCrashDecoder.nameAndPID(value).0
            case "Date/Time": crash.device.captureDate = ReportDates.date(from: value)
            case "Launch Time": crash.process.launchDate = ReportDates.date(from: value)
            case "OS Version":
                let (train, build) = LegacyCrashDecoder.nameAndDetail(value)
                crash.device.osTrain = train
                crash.device.osBuild = build
            case "Exception Type":
                let (type, signal) = LegacyCrashDecoder.nameAndDetail(value)
                exceptionType = type
                exceptionSignal = signal
                sawHeader = true
            case "Exception Subtype": exceptionSubtype = value
            case "Exception Codes": exceptionCodes = value
            case "Exception Message": exceptionMessage = value
            case "Termination Reason":
                LegacyCrashDecoder.apply(reason: value, to: &termination)
                sawTermination = true
            case "Termination Description":
                termination.reasons.append(value)
                sawTermination = true
            case "Terminating Process":
                let (name, pid) = LegacyCrashDecoder.nameAndPID(value)
                termination.byProcess = name
                termination.byPID = pid
                sawTermination = true
            case "Triggered by Thread": crash.faultingThreadIndex = Int(value)
            default: break
            }
        }

        // MARK: Threads

        private mutating func describe(thread index: Int, with text: String) {
            let value = text.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            let queueLabel = "Dispatch queue:"
            if value.hasPrefix(queueLabel) {
                crash.threads[index].queue = value.dropFirst(queueLabel.count)
                    .trimmingCharacters(in: .whitespaces)
            } else {
                crash.threads[index].name = value
            }
        }

        /// Threads are numbered in the file; gaps are filled so the index in
        /// `threads` always equals the number the report printed. A number
        /// beyond the cap is a corrupt file, not a thread.
        private mutating func thread(at text: String) -> Int? {
            guard let index = Int(text), index >= 0, index < Parser.threadLimit else { return nil }
            while crash.threads.count <= index {
                crash.threads.append(ReportThread(index: crash.threads.count))
            }
            return index
        }

        private static let threadLimit = 4096

        /// Legacy frames carry an absolute address; the image it belongs to is
        /// whichever one's range contains it.
        private mutating func resolveFrames() {
            guard !crash.images.isEmpty else { return }
            for threadIndex in crash.threads.indices {
                for frameIndex in crash.threads[threadIndex].frames.indices {
                    let address = crash.threads[threadIndex].frames[frameIndex].address
                    guard let image = crash.images.index(containing: address) else { continue }
                    crash.threads[threadIndex].frames[frameIndex].imageIndex = image
                    crash.threads[threadIndex].frames[frameIndex].imageOffset = address &- crash.images[image].base
                }
            }
        }
    }
}

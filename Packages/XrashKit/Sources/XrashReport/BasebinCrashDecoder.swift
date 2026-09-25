import Foundation

/// The plain-text log a jailbreak's basebin writes for the processes it lives
/// in — `launchd`, `jailbreakd` — which the system's own reporter never sees
/// die. No JSON header, no process name and no date inside: both come from the
/// file name, `launchd-1789969423.319857-1-2026-09-21-134343.ips`.
///
/// One thread, the crashed one. Its frames arrive symbolicated by the reporter
/// and its images carry a load address and nothing else, so an image here has
/// no UUID and no size.
enum BasebinCrashDecoder {
    /// Nil when the text is not this format — the caller tries the next one.
    static func decode(text: String, fileName: ReportFileName) -> Report? {
        var parser = Parser()
        for line in text.components(separatedBy: .newlines) {
            parser.consume(line)
        }
        guard var crash = parser.finish() else { return nil }
        crash.process.name = fileName.processName
        crash.process.pid = fileName.pid
        crash.process.path = crash.images.first { $0.name == fileName.processName }?.path ?? ""
        crash.device.captureDate = fileName.date

        // 109 is what a text crash report's header line would have said.
        var header = ReportHeader(bugType: "109")
        header.name = fileName.processName
        header.appName = fileName.processName
        header.osVersion = CrashTextRenderer.osVersion(crash)
        header.timestamp = fileName.date
        var report = Report(header: header, kind: .crash, rawText: text)
        report.crash = crash
        return report
    }

    // MARK: The line parser

    private enum Mode {
        case fields, registers, backtrace, stackTrace, images
    }

    private static let crashedThread = NSRegularExpression(literal: "^Thread (\\d+) crashed\\.$")
    private static let fieldPattern = NSRegularExpression(literal: "^([A-Za-z][A-Za-z0-9 \\[\\]]*):[ \t]*(.*)$")
    private static let registerPattern = NSRegularExpression(literal: "([a-z][a-z0-9]{0,4}) *= *(0x[0-9a-fA-F]+)")
    private static let osPattern = NSRegularExpression(literal: "^Version (.+?) \\(Build (.+)\\)$")
    private static let imagePattern = NSRegularExpression(literal: "^(0x[0-9a-fA-F]+)[ \t]+(/.*)$")
    /// `0x1030: name (0x1000 + 0x30) (/path/image(0x1000) + 0x30)`.
    private static let framePattern = NSRegularExpression(
        literal: "^(0x[0-9a-fA-F]+): (.*) \\((0x[0-9a-fA-F]+) \\+ (0x[0-9a-fA-F]+)\\) "
            + "\\((/.*)\\((0x[0-9a-fA-F]+)\\) \\+ (0x[0-9a-fA-F]+)\\)$",
    )

    /// What the reporter prints where it has no name to give.
    private static let placeholders: Set<String> = ["<redacted>", "<unexported>"]

    /// The order the model keeps registers in; `flags` is not one of them.
    private static let registerOrder = (0 ... 28).map { "x\($0)" } + ["fp", "lr", "sp", "pc", "cpsr", "far", "esr"]

    private struct Parser {
        private var mode = Mode.fields
        private var crash = CrashReport()
        private var thread = ReportThread(index: 0)
        private var sawCrashedThread = false
        private var exceptionType: String?
        private var exceptionCodes = [String]()
        private var exceptionMessage: String?
        private var signal: String?
        private var registers = [String: UInt64]()
        /// Image bases as the backtrace spelled them, by frame.
        private var frameBases = [UInt64?]()

        mutating func consume(_ line: String) {
            // Greedy captures over a line no reporter writes; the raw text keeps it.
            guard line.utf8.count <= 4096 else { return }
            guard !beginsSection(line) else { return }
            switch mode {
            case .fields: field(line)
            // "Stripped State" is pc, lr, sp and fp again with the pointer
            // authentication bits removed. It comes second and wins: those are
            // the values an address lookup can use.
            case .registers: readRegisters(line)
            case .backtrace: backtraceFrame(line)
            case .stackTrace: stackTraceFrame(line)
            case .images: image(line)
            }
        }

        /// Nil unless the text said which thread crashed and why.
        mutating func finish() -> CrashReport? {
            guard sawCrashedThread, exceptionType != nil || signal != nil else { return nil }
            var exception = ExceptionDetails(type: exceptionType ?? signal ?? "")
            exception.codes = exceptionCodes.isEmpty ? nil : exceptionCodes.joined(separator: ", ")
            exception.subtype = BasebinCrashDecoder.subtype(type: exception.type, codes: exceptionCodes)
            exception.message = exceptionMessage
            crash.exception = exception

            thread.registers = BasebinCrashDecoder.registerOrder.compactMap { name in
                registers[name].map { Register(name: name, value: $0) }
            }
            resolveFrames()
            crash.threads = [thread]
            crash.faultingThreadIndex = 0
            return crash
        }

        private mutating func beginsSection(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                mode = .fields
                return true
            }
            switch trimmed {
            case "Register State:", "Stripped State:": mode = .registers
            case "Backtrace:": mode = .backtrace
            case "Stack trace:": mode = .stackTrace
            case "Images:": mode = .images
            default:
                guard let groups = BasebinCrashDecoder.crashedThread.groups(in: trimmed) else { return false }
                thread.id = UInt64(groups[1])
                thread.isTriggered = true
                sawCrashedThread = true
            }
            return true
        }

        private mutating func field(_ line: String) {
            guard let groups = BasebinCrashDecoder.fieldPattern.groups(in: line) else { return }
            let value = groups[2].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            switch groups[1] {
            case "Device Model": crash.device.model = value
            case "Device Version":
                guard let version = BasebinCrashDecoder.osPattern.groups(in: value) else { break }
                crash.device.osTrain = version[1]
                crash.device.osBuild = version[2]
            case "Architecture": crash.process.cpuType = value
            case "Signal": signal = LegacyCrashDecoder.nameAndDetail(value).0
            case "Exception": exceptionType = value
            case "Exception Reason": exceptionMessage = value
            case let name where name.hasPrefix("Exception Code["):
                // `0x0000000000000008 (8)` — the hex is the spelling reports use.
                exceptionCodes.append(LegacyCrashDecoder.nameAndDetail(value).0)
            default: break
            }
        }

        private mutating func readRegisters(_ line: String) {
            let whole = NSRange(line.startIndex..., in: line)
            for match in BasebinCrashDecoder.registerPattern.matches(in: line, options: [], range: whole) {
                guard let name = Range(match.range(at: 1), in: line),
                      let value = Range(match.range(at: 2), in: line),
                      let number = UInt64(hex: String(line[value])) else { continue }
                registers[String(line[name])] = number
            }
        }

        private mutating func backtraceFrame(_ line: String) {
            guard let groups = BasebinCrashDecoder.framePattern.groups(in: line),
                  let address = UInt64(hex: groups[1]),
                  // A return address printed with its signature still on; the
                  // reporter repeats it stripped on the next line.
                  BasebinCrashDecoder.isStripped(address) else { return }
            var frame = Frame(imageIndex: nil, imageOffset: UInt64(hex: groups[7]) ?? 0, address: address)
            if !BasebinCrashDecoder.placeholders.contains(groups[2]), let offset = UInt64(hex: groups[4]) {
                frame.symbol = groups[2]
                frame.symbolLocation = offset
                frame.symbolSource = .report
            }
            thread.frames.append(frame)
            frameBases.append(UInt64(hex: groups[6]))
        }

        /// A signal handler's view: no unwinding, only where it was and where
        /// it would have returned to.
        private mutating func stackTraceFrame(_ line: String) {
            guard let groups = BasebinCrashDecoder.registerPattern.groups(in: line),
                  groups[1] == "pc" || groups[1] == "lr",
                  let address = UInt64(hex: groups[2]), BasebinCrashDecoder.isStripped(address) else { return }
            thread.frames.append(Frame(imageIndex: nil, imageOffset: 0, address: address))
            frameBases.append(nil)
        }

        private mutating func image(_ line: String) {
            guard let groups = BasebinCrashDecoder.imagePattern.groups(in: line),
                  let base = UInt64(hex: groups[1]) else { return }
            let path = groups[2].trimmingCharacters(in: .whitespaces)
            let name = path.split(separator: "/").last.map(String.init) ?? path
            crash.images.append(BinaryImage(name: name, path: path, uuid: "", base: base, size: 0))
        }

        /// A backtrace frame names its image's base. A bare program counter
        /// does not, and with no sizes to test against it belongs to the
        /// nearest image loaded below it — true of code, which is all a
        /// program counter points at.
        private mutating func resolveFrames() {
            for index in thread.frames.indices {
                let address = thread.frames[index].address
                let image = if let base = frameBases[index] {
                    crash.images.firstIndex { $0.base == base }
                } else {
                    crash.images.indices
                        .filter { crash.images[$0].base <= address }
                        .max { crash.images[$0].base < crash.images[$1].base }
                }
                guard let image else { continue }
                thread.frames[index].imageIndex = image
                thread.frames[index].imageOffset = address &- crash.images[image].base
            }
        }
    }

    // MARK: Small value shapes

    /// User-space addresses fit in 47 bits; anything above is a signature.
    private static func isStripped(_ address: UInt64) -> Bool {
        address >> 47 == 0
    }

    /// `KERN_INVALID_ADDRESS at 0x…`, which Apple's reporter derives from the
    /// same two codes: the kern_return_t and the address.
    private static func subtype(type: String, codes: [String]) -> String? {
        guard type == "EXC_BAD_ACCESS", codes.count == 2,
              let code = UInt64(hex: codes[0]), let address = UInt64(hex: codes[1]) else { return nil }
        let name: String
        switch code {
        case 1: name = "KERN_INVALID_ADDRESS"
        case 2: name = "KERN_PROTECTION_FAILURE"
        default: return nil
        }
        return "\(name) at 0x" + String(format: "%016llx", address)
    }
}

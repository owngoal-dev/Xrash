import Foundation

/// One line of a legacy `.crash` in, one model value out. Nothing here holds
/// state; the file-level bookkeeping is `LegacyCrashDecoder`'s `Parser`.
extension LegacyCrashDecoder {
    private static let framePattern =
        NSRegularExpression(literal: "^[ \t]*(\\d+)[ \t]+(.+?)[ \t]+(0x[0-9a-fA-F]+)[ \t]*(.*)$")
    private static let imagePattern = NSRegularExpression(
        literal: "^[ \t]*(0x[0-9a-fA-F]+)[ \t]*-[ \t]*(0x[0-9a-fA-F]+)[ \t]+(.+?)[ \t]+"
            + "<([0-9a-fA-F-]{32,36})>[ \t]+(.*)$",
    )
    private static let registerPattern = NSRegularExpression(literal: "([a-z][a-z0-9]{0,4}): +(0x[0-9a-fA-F]+)")
    private static let bracketedPID = NSRegularExpression(literal: "^(.*?)[ \t]*\\[(\\d+)\\]$")
    private static let parenthesised = NSRegularExpression(literal: "^(.*?)[ \t]*\\((.*)\\)$")
    private static let sourceLocation = NSRegularExpression(literal: "^(.*?)[ \t]*\\(([^()]+):(\\d+)\\)$")

    private static let architectures = ["arm64", "arm64e", "armv7", "armv7s", "x86_64", "i386"]

    // MARK: Line shapes

    /// `0   Crasher  0x0000000100088410 -[RootViewController tapped:] + 84`.
    static func frame(from line: String) -> Frame? {
        guard let groups = framePattern.groups(in: line), let address = UInt64(hex: groups[3]) else { return nil }
        var frame = Frame(imageIndex: nil, imageOffset: 0, address: address)
        var tail = groups[4].trimmingCharacters(in: .whitespaces)
        if let located = sourceLocation.groups(in: tail), let line = Int(located[3]) {
            frame.sourceFile = located[2]
            frame.sourceLine = line
            tail = located[1]
        }
        // "__pthread_kill + 8", or "0x1a4000000 + 16644" when unsymbolicated.
        let parts = tail.components(separatedBy: " + ")
        if parts.count == 2, let offset = UInt64(parts[1]), !parts[0].hasPrefix("0x") {
            frame.symbol = parts[0]
            frame.symbolLocation = offset
            frame.symbolSource = .report
        } else if !tail.isEmpty, !tail.hasPrefix("0x") {
            frame.symbol = tail
            frame.symbolSource = .report
        }
        return frame
    }

    /// `    x0: 0x0000000000000000   x1: 0x0000000000000000 …` — several to a
    /// line, and an empty result is how the caller knows the block ended.
    static func registers(from line: String) -> [Register] {
        let whole = NSRange(line.startIndex..., in: line)
        return registerPattern.matches(in: line, options: [], range: whole).compactMap { match in
            guard let name = Range(match.range(at: 1), in: line),
                  let value = Range(match.range(at: 2), in: line),
                  let number = UInt64(hex: String(line[value])) else { return nil }
            return Register(name: String(line[name]), value: number)
        }
    }

    /// `0x100084000 - 0x1000abfff +Crasher arm64  <uuid> /path/Crasher`.
    static func image(from line: String) -> BinaryImage? {
        guard let groups = imagePattern.groups(in: line),
              let base = UInt64(hex: groups[1]), let end = UInt64(hex: groups[2]) else { return nil }
        // "+Crasher arm64" — the leading + marks the main executable.
        var words = groups[3].split(separator: " ").map(String.init)
        var arch: String?
        if words.count > 1, let last = words.last, architectures.contains(last) {
            arch = words.removeLast()
        }
        let name = words.joined(separator: " ")
        var image = BinaryImage(
            name: name.hasPrefix("+") ? String(name.dropFirst()) : name,
            path: groups[5].trimmingCharacters(in: .whitespaces),
            uuid: uuidString(groups[4]),
            base: base,
            // An end below the base is a corrupt line, not a zero-length image.
            size: end >= base ? end &- base &+ 1 : 0,
        )
        image.arch = arch
        return image
    }

    // MARK: Small value shapes

    /// `launchd [1]` → `("launchd", 1)`.
    static func nameAndPID(_ value: String) -> (String, Int32?) {
        guard let groups = bracketedPID.groups(in: value) else { return (value, nil) }
        return (groups[1], Int32(groups[2]))
    }

    /// `EXC_BAD_ACCESS (SIGSEGV)` → `("EXC_BAD_ACCESS", "SIGSEGV")`.
    static func nameAndDetail(_ value: String) -> (String, String?) {
        guard let groups = parenthesised.groups(in: value), !groups[1].isEmpty else { return (value, nil) }
        return (groups[1], groups[2].isEmpty ? nil : groups[2])
    }

    /// `SIGNAL 11 Segmentation fault: 11`, or the older
    /// `Namespace SPRINGBOARD, Code 0x8badf00d`.
    static func apply(reason: String, to termination: inout TerminationDetails) {
        if reason.hasPrefix("Namespace ") {
            let parts = reason.dropFirst("Namespace ".count).components(separatedBy: ", Code ")
            termination.namespace = parts.first
            termination.code = parts.count > 1 ? hexOrDecimal(parts[1]) : nil
            return
        }
        let head = reason.split(separator: " ", maxSplits: 1).map(String.init)
        termination.namespace = head.first
        guard head.count > 1 else { return }
        let tail = head[1].split(separator: " ", maxSplits: 1).map(String.init)
        if let code = tail.first.flatMap(hexOrDecimal) {
            termination.code = code
            termination.indicator = tail.count > 1 ? tail[1] : nil
        } else {
            termination.indicator = head[1]
        }
    }

    /// `0x8badf00d` is hex, `11` is not — the format uses both.
    private static func hexOrDecimal(_ text: String) -> UInt64? {
        text.hasPrefix("0x") || text.hasPrefix("0X") ? UInt64(hex: text) : UInt64(text)
    }

    /// 32 hex digits in the file, dashed and uppercase in the model.
    private static func uuidString(_ raw: String) -> String {
        let hex = raw.filter(\.isHexDigit).uppercased()
        guard hex.count == 32 else { return raw.uppercased() }
        let boundaries = [0, 8, 12, 16, 20, 32]
        return (0 ..< 5).map { index in
            let start = hex.index(hex.startIndex, offsetBy: boundaries[index])
            let end = hex.index(hex.startIndex, offsetBy: boundaries[index + 1])
            return String(hex[start ..< end])
        }.joined(separator: "-")
    }
}

extension UInt64 {
    /// `0x1a4000000` or `1a4000000`; nil rather than a trap on anything else.
    init?(hex text: some StringProtocol) {
        let digits = text.hasPrefix("0x") || text.hasPrefix("0X") ? text.dropFirst(2) : text[...]
        guard !digits.isEmpty, let value = UInt64(digits, radix: 16) else { return nil }
        self = value
    }
}

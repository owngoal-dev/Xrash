import Foundation

/// What a register's value *means*, where that can be said: the image an
/// address falls in, the stack, the condition flags in `cpsr`, the exception
/// class in `esr`. A value with nothing to say about it gets no note — most of
/// a register dump is zeros and small integers.
public enum RegisterNotes {
    public static func note(for register: Register, thread: ReportThread, in crash: CrashReport) -> String? {
        switch register.name.lowercased() {
        case "cpsr": conditionFlags(register.value)
        case "esr": exceptionClass(register.value)
        default: location(of: register.value, thread: thread, in: crash)
        }
    }

    // MARK: Addresses

    /// Below the first page nothing is a real address — a small integer in a
    /// register, not a pointer.
    private static let addressFloor: UInt64 = 0x1000

    private static func location(of value: UInt64, thread: ReportThread, in crash: CrashReport) -> String? {
        guard value >= addressFloor else { return nil }
        // The frame that has this address already carries its symbol.
        if let frame = thread.frames.first(where: { $0.address == value }), let symbol = frame.symbol {
            let offset = frame.symbolLocation.map { " + \($0)" } ?? ""
            return symbol + offset
        }
        if let index = crash.images.index(containing: value) {
            let image = crash.images[index]
            return "\(image.name) + 0x\(String(value - image.base, radix: 16))"
        }
        // ponytail: "within 1 MB of sp" stands in for the stack's real bounds,
        // which a report does not carry per thread.
        if let sp = thread.registers.first(where: { $0.name.lowercased() == "sp" })?.value, sp >= addressFloor {
            let distance = value > sp ? value - sp : sp - value
            if distance < 1 << 20 {
                return "stack"
            }
        }
        return nil
    }

    // MARK: Status registers

    /// `N Z C V` as letters, lowercase when clear — the form lldb prints.
    private static func conditionFlags(_ value: UInt64) -> String {
        zip(["n", "z", "c", "v"], [31, 30, 29, 28])
            .map { value >> UInt64($1) & 1 == 1 ? $0.uppercased() : $0 }
            .joined()
    }

    /// `ESR_ELx.EC`, bits 31…26.
    private static func exceptionClass(_ value: UInt64) -> String? {
        switch (value >> 26) & 0x3F {
        case 0x15: "Supervisor call"
        case 0x20, 0x21: "Instruction abort"
        case 0x22: "PC alignment fault"
        case 0x24, 0x25: "Data abort"
        case 0x26: "SP alignment fault"
        case 0x2C: "Floating-point exception"
        case 0x1C: "Pointer authentication failure"
        case 0x3C: "Breakpoint (brk)"
        case 0x00 where value == 0: nil
        case 0x00: "Unknown reason"
        default: nil
        }
    }
}

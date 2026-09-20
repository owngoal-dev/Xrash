import XCTest
@testable import XrashReport

final class RegisterNotesTests: XCTestCase {
    private var thread: ReportThread {
        var thread = ReportThread(index: 0)
        var frame = Frame(imageIndex: 0, imageOffset: 0x3CD4, address: 0x2_3A9B_3CD4)
        frame.symbol = "mach_msg2_trap"
        frame.symbolLocation = 8
        thread.frames = [frame]
        thread.registers = [Register(name: "sp", value: 0x1_6B84_7000)]
        return thread
    }

    private var crash: CrashReport {
        var crash = CrashReport()
        crash.images = [BinaryImage(
            name: "libsystem_kernel.dylib",
            path: "/usr/lib/system/libsystem_kernel.dylib",
            uuid: "",
            base: 0x2_3A9B_0000,
            size: 0x40000
        )]
        return crash
    }

    private func note(_ name: String, _ value: UInt64) -> String? {
        RegisterNotes.note(for: Register(name: name, value: value), thread: thread, in: crash)
    }

    func testAddresses() {
        XCTAssertEqual(note("pc", 0x2_3A9B_3CD4), "mach_msg2_trap + 8")
        XCTAssertEqual(note("lr", 0x2_3A9B_730C), "libsystem_kernel.dylib + 0x730c")
        XCTAssertEqual(note("x0", 0x1_6B84_7010), "stack")
        XCTAssertNil(note("x3", 0))
        XCTAssertNil(note("x1", 0x1003))
        XCTAssertNil(note("x5", .max))
    }

    func testStatusRegisters() {
        XCTAssertEqual(note("cpsr", 0x6000_1000), "nZCv")
        XCTAssertEqual(note("esr", 0x5600_0080), "Supervisor call")
        XCTAssertEqual(note("esr", 0x9200_0006), "Data abort")
        XCTAssertEqual(note("esr", 0xF200_0001), "Breakpoint (brk)")
        XCTAssertNil(note("esr", 0))
    }
}

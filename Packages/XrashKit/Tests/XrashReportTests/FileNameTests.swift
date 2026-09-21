import XCTest
@testable import XrashReport

/// The list classifies every row from its name alone. Four reports in five end
/// in `.synced`, so the suffix chain is the part that has to be right.
final class FileNameTests: XCTestCase {
    func testNameTable() {
        let cases: [(String, String, ReportKind, Bool)] = [
            ("Fila-2026-09-08-191717.ips.synced", "Fila", .crash, true),
            ("Analytics-Census-2026-09-15-143550.ips.ca.synced", "Analytics-Census", .analytics, true),
            ("panic-full-2026-09-06-184838.0002.ips.synced", "panic-full", .panic, true),
            ("JetsamEvent-2026-09-10-101010.ips", "JetsamEvent", .jetsam, false),
            ("ExcUserFault_Foo-2026-09-10-101010.ips", "ExcUserFault_Foo", .crash, false),
            ("Foo.cpu_resource-2026-09-10-101010.ips", "Foo", .resource, false),
            ("stacks-2026-09-10-101010.ips", "stacks", .hang, false),
            ("Crasher_2019-01-02-123456_iPhone.crash", "Crasher", .crash, false),
            ("SiriSearchFeedback-2026-09-05-133708.000.ips.synced", "SiriSearchFeedback", .analytics, true),
            ("spotlight_heartbeat_last.log", "spotlight_heartbeat_last", .other, false),
        ]
        for (fileName, process, kind, synced) in cases {
            let parsed = ReportFileName(fileName)
            XCTAssertEqual(parsed.processName, process, fileName)
            XCTAssertEqual(parsed.kind, kind, fileName)
            XCTAssertEqual(parsed.isSynced, synced, fileName)
        }
    }

    /// The stamp is written in the device's local time, so it reads back in
    /// the current zone — not UTC.
    func testStampIsLocalTime() throws {
        let date = try XCTUnwrap(ReportFileName("Fila-2026-09-08-191717.ips").date)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.hour, 19)
        XCTAssertEqual(parts.minute, 17)
        XCTAssertEqual(parts.second, 17)
    }

    func testNameWithoutStampFallsBackToModified() {
        XCTAssertNil(ReportFileName("spotlight_heartbeat_last.log").date)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let row = ReportDecoder.summary(path: "/tmp/spotlight_heartbeat_last.log", byteCount: 12, modified: modified)
        XCTAssertEqual(row.date, modified)
        XCTAssertEqual(row.fileName, "spotlight_heartbeat_last.log")
        XCTAssertEqual(row.id, "/tmp/spotlight_heartbeat_last.log")
        XCTAssertEqual(row.group, .other)
    }

    func testGroupBeforeTheFileIsOpened() {
        XCTAssertEqual(
            ReportDecoder.summary(path: "/a/Fila-2026-09-08-191717.ips", byteCount: 1, modified: .now).group,
            .service
        )
        XCTAssertEqual(
            ReportDecoder.summary(path: "/a/JetsamEvent-2026-09-10-101010.ips", byteCount: 1, modified: .now).group,
            .jetsam
        )
    }
}

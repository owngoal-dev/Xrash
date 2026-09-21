import Foundation
import XCTest
@testable import XrashNotice
import XrashProtocol

final class NoticeDetailTests: XCTestCase {
    /// The report fixtures live with the decoder's tests; one copy is enough.
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("XrashReportTests/Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    func testACrashSaysWhatTheListRowSays() throws {
        let name = "Fila-2026-09-08-191717.ips"
        let detail = try XCTUnwrap(NoticeDetail(report: fixture(name), fileName: name))
        XCTAssertEqual(detail.processName, "Fila")
        let line = try XCTUnwrap(detail.line)
        XCTAssertTrue(line.hasPrefix("EXC_"), line)
        XCTAssertTrue(line.contains(" · "), line)
    }

    func testWhatIsNotAReportSaysNothing() {
        XCTAssertNil(NoticeDetail(report: Data([0xFF, 0xFE, 0x00]), fileName: "junk-2026-09-08-191717.ips")?.line)
    }

    func testTheAnswerIsClampedToOneShortLinePerField() throws {
        let name = "Fila-2026-09-08-191717.ips"
        var detail = try XCTUnwrap(NoticeDetail(report: fixture(name), fileName: name))
        detail.reason = String(repeating: "A", count: 5000) + "\nsecond line"
        detail.processName = "Fila\nnot this"
        let clamped = detail.clamped
        XCTAssertEqual(clamped.processName, "Fila")
        XCTAssertEqual(clamped.reason?.count, 120)
        XCTAssertLessThanOrEqual(try XrashWire.encode(clamped).count, NoticeDetail.maximumEncodedByteCount)
    }
}

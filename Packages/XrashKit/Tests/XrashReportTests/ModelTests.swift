import XCTest
@testable import XrashReport

final class ModelTests: XCTestCase {
    func testFaultingThreadIsBoundsChecked() {
        var crash = CrashReport()
        crash.faultingThreadIndex = 3
        XCTAssertNil(crash.faultingThread)
        crash.threads = (0 ..< 4).map(ReportThread.init(index:))
        XCTAssertEqual(crash.faultingThread?.index, 3)
    }
}

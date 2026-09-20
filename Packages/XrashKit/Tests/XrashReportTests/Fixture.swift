import Foundation
import XCTest

/// Scrubbed reports pulled off a vphone, plus two hand-written ones. Copied
/// into the test bundle as a folder, so they keep the names the decoder
/// classifies from.
enum Fixture {
    static let fila = "Fila-2026-09-08-191717.ips"
    static let sudo = "sudo-2026-09-07-201248.ips.synced"
    static let panic = "panic-full-2026-09-06-184838.0002.ips.synced"
    static let siri = "SiriSearchFeedback-2026-09-04-032224.ips.synced"
    static let census = "Analytics-Census-2026-09-15-143550.ips.ca.synced"
    static let jetsam = "JetsamEvent-2026-09-10-101010.ips"
    static let legacy = "Crasher_2019-01-02-123456_iPhone.crash"

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let root = try XCTUnwrap(Bundle.module.resourceURL, "no resource bundle", file: file, line: line)
        return try Data(contentsOf: root.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }
}

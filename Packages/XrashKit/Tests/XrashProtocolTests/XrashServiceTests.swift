import Foundation
import XCTest
@testable import XrashProtocol

/// The names in Swift and the names in the packaging inputs are two copies of
/// one fact. A rename that reaches only one side builds cleanly and then the
/// daemon refuses the app at runtime.
final class XrashServiceTests: XCTestCase {
    private var packaging: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // XrashProtocolTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // XrashKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Packaging")
    }

    private func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: packaging.appendingPathComponent(name))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testAppEntitlementsNameTheService() throws {
        let entitlements = try plist("Xrash.entitlements")
        XCTAssertEqual(entitlements[XrashService.clientEntitlement] as? Bool, true)
        let lookups = entitlements["com.apple.security.exception.mach-lookup.global-name"] as? [String]
        XCTAssertEqual(lookups, [XrashService.machServiceName])
    }

    func testLaunchDaemonIsOnDemandAndNamesTheService() throws {
        let job = try plist("wiki.qaq.xrashd.plist")
        let services = try XCTUnwrap(job["MachServices"] as? [String: Any])
        XCTAssertEqual(Array(services.keys), [XrashService.machServiceName])
        let arguments = try XCTUnwrap(job["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments, ["@PREFIX@" + XrashService.daemonPathSuffix])
        XCTAssertNil(job["KeepAlive"])
        XCTAssertNil(job["RunAtLoad"])
    }
}

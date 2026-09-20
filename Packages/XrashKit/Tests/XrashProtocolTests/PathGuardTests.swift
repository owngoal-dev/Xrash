import Foundation
import XCTest
@testable import XrashProtocol

final class PathGuardTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xrash-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("CrashReporter/Retired"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("CrashReporterEvil"),
            withIntermediateDirectories: true
        )
        root = try XCTUnwrap(PathGuard.canonical(directory.path))
        for name in ["CrashReporter/a.ips", "CrashReporter/Retired/b.ips.synced", "CrashReporterEvil/c.ips", "secret"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: "\(root!)/\(name)", contents: Data("{}".utf8)))
        }
        try FileManager.default.createSymbolicLink(
            atPath: "\(root!)/CrashReporter/escape.ips",
            withDestinationPath: "\(root!)/secret"
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    func testRefusesEverythingOutsideTheRoot() {
        let roots = ["\(root!)/CrashReporter"]
        XCTAssertNotNil(PathGuard.regularFile("\(root!)/CrashReporter/a.ips", below: roots))
        XCTAssertNotNil(PathGuard.regularFile("\(root!)/CrashReporter/Retired/../a.ips", below: roots))
        // A sibling whose name merely starts with the root's.
        XCTAssertNil(PathGuard.regularFile("\(root!)/CrashReporterEvil/c.ips", below: roots))
        XCTAssertNil(PathGuard.regularFile("\(root!)/CrashReporter/../secret", below: roots))
        XCTAssertNil(PathGuard.regularFile("\(root!)/CrashReporter/escape.ips", below: roots))
        XCTAssertNil(PathGuard.regularFile("\(root!)/CrashReporter/a.ips\0/../../secret", below: roots))
        XCTAssertNil(PathGuard.regularFile("\(root!)/CrashReporter", below: roots))
        XCTAssertNil(PathGuard.regularFile("CrashReporter/a.ips", below: roots))
    }

    func testScannerFindsSyncedReportsInSubdirectoriesAndSkipsSymlinks() {
        let names = ReportScanner(roots: ["\(root!)/CrashReporter"]).scan()
            .map { ($0.path as NSString).lastPathComponent }
            .sorted()
        XCTAssertEqual(names, ["a.ips", "b.ips.synced"])
    }

    /// The directories above `CrashReporter` belong to `mobile`, so a root can
    /// be pointed somewhere else by whoever the daemon is opening files for.
    func testARootPointedAtAnotherTreeIsDropped() throws {
        try FileManager.default.createSymbolicLink(
            atPath: "\(root!)/Redirected",
            withDestinationPath: "\(root!)/CrashReporterEvil"
        )
        XCTAssertNil(ReportRoots.canonicalRoot("\(root!)/Redirected"))
        XCTAssertEqual(ReportRoots.canonicalRoot("\(root!)/CrashReporter"), "\(root!)/CrashReporter")
    }

    /// `openImage` takes a path out of a crash report rather than one the
    /// daemon listed itself; the allow-list is what keeps it from being a
    /// read-anything-as-root call.
    func testImageRootsAdmitTheSystemAndTheBootstrapAndNothingElse() throws {
        let installRoot = try XCTUnwrap(root)
        let roots = ImageRoots.current(installRoot: installRoot)
        func admits(_ path: String) -> Bool {
            roots.contains { PathGuard.isInside(path, root: $0) }
        }
        XCTAssertTrue(admits("/usr/lib/libobjc.A.dylib"))
        XCTAssertTrue(admits("/System/Library/Frameworks/Foundation.framework/Foundation"))
        XCTAssertTrue(admits("\(installRoot)/usr/lib/libsubstrate.dylib"))
        XCTAssertFalse(admits("/private/etc/master.passwd"))
        XCTAssertFalse(admits("/private/var/mobile/Library/Preferences/com.apple.mobilephone.plist"))
        XCTAssertFalse(admits("/private/var/db/timezone"))
        XCTAssertFalse(admits(installRoot), "the root itself is not a file below it")
    }

    func testPayloadRoundTrip() throws {
        let entry = ReportEntry(path: "/x/a.ips", byteCount: 2, modified: Date(timeIntervalSince1970: 1), ownerUserID: 0)
        XCTAssertEqual(try XrashWire.decode([ReportEntry].self, from: XrashWire.encode([entry])), [entry])
    }
}

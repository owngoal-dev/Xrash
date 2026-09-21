import XCTest
import XrashBlame
@testable import XrashSystemState

/// The collector as the Mac sees it: `IcliSystem` is an iOS-only product, so
/// every device collector fails here and the dpkg one still does not. That is
/// the rule being tested — one collector's failure costs only its own file.
final class SystemStateTests: XCTestCase {
    private var root: URL!
    private var output: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xrash-system-\(UUID().uuidString)")
        output = root.appendingPathComponent("collected", isDirectory: true)

        let info = root.appendingPathComponent("var/lib/dpkg/info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try write(
            "/usr/lib/relative.dylib\n/Library/MobileSubstrate/DynamicLibraries/Relative.dylib\n",
            to: info.appendingPathComponent("com.example.relative.list")
        )
        try write("/var/jb/usr/lib/prefixed.dylib\n", to: info.appendingPathComponent("com.example.prefixed.list"))
        try write(
            """
            Package: com.example.relative
            Name: Relative Tweak
            Version: 1.2.3
            Maintainer: Jane <jane@example.com>
            Status: install ok installed

            Package: com.example.prefixed
            Name: Prefixed Tweak
            Version: 0.9

            """,
            to: root.appendingPathComponent("var/lib/dpkg/status")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// Identifier order, and every field the status file and the list gave.
    func testPackagesComeOutOfTheDpkgTree() throws {
        let object = try SystemState.packages(DpkgDatabase(installRoot: root.path))
        let rows = try XCTUnwrap(object["packages"] as? [[String: Any]])
        XCTAssertEqual(object["count"] as? Int, 2)
        XCTAssertEqual(rows.map { $0["identifier"] as? String }, ["com.example.prefixed", "com.example.relative"])

        let relative = try XCTUnwrap(rows.last)
        XCTAssertEqual(relative["name"] as? String, "Relative Tweak")
        XCTAssertEqual(relative["version"] as? String, "1.2.3")
        XCTAssertEqual(relative["maintainer"] as? String, "Jane <jane@example.com>")
        XCTAssertNotNil(relative["installed"] as? String, "a file list's date is the install date")

        // A package the status file never described is still installed.
        let prefixed = try XCTUnwrap(rows.first)
        XCTAssertEqual(prefixed["version"] as? String, "0.9")
        XCTAssertNil(prefixed["maintainer"])
    }

    /// Sorted keys and indentation, so two collections of one device diff.
    func testJSONIsSortedAndIndented() throws {
        let text = try String(decoding: SystemState.serialise(["b": 1, "a": 2]), as: UTF8.self)
        XCTAssertEqual(text, "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
    }

    /// No install root is not an exception the caller has to handle; it is a
    /// sentence in `packages.json`.
    func testAFailedCollectorWritesItsReasonAndNothingElseIsLost() throws {
        let files = SystemState.collect(into: output, packages: DpkgDatabase(installRoot: root.path))
        XCTAssertEqual(
            files.map(\.name),
            [
                "device.json", "launchd-services.json", "launchd-disabled.json", "launchd-environment.json",
                "apps.json", "packages.json", "tweaks.json", "processes.json",
                "jetsam.json", "jetsam-properties.json",
            ]
        )
        for file in files {
            XCTAssertEqual(file.url, output.appendingPathComponent(file.name))
            XCTAssertEqual(file.byteCount, UInt64(try Data(contentsOf: file.url).count))
            XCTAssertGreaterThan(file.byteCount, 0)
        }

        // The one collector that does not need a device answered in full.
        let packages = try object(in: files, named: "packages.json")
        XCTAssertNil(packages["error"])
        XCTAssertEqual(packages["count"] as? Int, 2)

        // The nine that do said so, each in its own file.
        for name in files.map(\.name) where name != "packages.json" {
            let failed = try object(in: files, named: name)
            XCTAssertEqual(failed.keys.sorted(), ["error"], name)
            XCTAssertFalse((failed["error"] as? String ?? "").isEmpty, name)
        }
    }

    func testTheReasonForAFailureIsTheWordsAndNotACode() {
        let reason = SystemState.reason(of: SystemStateFailure(reason: "launchd would not answer"))
        XCTAssertEqual(reason, "launchd would not answer")
        let written = try? JSONSerialization.jsonObject(
            with: SystemState.failure(SystemStateFailure(reason: "no"))
        ) as? [String: Any]
        XCTAssertEqual(written?["error"] as? String, "no")
    }

    /// Nothing is collected on a Mac or in the simulator, and the interface
    /// asks this one question rather than branching per platform.
    func testCollectionIsUnavailableOffADevice() {
        #if canImport(IcliSystem) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
            XCTAssertTrue(SystemState.isAvailable)
        #else
            XCTAssertFalse(SystemState.isAvailable)
        #endif
    }

    private func object(in files: [SystemStateFile], named name: String) throws -> [String: Any] {
        let file = try XCTUnwrap(files.first { $0.name == name }, name)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: file.url)) as? [String: Any])
    }
}

import XCTest
@testable import XrashBlame

/// A dpkg tree in a temporary directory, in both spellings that real bootstraps
/// write: prefix-relative (roothide, rootful) and `/var/jb`-prefixed (rootless).
final class DpkgDatabaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xrash-dpkg-\(UUID().uuidString)")
        let info = root.appendingPathComponent("var/lib/dpkg/info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)

        try write(
            "/usr/lib/relative.dylib\n/Library/MobileSubstrate/DynamicLibraries/Relative.dylib\n",
            to: info.appendingPathComponent("com.example.relative.list"),
        )
        try write("/var/jb/usr/lib/prefixed.dylib\n", to: info.appendingPathComponent("com.example.prefixed.list"))
        try write("/var/mobile/Documents/thing\n", to: info.appendingPathComponent("com.example.private.list"))
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
            to: root.appendingPathComponent("var/lib/dpkg/status"),
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func testPrefixRelativeListMatchesACanonicalPath() {
        let database = DpkgDatabase(installRoot: root.path)
        let owner = database.owner(ofPath: root.appendingPathComponent("usr/lib/relative.dylib").path)
        XCTAssertEqual(owner?.identifier, "com.example.relative")
        XCTAssertEqual(owner?.name, "Relative Tweak")
        XCTAssertEqual(owner?.version, "1.2.3")
        XCTAssertNotNil(owner?.installed)
    }

    func testVarJBListMatchesACanonicalPath() {
        let database = DpkgDatabase(installRoot: root.path)
        let owner = database.owner(ofPath: root.appendingPathComponent("usr/lib/prefixed.dylib").path)
        XCTAssertEqual(owner?.identifier, "com.example.prefixed")
        XCTAssertEqual(owner?.version, "0.9")
    }

    /// `realpath(3)` turns `/var` into `/private/var` before anything is asked.
    func testPrivatePrefixIsStripped() {
        let database = DpkgDatabase(installRoot: root.path)
        XCTAssertEqual(
            database.owner(ofPath: "/private/var/mobile/Documents/thing")?.identifier,
            "com.example.private",
        )
    }

    /// A report spells an image path the way dyld loaded it, which on rootless
    /// is through the `/var/jb` symlink — not the way `realpath(3)` would.
    func testAVarJBPathMatchesAPrefixRelativeList() {
        let database = DpkgDatabase(installRoot: root.path)
        XCTAssertEqual(
            database.owner(ofPath: "/var/jb/usr/lib/relative.dylib")?.identifier,
            "com.example.relative",
        )
        XCTAssertEqual(
            database.owner(ofPath: "/var/jb/Library/MobileSubstrate/DynamicLibraries/Relative.dylib")?.identifier,
            "com.example.relative",
        )
    }

    func testAListedPathIsMatchedAsWritten() {
        let database = DpkgDatabase(installRoot: root.path)
        XCTAssertEqual(database.owner(ofPath: "/usr/lib/relative.dylib")?.identifier, "com.example.relative")
    }

    /// The field as the status file spells it, display name and all; a package
    /// that does not name one has nobody to write to.
    func testMaintainerIsReadAsWritten() {
        let database = DpkgDatabase(installRoot: root.path)
        XCTAssertEqual(
            database.owner(ofPath: "/usr/lib/relative.dylib")?.maintainer,
            "Jane <jane@example.com>",
        )
        XCTAssertNil(database.owner(ofPath: "/var/jb/usr/lib/prefixed.dylib")?.maintainer)
    }

    /// What a mail goes to. A status file is untrusted input, so anything that
    /// would smuggle in a second recipient is no address at all.
    func testMaintainerAddressIsParsedAndChecked() {
        XCTAssertEqual(address(of: "Jane <jane@example.com>"), "jane@example.com")
        XCTAssertEqual(address(of: "Jane <old@example.com> (now <new@example.com>)"), "new@example.com")
        XCTAssertEqual(address(of: "  jane@example.com \n"), "jane@example.com")
        XCTAssertNil(address(of: "Jane Doe"))
        XCTAssertNil(address(of: "Jane <jane at example.com>"))
        XCTAssertNil(address(of: "jane@example.com, bob@example.com"))
        XCTAssertNil(address(of: "jane@example.com\nBcc: bob@example.com"))
        XCTAssertNil(PackageOwner(identifier: "com.example.relative").maintainerAddress)
    }

    private func address(of maintainer: String) -> String? {
        var owner = PackageOwner(identifier: "com.example.relative")
        owner.maintainer = maintainer
        return owner.maintainerAddress
    }

    func testUnknownPathHasNoOwner() {
        let database = DpkgDatabase(installRoot: root.path)
        XCTAssertNil(database.owner(ofPath: "/usr/lib/nobody.dylib"))
    }

    /// No backend means no install root, and that is not an error anywhere.
    func testNoRootAndNoDatabaseFindNothing() {
        XCTAssertNil(DpkgDatabase(installRoot: nil).owner(ofPath: "/usr/lib/relative.dylib"))
        XCTAssertNil(
            DpkgDatabase(installRoot: "/var/empty/not-a-bootstrap").owner(ofPath: "/usr/lib/relative.dylib"),
        )
    }

    func testTrailingSlashOnTheRootIsIgnored() {
        let database = DpkgDatabase(installRoot: root.path + "/")
        XCTAssertEqual(
            database.owner(ofPath: root.appendingPathComponent("usr/lib/relative.dylib").path)?.identifier,
            "com.example.relative",
        )
    }
}

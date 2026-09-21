import LibArchive
import XCTest
@testable import XrashBundle
import XrashReport

/// The archive, from both ends: what Xrash writes, and what someone else's zip
/// is allowed to do when Xrash opens it.
final class BundleArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xrash-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testManifestRoundTripsThroughAnXMLPlist() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(manifest())
        XCTAssertTrue(String(decoding: data.prefix(64), as: UTF8.self).hasPrefix("<?xml"))
        XCTAssertEqual(try PropertyListDecoder().decode(BundleManifest.self, from: data), manifest())
    }

    /// `systemFiles` is optional so that a bundle written before it existed
    /// still decodes, and one written with it comes back with the field.
    func testAManifestWithoutSystemFilesStillDecodes() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        let old = try encoder.encode(manifest())
        XCTAssertFalse(
            String(decoding: old, as: UTF8.self).contains("systemFiles"),
            "nil must not be written at all, or an old reader would meet a key it has no type for"
        )
        XCTAssertNil(try PropertyListDecoder().decode(BundleManifest.self, from: old).systemFiles)

        var withState = manifest()
        withState.systemFiles = [
            BundleManifest.SystemFile(
                name: "launchd-services.json",
                archivePath: BundleLayout.systemFile(name: "launchd-services.json"),
                byteCount: 2_915_842
            ),
        ]
        let decoded = try PropertyListDecoder().decode(
            BundleManifest.self,
            from: encoder.encode(withState)
        )
        XCTAssertEqual(decoded, withState)
        XCTAssertEqual(decoded.systemFiles?.first?.archivePath, "system/launchd-services.json")
    }

    /// The archive stores a collected file exactly where the manifest says it
    /// is, because that path is all a reader has to go on.
    func testSystemFilesLandWhereTheManifestSaysTheyAre() throws {
        let source = directory.appendingPathComponent("device.json")
        let contents = Data(#"{"model": "iPhone14,2"}"#.utf8)
        try contents.write(to: source)

        let archivePath = BundleLayout.systemFile(name: "device.json")
        var manifest = manifest()
        manifest.systemFiles = [
            BundleManifest.SystemFile(
                name: "device.json",
                archivePath: archivePath,
                byteCount: UInt64(contents.count)
            ),
        ]
        let destination = directory.appendingPathComponent("System.xrashreport")
        try BundleArchive.write(
            manifest,
            files: [BundleFile(source: source, archivePath: archivePath)],
            to: destination
        )

        let unpacked = directory.appendingPathComponent("unpacked-system")
        let read = try BundleArchive.read(destination, extractingInto: unpacked)
        let declared = try XCTUnwrap(read.systemFiles?.first)
        XCTAssertEqual(
            try Data(contentsOf: unpacked.appendingPathComponent(declared.archivePath)),
            contents
        )
        XCTAssertEqual(try headers(of: destination).map(\.name), [BundleLayout.manifest, archivePath])
    }

    func testWriteAndReadRoundTripALargeFile() throws {
        let payload = Data((0 ..< (5 << 20)).map { _ in UInt8.random(in: .min ... .max) })
        let source = directory.appendingPathComponent("Fila")
        try payload.write(to: source)

        let archivePath = BundleLayout.binary(uuid: "0000-UUID", name: "Fila")
        let destination = directory.appendingPathComponent("Report.xrashreport")
        let log = ProgressLog()
        try BundleArchive.write(
            manifest(),
            files: [BundleFile(source: source, archivePath: archivePath)],
            to: destination,
            progress: { log.append($0) }
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial"))
        let fractions = log.values
        XCTAssertGreaterThan(fractions.count, 2, "a 5 MB file should report progress more than once")
        XCTAssertEqual(zip(fractions, fractions.dropFirst()).filter { $0 > $1 }.count, 0, "progress went backwards")
        XCTAssertEqual(fractions.last, 1)

        let unpacked = directory.appendingPathComponent("unpacked")
        XCTAssertEqual(try BundleArchive.read(destination, extractingInto: unpacked), manifest())
        XCTAssertEqual(
            try Data(contentsOf: unpacked.appendingPathComponent(archivePath)),
            payload,
            "the archived binary came back different"
        )

        // The manifest comes first so a reader knows what it has before the
        // central directory, and the member keeps the date it had on disk.
        let listing = try headers(of: destination)
        XCTAssertEqual(listing.map(\.name), [BundleLayout.manifest, archivePath])
        let modified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(listing.last?.modified, time_t(modified.timeIntervalSince1970))
    }

    func testAnEntryThatClimbsOutOfTheDirectoryIsRefused() throws {
        let archive = directory.appendingPathComponent("escape.zip")
        try craft(archive, entries: [Entry(name: "../escaped.txt", contents: Data("no".utf8))])

        let into = directory.appendingPathComponent("into")
        XCTAssertThrowsError(try BundleArchive.extractZip(archive, into: into)) { error in
            XCTAssertEqual(error as? BundleArchiveError, .unsafeEntryPath("../escaped.txt"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped.txt").path))
    }

    func testAnAbsoluteEntryIsRefused() throws {
        let archive = directory.appendingPathComponent("absolute.zip")
        let target = directory.appendingPathComponent("absolute-target.txt")
        try craft(archive, entries: [Entry(name: target.path, contents: Data("no".utf8))])

        let into = directory.appendingPathComponent("into")
        XCTAssertThrowsError(try BundleArchive.extractZip(archive, into: into))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// A bundle has no use for a link, and every link is a way out. (A zip
    /// cannot express a hard link at all; the reader still refuses one.)
    func testALinkEntryIsSkipped() throws {
        let archive = directory.appendingPathComponent("link.zip")
        try craft(archive, entries: [
            Entry(name: "keep.txt", contents: Data("yes".utf8)),
            Entry(name: "escape", filetype: S_IFLNK, symlink: "/etc/passwd"),
        ])

        let into = directory.appendingPathComponent("into")
        try BundleArchive.extractZip(archive, into: into)
        XCTAssertEqual(try Data(contentsOf: into.appendingPathComponent("keep.txt")), Data("yes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: into.appendingPathComponent("escape").path))
    }

    func testANewerSchemaIsNamedRatherThanCalledDamaged() throws {
        var newer = manifest()
        newer.schemaVersion = BundleManifest.currentSchemaVersion + 7
        let destination = directory.appendingPathComponent("Newer.xrashreport")
        try BundleArchive.write(newer, files: [], to: destination)

        XCTAssertThrowsError(
            try BundleArchive.read(destination, extractingInto: directory.appendingPathComponent("newer"))
        ) { error in
            XCTAssertEqual(
                error as? BundleArchiveError,
                .unsupportedSchema(BundleManifest.currentSchemaVersion + 7)
            )
        }
    }

    func testAZipWithoutAManifestIsNotABundle() throws {
        let archive = directory.appendingPathComponent("plain.zip")
        try craft(archive, entries: [Entry(name: "notes.txt", contents: Data("hello".utf8))])

        XCTAssertThrowsError(
            try BundleArchive.read(archive, extractingInto: directory.appendingPathComponent("plain"))
        ) { error in
            XCTAssertEqual(error as? BundleArchiveError, .missingManifest)
        }
    }

    func testThePartialFileIsRemovedWhenTheWriteFails() throws {
        let destination = directory.appendingPathComponent("Doomed.xrashreport")
        let missing = BundleFile(
            source: directory.appendingPathComponent("was-never-there"),
            archivePath: BundleLayout.crashText(member: "M1")
        )
        XCTAssertThrowsError(try BundleArchive.write(manifest(), files: [missing], to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial"))

        // Unreadable only once the archive is already open, so this is the case
        // that leaves a half-written `.partial` behind if nothing removes it.
        let unreadable = directory.appendingPathComponent("unreadable.crash")
        try Data("thread 0".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        XCTAssertThrowsError(
            try BundleArchive.write(
                manifest(),
                files: [BundleFile(source: unreadable, archivePath: BundleLayout.crashText(member: "M1"))],
                to: destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAnArchivePathTheBundleCannotCarryIsRefused() throws {
        let source = directory.appendingPathComponent("member.crash")
        try Data("thread 0".utf8).write(to: source)
        let destination = directory.appendingPathComponent("Refused.xrashreport")

        for path in ["/etc/passwd", "../escaped", ""] {
            XCTAssertThrowsError(
                try BundleArchive.write(
                    manifest(),
                    files: [BundleFile(source: source, archivePath: path)],
                    to: destination
                ),
                path
            )
        }
        let duplicated = BundleFile(source: source, archivePath: BundleLayout.crashText(member: "M1"))
        XCTAssertThrowsError(try BundleArchive.write(manifest(), files: [duplicated, duplicated], to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Fixtures

    /// Integral seconds: an XML plist stores a date to the second, and the
    /// round trip is asserted by equality.
    private func manifest() -> BundleManifest {
        var summary = ReportSummary(
            id: "/var/mobile/Library/Logs/CrashReporter/Fila-2026-09-08-191717.ips",
            fileName: "Fila-2026-09-08-191717.ips",
            processName: "Fila",
            kind: .crash,
            group: .app,
            date: Date(timeIntervalSince1970: 1_757_355_437),
            byteCount: 40960,
            isSynced: false
        )
        summary.bundleID = "wiki.qaq.fila"
        summary.incidentID = "00000000-0000-0000-0000-000000000001"

        var report = Report(header: ReportHeader(bugType: "309"), kind: .crash, rawText: "{\"bug_type\":\"309\"}")
        report.crash = CrashReport()
        let member = BundleManifest.Member(id: "M1", summary: summary, relation: nil, report: report)

        var manifest = BundleManifest(
            id: "00000000-0000-0000-0000-0000000000AA",
            created: Date(timeIntervalSince1970: 1_757_355_500),
            title: "Fila crashed on launch",
            notes: "Happens every time after installing the tweak.",
            generator: "Xrash 0.1.0 (1)",
            primary: member
        )
        manifest.deviceModel = "iPhone14,2"
        manifest.osVersion = "iPhone OS 26.6.1 (23G83)"
        return manifest
    }

    private struct Entry {
        var name: String
        var filetype: mode_t = S_IFREG
        var contents = Data()
        var symlink: String?
        var hardlink: String?
    }

    /// Entry names and dates in the order the archive stores them.
    private func headers(of url: URL) throws -> [(name: String, modified: time_t)] {
        let handle = try XCTUnwrap(archive_read_new())
        defer { archive_read_free(handle) }
        XCTAssertEqual(archive_read_support_format_zip(handle), ARCHIVE_OK)
        XCTAssertEqual(archive_read_open_filename(handle, url.path, 64 * 1024), ARCHIVE_OK)

        var listing = [(name: String, modified: time_t)]()
        var entry: OpaquePointer?
        while archive_read_next_header(handle, &entry) == ARCHIVE_OK, let entry {
            let name = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            listing.append((name.map { String(cString: $0) } ?? "", archive_entry_mtime(entry)))
        }
        return listing
    }

    /// Zips crafted here rather than committed: the interesting ones are zips
    /// no archiver would write on purpose.
    private func craft(_ url: URL, entries: [Entry]) throws {
        let handle = try XCTUnwrap(archive_write_new())
        XCTAssertEqual(archive_write_set_format_zip(handle), ARCHIVE_OK)
        XCTAssertEqual(archive_write_set_options(handle, "zip:compression=store"), ARCHIVE_OK)
        XCTAssertEqual(archive_write_open_filename(handle, url.path), ARCHIVE_OK)
        for entry in entries {
            let item = try XCTUnwrap(archive_entry_new())
            archive_entry_set_pathname(item, entry.name)
            archive_entry_set_filetype(item, UInt32(entry.filetype))
            archive_entry_set_perm(item, entry.filetype == S_IFLNK ? 0o777 : 0o644)
            archive_entry_set_size(item, Int64(entry.contents.count))
            entry.symlink.map { archive_entry_set_symlink(item, $0) }
            entry.hardlink.map { archive_entry_set_hardlink(item, $0) }
            XCTAssertEqual(archive_write_header(handle, item), ARCHIVE_OK, entry.name)
            entry.contents.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, !raw.isEmpty else { return }
                XCTAssertEqual(archive_write_data(handle, base, raw.count), raw.count)
            }
            XCTAssertEqual(archive_write_finish_entry(handle), ARCHIVE_OK)
            archive_entry_free(item)
        }
        XCTAssertEqual(archive_write_close(handle), ARCHIVE_OK)
        archive_write_free(handle)
    }
}

/// The progress handler is `@Sendable`, so what it appends to needs a lock even
/// though this test calls it from one thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions = [Double]()

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return fractions
    }

    func append(_ fraction: Double) {
        lock.lock()
        fractions.append(fraction)
        lock.unlock()
    }
}

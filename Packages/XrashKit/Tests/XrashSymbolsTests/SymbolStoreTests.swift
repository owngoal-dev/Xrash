import XCTest
@testable import XrashSymbols

final class DSYMStoreTests: XCTestCase {
    func testImportsADSYMBundle() throws {
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertEqual(store.records.count, 0)

        let imported = try store.importDSYM(at: Fixture.dsymBundle)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.id, Fixture.uuid.uuidString)
        XCTAssertEqual(imported.first?.arch, "arm64")
        XCTAssertEqual(imported.first?.binaryName, "fixture.dylib")
        XCTAssertGreaterThan(imported.first?.byteCount ?? 0, 0)

        let url = try XCTUnwrap(store.url(forUUID: Fixture.uuid.uuidString))
        XCTAssertEqual(try Data(contentsOf: url), try Fixture.data(of: Fixture.dsymBinary))
        // Matching is case-insensitive because reports and dwarfdump disagree.
        XCTAssertNotNil(store.url(forUUID: Fixture.uuid.uuidString.lowercased()))
    }

    func testImportsABareMachOAndAFolderOfThem() throws {
        let bare = DSYMStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertEqual(try bare.importDSYM(at: Fixture.dsymBinary).count, 1)

        // The folder holds the dSYM and the stripped dylib it came from, which
        // share a UUID. The one with DWARF has to win whatever order they list in.
        let folder = DSYMStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertEqual(try folder.importDSYM(at: Fixture.directory).count, 1)
        let stored = try XCTUnwrap(folder.url(forUUID: Fixture.uuid.uuidString))
        let slice = try XCTUnwrap(MachOSlice.slice(of: Data(contentsOf: stored), uuid: Fixture.uuid))
        XCTAssertNotNil(slice.section(segment: "__DWARF", name: "__debug_line"))
    }

    /// A release's unpacked `*_dSYMs.zip`, when there is one to hand:
    /// `XRASH_DSYM_DIR=<folder> swift test`.
    func testImportsAnUnpackedReleaseArchiveWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["XRASH_DSYM_DIR"] else { throw XCTSkip("opt-in") }
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        let imported = try store.importDSYM(at: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(imported.count, 1)
    }

    func testRefusesAPathWithNoSymbols() throws {
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        let empty = Fixture.temporaryDirectory(self)
        XCTAssertThrowsError(try store.importDSYM(at: empty)) {
            XCTAssertEqual($0 as? SymbolStoreFailure, .noDebugSymbols)
        }
        XCTAssertEqual(store.revision, 0)
    }

    func testRevisionAndRecordsSurviveARestart() throws {
        let directory = Fixture.temporaryDirectory(self)
        let store = DSYMStore(directory: directory)
        _ = try store.importDSYM(at: Fixture.dsymBundle)
        XCTAssertEqual(store.revision, 1)

        let reopened = DSYMStore(directory: directory)
        XCTAssertEqual(reopened.revision, 1)
        XCTAssertEqual(reopened.records.map(\.id), [Fixture.uuid.uuidString])

        try reopened.remove(uuid: Fixture.uuid.uuidString)
        XCTAssertEqual(reopened.revision, 2)
        XCTAssertNil(reopened.url(forUUID: Fixture.uuid.uuidString))
        XCTAssertEqual(DSYMStore(directory: directory).records.count, 0)
    }

    func testReimportingReplacesTheRecordRatherThanDoublingIt() throws {
        let store = DSYMStore(directory: Fixture.temporaryDirectory(self))
        _ = try store.importDSYM(at: Fixture.dsymBundle)
        _ = try store.importDSYM(at: Fixture.dsymBundle)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.revision, 2)
    }
}

final class SystemSymbolStoreTests: XCTestCase {
    /// What crashed the app on every extraction: a cache holds an `n_value`
    /// above `Int.max`, and the library's iterator casts it to `Int`.
    func testReadsSymbolEntriesWithoutTrustingThem() {
        func nlist(_ strx: UInt32, _ type: UInt8, _ value: UInt64) -> Data {
            var data = Data()
            withUnsafeBytes(of: strx.littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: [type, 1, 0, 0])
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            return data
        }
        let entries = nlist(1, 0x0F, 0x1000) // defined, external
            + nlist(1, 0x0E, .max) // defined, and no `Int` holds it
            + nlist(1, 0x64, 0x2000) // a stab
            + nlist(1, 0x01, 0) // undefined
            + Data([1, 2, 3]) // a torn tail
        let found = SystemSymbolStore.definedSymbols(in: entries)
        XCTAssertEqual(found.map(\.address), [0x1000, .max])

        let pool = Data("\0_main\0tail".utf8)
        XCTAssertEqual(SystemSymbolStore.cString(in: pool, at: 1), "_main")
        XCTAssertEqual(SystemSymbolStore.cString(in: pool, at: 7), "", "no terminator inside the pool")
        XCTAssertEqual(SystemSymbolStore.cString(in: pool, at: 400), "")
        // A slice keeps its parent's indices; the offset is still from its start.
        XCTAssertEqual(SystemSymbolStore.cString(in: pool.dropFirst(1), at: 0), "_main")
    }

    /// The whole cache, which is where the entries that trap actually are.
    /// Minutes, so only when asked: `XRASH_FULL_CACHE=1 swift test`.
    func testExtractsTheWholeCacheWhenAsked() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["XRASH_FULL_CACHE"] == nil, "opt-in")
        let store = SystemSymbolStore(directory: Fixture.temporaryDirectory(self))
        let set = try await store.extractCurrentSystem(
            openImage: { FileHandle(forReadingAtPath: $0) ?? FileHandle.nullDevice },
            progress: { _, _ in }
        )
        XCTAssertGreaterThan(set.imageCount, 1000)
    }

    /// The real cache, capped to a few images so this takes seconds. The whole
    /// extraction is what the app's button does and is not a unit test.
    func testExtractsTheRunningSystemsCache() async throws {
        try XCTSkipIf(SystemSymbolStore.sharedCacheURL() == nil, "no dyld shared cache on this machine")

        let directory = Fixture.temporaryDirectory(self)
        let store = SystemSymbolStore(directory: directory)
        let reported = Fixture.Recorder<Double>()
        let set = try await store.extractCurrentSystem(
            openImage: { FileHandle(forReadingAtPath: $0) ?? FileHandle.nullDevice },
            maximumImages: 4,
            progress: { fraction, _ in reported.record(fraction) }
        )

        XCTAssertEqual(set.id, SystemSymbolStore.osBuild())
        XCTAssertGreaterThan(set.byteCount, 0)
        XCTAssertEqual(reported.values.count, 4)
        XCTAssertEqual(reported.values.last, 1)
        XCTAssertEqual(store.sets.map(\.id), [set.id])
        XCTAssertEqual(SystemSymbolStore(directory: directory).revision, 1)

        // Every file written is a table that reads back, and one of them can
        // name something — a cache image with no symbols at all would be news.
        let written = try FileManager.default
            .contentsOfDirectory(at: directory.appendingPathComponent(set.id), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "symbols" }
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(set.imageCount, written.count)
        let uuid = written[0].deletingPathExtension().lastPathComponent
        let table = try XCTUnwrap(store.table(build: set.id, uuid: uuid))
        XCTAssertGreaterThan(table.count, 0)

        try store.remove(build: set.id)
        XCTAssertTrue(store.sets.isEmpty)
        XCTAssertNil(store.table(build: set.id, uuid: uuid))
    }

    /// The whole cache is a gigabyte or two of tables; a report names a few
    /// dozen images, and those are all that has to be written.
    func testExtractsOnlyTheImagesAskedFor() async throws {
        try XCTSkipIf(SystemSymbolStore.sharedCacheURL() == nil, "no dyld shared cache on this machine")
        let open: ImageOpener = { FileHandle(forReadingAtPath: $0) ?? FileHandle.nullDevice }

        // The cache is walked in a fixed order, so a UUID from its first images
        // is one the per-image extraction reaches without walking the rest.
        let seedDirectory = Fixture.temporaryDirectory(self)
        let seed = SystemSymbolStore(directory: seedDirectory)
        let seeded = try await seed.extractCurrentSystem(
            openImage: open, maximumImages: 2, progress: { _, _ in }
        )
        let names = try FileManager.default
            .contentsOfDirectory(atPath: seedDirectory.appendingPathComponent(seeded.id).path)
        let uuid = try XCTUnwrap(names
            .compactMap { UUID(uuidString: ($0 as NSString).deletingPathExtension) }
            .first)

        let store = SystemSymbolStore(directory: Fixture.temporaryDirectory(self))
        let set = try await store.extract(images: [uuid], openImage: open, progress: { _, _ in })
        XCTAssertEqual(set.imageCount, 1)
        XCTAssertNotNil(store.table(build: set.id, uuid: uuid.uuidString))

        // Asking again leaves what is there and still reports the whole set.
        let again = try await store.extract(images: [uuid], openImage: open, progress: { _, _ in })
        XCTAssertEqual(again.imageCount, 1)
    }

    func testABuildOrUUIDFromAReportCannotWalkOutOfTheStore() {
        let store = SystemSymbolStore(directory: Fixture.temporaryDirectory(self))
        XCTAssertNil(store.table(build: "../../../etc", uuid: "passwd"))
        XCTAssertNil(store.table(build: "..", uuid: ".."))
        XCTAssertNil(store.table(build: "", uuid: ""))
    }
}

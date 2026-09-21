import Foundation
import MachOKit

/// Why a store could not take in what it was given.
public enum SymbolStoreFailure: Error, Equatable {
    /// Nothing under the path was a Mach-O with a UUID: the wrong folder, an
    /// archive that was never unpacked, a dSYM for another architecture.
    case noDebugSymbols
    /// There is no dyld shared cache where this system keeps one, or it cannot
    /// be read from here.
    case noSharedCache
}

public struct DSYMRecord: Codable, Hashable, Sendable, Identifiable {
    /// The image UUID, uppercase and dashed — what reports are matched on.
    public var id: String
    /// `Fila` for `Fila.app.dSYM/Contents/Resources/DWARF/Fila`.
    public var binaryName: String
    public var arch: String
    public var byteCount: UInt64
    public var imported: Date

    public init(id: String, binaryName: String, arch: String, byteCount: UInt64, imported: Date) {
        self.id = id
        self.binaryName = binaryName
        self.arch = arch
        self.byteCount = byteCount
        self.imported = imported
    }
}

/// Imported dSYMs, copied into `directory` and indexed by UUID.
public final class DSYMStore: @unchecked Sendable {
    private struct Index: Codable {
        var revision = 0
        var records = [DSYMRecord]()
    }

    private let directory: URL
    private let indexURL: URL
    // ponytail: one lock for the whole store. Imports are rare and a lookup is
    // a dictionary hit; per-record locking would buy nothing measurable.
    private let lock = NSLock()
    private var index = Index()

    public init(directory: URL) {
        self.directory = directory
        indexURL = directory.appendingPathComponent("index.plist")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let stored = try? PropertyListDecoder().decode(Index.self, from: data)
        {
            index = stored
        }
    }

    /// Bumped by every import and removal; symbolication caches key on it.
    public var revision: Int {
        lock.locked { index.revision }
    }

    public var records: [DSYMRecord] {
        lock.locked { index.records }
    }

    /// A `.dSYM` bundle, a bare DWARF Mach-O, or a directory holding either.
    /// One record per architecture slice found.
    ///
    /// A zip is unpacked before it gets here: `XrashBundle` owns archives, and
    /// a store that also unpacked would own two ways of being wrong about a
    /// path. Pass the directory it unpacked into.
    public func importDSYM(at url: URL) throws -> [DSYMRecord] {
        var imported = [DSYMRecord]()
        // A folder of dSYMs often holds the stripped binaries beside them, and
        // those carry the same UUID. Whichever the file system lists last would
        // otherwise win and take the line numbers with it.
        var uuidsWithDWARF = Set<String>()
        for candidate in Self.machOFiles(at: url, depth: 4) {
            guard let handle = try? FileHandle(forReadingFrom: candidate),
                  let data = try? Data.mapping(handle),
                  let slices = try? MachOSlice.slices(of: data)
            else { continue }
            for slice in slices {
                guard let uuid = slice.uuid else { continue }
                let debugLine = slice.section(segment: "__DWARF", name: "__debug_line") != nil
                guard debugLine || !uuidsWithDWARF.contains(uuid.uuidString) else { continue }
                if debugLine {
                    uuidsWithDWARF.insert(uuid.uuidString)
                }
                imported.removeAll { $0.id == uuid.uuidString }
                let stored = storedURL(for: uuid.uuidString)
                if slices.count == 1, slice.byteCount == UInt64(data.count) {
                    // The common case: a thin dSYM. Copying the file keeps its
                    // bytes off the heap, which matters for a large app's dSYM.
                    try? FileManager.default.removeItem(at: stored)
                    try FileManager.default.copyItem(at: candidate, to: stored)
                } else {
                    try slice.bytes.write(to: stored, options: .atomic)
                }
                imported.append(DSYMRecord(
                    id: uuid.uuidString,
                    binaryName: candidate.lastPathComponent,
                    arch: slice.arch,
                    byteCount: slice.byteCount,
                    imported: Date()
                ))
            }
        }
        guard !imported.isEmpty else { throw SymbolStoreFailure.noDebugSymbols }

        lock.locked {
            for record in imported {
                index.records.removeAll { $0.id == record.id }
                index.records.append(record)
            }
            index.revision += 1
            save()
        }
        return imported
    }

    public func remove(uuid: String) throws {
        lock.locked {
            guard index.records.contains(where: { $0.id == uuid }) else { return }
            index.records.removeAll { $0.id == uuid }
            index.revision += 1
            save()
            try? FileManager.default.removeItem(at: storedURL(for: uuid))
        }
    }

    /// The stored DWARF file for an image UUID.
    public func url(forUUID uuid: String) -> URL? {
        let uuid = uuid.uppercased()
        return lock.locked {
            guard index.records.contains(where: { $0.id == uuid }) else { return nil }
            let url = storedURL(for: uuid)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func storedURL(for uuid: String) -> URL {
        directory.appendingPathComponent("\(uuid.uppercased()).dwarf")
    }

    private func save() {
        guard let data = try? PropertyListEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Everything under `url` that might be a Mach-O: the file itself, the
    /// `Contents/Resources/DWARF` of a `.dSYM`, or whatever a folder of dSYMs
    /// holds. Bounded, because a dropped folder can be the whole home directory.
    private static func machOFiles(at url: URL, depth: Int) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }

        let dwarf = url.appendingPathComponent("Contents/Resources/DWARF")
        if manager.fileExists(atPath: dwarf.path) {
            return (try? manager.contentsOfDirectory(at: dwarf, includingPropertiesForKeys: nil)) ?? []
        }
        guard depth > 0 else { return [] }
        let children = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.prefix(256).flatMap { machOFiles(at: $0, depth: depth - 1) }
    }
}

public struct SystemSymbolSet: Codable, Hashable, Sendable, Identifiable {
    /// The OS build — `23G83`.
    public var id: String
    public var imageCount: Int
    public var byteCount: UInt64
    public var extracted: Date

    public init(id: String, imageCount: Int, byteCount: UInt64, extracted: Date) {
        self.id = id
        self.imageCount = imageCount
        self.byteCount = byteCount
        self.extracted = extracted
    }
}

/// Symbol tables pulled out of a dyld shared cache once, stored compactly per
/// OS build, so reports from that build symbolicate without the cache — and
/// still do after an OS update replaced it.
public final class SystemSymbolStore: @unchecked Sendable {
    private struct Index: Codable {
        var revision = 0
        var sets = [SystemSymbolSet]()
    }

    private let directory: URL
    private let indexURL: URL
    private let lock = NSLock()
    private var index = Index()

    public init(directory: URL) {
        self.directory = directory
        indexURL = directory.appendingPathComponent("index.plist")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let stored = try? PropertyListDecoder().decode(Index.self, from: data)
        {
            index = stored
        }
    }

    public var revision: Int {
        lock.locked { index.revision }
    }

    public var sets: [SystemSymbolSet] {
        lock.locked { index.sets }
    }

    /// The table extracted for one image of one OS build, or nil when that
    /// build was never extracted.
    public func table(build: String, uuid: String) -> SymbolTable? {
        guard let url = fileURL(build: build, uuid: uuid),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else { return nil }
        return SymbolTable(data: data)
    }

    /// Where one image's table is filed. Both parts are read out of a report,
    /// so neither may name anything but a file directly under the store.
    private func fileURL(build: String, uuid: String) -> URL? {
        let uuid = uuid.uppercased()
        guard Self.isPathComponent(build), Self.isPathComponent(uuid) else { return nil }
        return directory.appendingPathComponent(build).appendingPathComponent("\(uuid).symbols")
    }

    private static func isPathComponent(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix(".") && !text.contains("/") && !text.contains("\0")
    }

    /// Extracts the running system's cache. `progress` is 0…1.
    ///
    /// The whole cache is a few thousand images and a gigabyte or two of
    /// tables. `extract(images:…)` is the same walk over the images a report
    /// actually names; this is the one the app's button runs.
    public func extractCurrentSystem(
        openImage: @escaping ImageOpener,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> SystemSymbolSet {
        try await extract(only: nil, maximumImages: nil, openImage: openImage, progress: progress)
    }

    /// Extracts only the images a report names, into the running system's set,
    /// and leaves what is already extracted alone.
    ///
    /// Reading an image's UUID out of the cache is a load-command walk; what
    /// costs is building its table. A report touches a few dozen images, so
    /// this is one pass over the cache and a few megabytes written rather than
    /// the whole one to two gigabytes.
    public func extract(
        images: Set<UUID>,
        openImage: @escaping ImageOpener,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> SystemSymbolSet {
        try await extract(only: images, maximumImages: nil, openImage: openImage, progress: progress)
    }

    /// `maximumImages` is for the tests, which want a few seconds rather than
    /// the whole cache; nothing in the app passes it.
    func extractCurrentSystem(
        openImage: @escaping ImageOpener,
        maximumImages: Int?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> SystemSymbolSet {
        try await extract(only: nil, maximumImages: maximumImages, openImage: openImage, progress: progress)
    }

    /// `only` nil means the whole cache, and then the build's previous
    /// extraction is replaced rather than added to.
    private func extract(
        only wanted: Set<UUID>?,
        maximumImages: Int?,
        openImage: @escaping ImageOpener,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> SystemSymbolSet {
        guard let cacheURL = Self.sharedCacheURL() else { throw SymbolStoreFailure.noSharedCache }
        // The cache files are root 0755, so a path is enough and MachOKit —
        // which takes URLs, and derives every subcache URL from this one — can
        // open them itself. When a plain open fails the daemon is asked once,
        // so the attempt is made with its privileges too; what comes back
        // cannot be handed to MachOKit for the subcaches, so it is not kept
        // and the extraction stops here.
        if (try? FileHandle(forReadingFrom: cacheURL)) == nil {
            _ = try? await openImage(cacheURL.path)
            throw SymbolStoreFailure.noSharedCache
        }

        let build = Self.osBuild()
        let destination = directory.appendingPathComponent(build)
        if wanted == nil {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let cache = try FullDyldCache(url: cacheURL)
        let total = min(cache.header.imagesCount, maximumImages ?? .max)
        let locals = LocalSymbols(cache: cache)
        let strings = StringPool()

        var missing = wanted
        var visited = 0
        for machO in cache.machOFiles() {
            if visited >= total || missing?.isEmpty == true {
                break
            }
            visited += 1
            // Each image's symbols are built, written and dropped before the
            // next one is read: a whole cache's tables at once is gigabytes.
            autoreleasepool {
                guard let uuid = machO.loadCommands.info(of: LoadCommand.uuid)?.uuid else { return }
                if wanted != nil, missing?.remove(uuid) == nil {
                    return
                }
                let url = destination.appendingPathComponent("\(uuid.uuidString).symbols")
                if wanted != nil, FileManager.default.fileExists(atPath: url.path) {
                    return
                }
                guard let table = Self.symbolTable(for: machO, locals: locals, strings: strings) else { return }
                try? table.data.write(to: url, options: .atomic)
            }
            let fraction = wanted.map { Double($0.count - (missing ?? $0).count) / Double(max($0.count, 1)) }
                ?? Double(visited) / Double(max(total, 1))
            progress(fraction, (machO.imagePath as NSString).lastPathComponent)
            await Task.yield()
        }

        let set = Self.extractedSet(build: build, in: destination)
        lock.locked {
            index.sets.removeAll { $0.id == build }
            index.sets.append(set)
            index.revision += 1
            save()
        }
        return set
    }

    /// Counted off the directory rather than off this pass, so an incremental
    /// extraction still reports what the build's set holds.
    private static func extractedSet(build: String, in destination: URL) -> SystemSymbolSet {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let tables = files.filter { $0.pathExtension == "symbols" }
        return SystemSymbolSet(
            id: build,
            imageCount: tables.count,
            byteCount: tables.reduce(0) { total, url in
                total + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            },
            extracted: Date()
        )
    }

    public func remove(build: String) throws {
        lock.locked {
            guard index.sets.contains(where: { $0.id == build }) else { return }
            index.sets.removeAll { $0.id == build }
            index.revision += 1
            save()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(build))
        }
    }

    private func save() {
        guard let data = try? PropertyListEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// The cache's unmapped local symbols, which on iOS live in a `.symbols`
    /// file beside the cache rather than in it. Without these an image's table
    /// holds only what it exports, and a crash inside a static function of
    /// `libsystem_kernel` names whatever public function precedes it.
    private struct LocalSymbols {
        private let symbols: AnyRandomAccessCollection<MachOFile.Symbol>?
        /// `__TEXT` vmaddr minus the shared region start → this image's range
        /// in the nlist table.
        private let ranges: [UInt64: Range<Int>]
        private let sharedRegionStart: UInt64

        init(cache: FullDyldCache) {
            sharedRegionStart = cache.header.layout.sharedRegionStart
            let symbolCache = (try? cache.symbolCache) ?? nil
            if let symbolCache, let info = symbolCache.localSymbolsInfo {
                symbols = info.symbols(in: symbolCache)
                ranges = Self.ranges(info.entries(in: symbolCache))
            } else if let info = cache.localSymbolsInfo {
                symbols = info.symbols(in: cache)
                ranges = Self.ranges(info.entries(in: cache))
            } else {
                symbols = nil
                ranges = [:]
            }
        }

        private static func ranges(
            _ entries: AnyRandomAccessCollection<any DyldCacheLocalSymbolsEntryProtocol>
        ) -> [UInt64: Range<Int>] {
            var ranges = [UInt64: Range<Int>]()
            for entry in entries where entry.nlistCount > 0 {
                let start = entry.nlistStartIndex
                ranges[UInt64(entry.dylibOffset)] = start ..< start + entry.nlistCount
            }
            return ranges
        }

        func symbols(forTextVMAddress address: UInt64) -> AnySequence<MachOFile.Symbol> {
            guard let symbols, address >= sharedRegionStart,
                  let range = ranges[address - sharedRegionStart],
                  range.upperBound <= symbols.count
            else { return AnySequence([]) }
            return AnySequence(symbols.dropFirst(range.lowerBound).prefix(range.count))
        }
    }

    /// Every image in a cache names the same string pool, and the only public
    /// way to it is a copy — so it is copied once, not once per image.
    ///
    // ponytail: that one copy is the whole pool, a hundred megabytes or so,
    // held for the length of an extraction. Map the linkedit file ourselves
    // if that ever matters on a small device.
    private final class StringPool {
        private var key: (UInt32, UInt32)?
        private var pool = Data()

        func data(for symbols: MachOFile.Symbols64) -> Data {
            guard let layout = symbols.symtab?.layout else { return Data() }
            if key?.0 != layout.stroff || key?.1 != layout.strsize {
                key = (layout.stroff, layout.strsize)
                pool = symbols.stringsData ?? Data()
            }
            return pool
        }
    }

    /// The `nlist_64` entries that are defined in a section and are not
    /// debugger stabs: string offset and address, read by hand and in bounds.
    static func definedSymbols(in nlists: Data) -> [(nameOffset: Int, address: UInt64)] {
        let stride = nlist64Size
        return nlists.withUnsafeBytes { bytes in
            (0 ..< bytes.count / stride).compactMap { index in
                let at = index * stride
                let type = bytes[at + 4]
                // N_STAB clear, N_TYPE == N_SECT.
                guard type & symbolStabMask == 0, type & symbolTypeMask == symbolTypeSection else { return nil }
                return (
                    Int(bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)),
                    bytes.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)
                )
            }
        }
    }

    /// The NUL-terminated name at `offset`, or nothing when the offset or the
    /// terminator is outside the pool.
    static func cString(in pool: Data, at offset: Int) -> String {
        guard offset >= 0, offset < pool.count else { return "" }
        let start = pool.startIndex + offset
        guard let end = pool[start...].firstIndex(of: 0) else { return "" }
        return String(decoding: pool[start ..< end], as: UTF8.self)
    }

    private static func symbolTable(
        for machO: MachOFile,
        locals: LocalSymbols,
        strings: StringPool
    ) -> SymbolTable? {
        guard let text = machO.loadCommands
            .infos(of: LoadCommand.segment64)
            .first(where: { $0.segmentName == "__TEXT" })
        else { return nil }
        let textVMAddress = UInt64(text.virtualMemoryAddress)
        // Only what is in __TEXT: a data symbol has an address no frame can
        // ever carry, and a whole cache's worth of them is hundreds of
        // megabytes of file nobody reads.
        let textVMEnd = textVMAddress &+ text.layout.vmsize

        var entries = [SymbolTable.Entry]()
        func add(_ name: String, at address: UInt64) {
            guard address >= textVMAddress, address < textVMEnd, !name.isEmpty else { return }
            entries.append(SymbolTable.Entry(offset: address - textVMAddress, name: name))
        }
        // Not `machO.symbols`: its iterator casts every `n_value` to `Int`
        // and traps on the first one above `Int.max`, which a real cache has.
        if let symbols = machO.symbols64, let nlists = symbols.symbolsData {
            let strings = strings.data(for: symbols)
            for (nameOffset, address) in definedSymbols(in: nlists) {
                add(cString(in: strings, at: nameOffset), at: address)
            }
        }
        // ponytail: the locals still come through MachOKit's own iterator.
        // They are functions inside the shared region, so none has tripped
        // the same cast; read that table raw too if one ever does.
        for symbol in locals.symbols(forTextVMAddress: textVMAddress) {
            add(symbol.name, at: UInt64(bitPattern: Int64(symbol.offset)))
        }
        if let starts = machO.functionStarts {
            for start in starts where UInt64(start.offset) >= textVMAddress {
                entries.append(SymbolTable.Entry(offset: UInt64(start.offset) - textVMAddress, name: nil))
            }
        }
        guard !entries.isEmpty else { return nil }
        entries.append(SymbolTable.Entry(offset: UInt64(text.layout.vmsize), name: nil))
        return SymbolTable(entries: entries)
    }

    /// The cache this process is running out of, as dyld names it. The
    /// function is in libdyld on every OS this app runs on but in no public
    /// header, hence the lookup by name.
    private static func loadedSharedCachePath() -> String? {
        typealias FilePath = @convention(c) () -> UnsafePointer<CChar>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_shared_cache_file_path"),
              let path = unsafeBitCast(symbol, to: FilePath.self)()
        else { return nil }
        return String(cString: path)
    }

    /// Where the running system keeps its cache. dyld is asked first, because
    /// the directory has moved with the OS more than once; the list is for a
    /// process dyld gives no answer to. The Cryptex paths are where iOS 16 and
    /// later put it — under `Caches/com.apple.dyld` on an iPad running 18.5
    /// (seen 2026-09-21) — and the Preboot one is a Mac, which is where the
    /// tests run.
    static func sharedCacheURL() -> URL? {
        if let path = loadedSharedCachePath(), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let directories = [
            "/System/Library/Caches/com.apple.dyld",
            "/System/Library/dyld",
            "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
            "/private/preboot/Cryptexes/OS/System/Library/dyld",
            "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
            "/System/Cryptexes/OS/System/Library/dyld",
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
        ]
        let names = [
            "dyld_shared_cache_arm64e", "dyld_shared_cache_arm64",
            "dyld_shared_cache_x86_64h", "dyld_shared_cache_x86_64",
        ]
        for directory in directories {
            for name in names {
                let path = directory + "/" + name
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    /// `23G83`. The build a report was written on is what its symbols are
    /// filed under, and this is the running one.
    public static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: value)
    }
}

extension NSLock {
    /// Foundation's own `withLock` starts at iOS 16; this app starts at 15, and
    /// a second spelling avoids an ambiguity on the newer SDK.
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

import Foundation
import XrashReport

/// How the symbolicator gets at a binary or a shared cache file. The app
/// passes `ReportBackend.openImage`; tests pass a plain open.
public typealias ImageOpener = @Sendable (_ path: String) async throws -> FileHandle

public struct SymbolicationProgress: Sendable {
    public var completedImages: Int
    public var totalImages: Int
    public var currentImage: String

    public init(completedImages: Int, totalImages: Int, currentImage: String) {
        self.completedImages = completedImages
        self.totalImages = totalImages
        self.currentImage = currentImage
    }
}

/// Fills in the frames of a report. Per image, by UUID, first hit wins:
/// imported dSYM → the binary on disk → extracted system symbols → the live
/// dyld shared cache → the name Apple already wrote → left as it is.
/// A pure function of (report, stores): the same inputs give the same report.
public actor Symbolicator {
    /// Everything one image can answer with, and where it came from.
    private struct Resolver {
        var symbols: SymbolTable
        var lines: DWARFLineTable?
        /// What a report's image offset has to be added to before the line
        /// table is asked: DWARF addresses are the image's own vm addresses.
        var textVMAddress: UInt64
        var source: SymbolSource
    }

    private let dsyms: DSYMStore
    private let systemSymbols: SystemSymbolStore
    private let openImage: ImageOpener

    /// Keyed by image UUID. A report of any size touches a few dozen images,
    /// and a viewer walks several reports from the same build in a row.
    private var resolvers = [String: Resolver?]()
    private var order = [String]()
    /// What the stores held when the cache was filled. An import is the one
    /// thing that turns a "nothing names this image" into an answer.
    private var storeRevisions: (dsyms: Int, system: Int)?
    private static let cacheLimit = 32

    public init(dsyms: DSYMStore, systemSymbols: SystemSymbolStore, openImage: @escaping ImageOpener) {
        self.dsyms = dsyms
        self.systemSymbols = systemSymbols
        self.openImage = openImage
    }

    public func symbolicate(
        _ crash: CrashReport,
        progress: (@Sendable (SymbolicationProgress) -> Void)? = nil
    ) async -> CrashReport {
        let revisions = (dsyms: dsyms.revision, system: systemSymbols.revision)
        if (storeRevisions ?? revisions) != revisions {
            resolvers.removeAll()
            order.removeAll()
        }
        storeRevisions = revisions

        let referenced = Set((crash.threads.flatMap(\.frames) + crash.lastExceptionBacktrace)
            .compactMap(\.imageIndex))
        let indices = referenced.filter { crash.images.indices.contains($0) }.sorted()

        var resolved = [Int: Resolver]()
        for (completed, index) in indices.enumerated() {
            let image = crash.images[index]
            progress?(SymbolicationProgress(
                completedImages: completed,
                totalImages: indices.count,
                currentImage: image.name
            ))
            if let resolver = await resolver(for: image, osBuild: crash.device.osBuild) {
                resolved[index] = resolver
            }
        }
        progress?(SymbolicationProgress(
            completedImages: indices.count,
            totalImages: indices.count,
            currentImage: ""
        ))

        var crash = crash
        for index in crash.threads.indices {
            for frame in crash.threads[index].frames.indices {
                fill(&crash.threads[index].frames[frame], with: resolved)
            }
        }
        for index in crash.lastExceptionBacktrace.indices {
            fill(&crash.lastExceptionBacktrace[index], with: resolved)
        }
        return crash
    }

    private func fill(_ frame: inout Frame, with resolved: [Int: Resolver]) {
        guard let index = frame.imageIndex, let resolver = resolved[index],
              let found = resolver.symbols.lookup(offset: frame.imageOffset)
        else {
            // Nothing there under a better source than Apple's: what the report
            // already said stands, and says where it came from.
            if frame.symbol != nil, frame.symbolSource == nil {
                frame.symbolSource = .report
            }
            return
        }
        frame.symbol = Demangler.demangle(found.name)
        frame.symbolLocation = frame.imageOffset - found.startOffset
        frame.symbolSource = resolver.source
        if let location = resolver.lines?.lookup(address: resolver.textVMAddress &+ frame.imageOffset) {
            frame.sourceFile = location.file
            frame.sourceLine = location.line
        }
    }

    // MARK: Finding something that can name this image

    private func resolver(for image: BinaryImage, osBuild: String?) async -> Resolver? {
        let key = image.uuid.uppercased()
        if let cached = resolvers[key] {
            touch(key)
            return cached
        }
        let resolver = await makeResolver(for: image, osBuild: osBuild)
        resolvers[key] = resolver
        touch(key)
        while order.count > Self.cacheLimit {
            resolvers.removeValue(forKey: order.removeFirst())
        }
        return resolver
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func makeResolver(for image: BinaryImage, osBuild: String?) async -> Resolver? {
        guard let uuid = UUID(uuidString: image.uuid) else { return nil }

        if let url = dsyms.url(forUUID: image.uuid),
           let handle = try? FileHandle(forReadingFrom: url),
           let data = try? Data.mapping(handle)
        {
            if let slice = MachOSlice.slice(of: data, uuid: uuid) {
                return Resolver(
                    symbols: slice.symbolTable(),
                    lines: Self.lineTable(of: slice),
                    textVMAddress: slice.textVMAddress,
                    source: .dsym
                )
            }
        }

        if !image.path.isEmpty,
           let handle = try? await openImage(image.path),
           let data = try? Data.mapping(handle)
        {
            // A UUID that does not match means the binary was replaced since
            // the crash — an update, a rebuild — and its addresses now name
            // other functions. Better nothing than a plausible wrong answer.
            if let slice = MachOSlice.slice(of: data, uuid: uuid) {
                return Resolver(
                    symbols: slice.symbolTable(),
                    lines: nil,
                    textVMAddress: slice.textVMAddress,
                    source: .binary
                )
            }
        }

        if let osBuild, let table = systemSymbols.table(build: osBuild, uuid: image.uuid) {
            return Resolver(symbols: table, lines: nil, textVMAddress: 0, source: .systemSymbols)
        }

        // ponytail: the live shared cache is not read frame-by-frame. Opening
        // it costs the same as extracting it, and the extraction is already a
        // button in the app — `.sharedCache` stays in the model for a report
        // symbolicated on the device that produced it, once that is measured
        // to be worth a second code path.
        return nil
    }

    private static func lineTable(of slice: MachOSlice) -> DWARFLineTable? {
        guard let debugLine = slice.section(segment: "__DWARF", name: "__debug_line") else { return nil }
        let table = DWARFLineTable(
            debugLine: debugLine,
            debugLineStr: slice.section(segment: "__DWARF", name: "__debug_line_str"),
            debugStr: slice.section(segment: "__DWARF", name: "__debug_str")
        )
        return table.isEmpty ? nil : table
    }
}

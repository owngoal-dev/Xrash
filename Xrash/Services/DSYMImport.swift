import Foundation
import XrashBundle
import XrashSymbols

/// The Kit has no string catalogue; what its failures say to a person is said
/// here. Without these an alert reads "SymbolStoreFailure error 0".
extension SymbolStoreFailure: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDebugSymbols:
            String(localized: "No debug symbols were found in that file.")
        case .noSharedCache:
            String(localized: "The system symbols could not be read.")
        }
    }
}

extension BundleArchiveError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotWrite:
            String(localized: "The archive could not be written.")
        case .cannotRead, .unsafeEntryPath:
            String(localized: "The archive could not be read. It may be damaged.")
        case .missingManifest:
            String(localized: "That archive is not an Xrash report.")
        case .unsupportedSchema:
            String(localized: "That report was made by a newer version of Xrash.")
        }
    }
}

/// A `.dSYM`, a bare DWARF file, a folder of either — or a zip of any of
/// them, which is how every release attaches its symbols. `DSYMStore` reads
/// Mach-O and does not unpack; the unpacking is here, once, for both the Files
/// import and the GitHub one.
enum DSYMImport {
    /// How many symbol files went into the store.
    static func run(at url: URL, into store: DSYMStore) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard isZip(url) else { return try store.importDSYM(at: url).count }

        let unpacked = FileManager.default.temporaryDirectory
            .appendingPathComponent("Symbols-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        try BundleArchive.extractZip(url, into: unpacked)
        return try store.importDSYM(at: unpacked).count
    }

    /// `run` for a caller on the main actor: only a thread to get off, and
    /// `@concurrent` because a plain `nonisolated async` would stay on it.
    @concurrent nonisolated static func runDetached(at url: URL, into store: DSYMStore) async throws -> Int {
        try run(at: url, into: store)
    }

    /// By its first bytes, not its name: Files hands over whatever it was called.
    private static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }
}

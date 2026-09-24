import ArchiveKit
import Darwin
import Foundation

/// Unpacks a zip that someone else may have written.
///
/// Every name is refused before it is joined onto anything, links and devices
/// are dropped rather than recreated, and a running total stops the small zip
/// that unpacks to a full disk. A bundle arrives through Files, AirDrop or a
/// Discord thread: none of those are the user's own disk.
enum ZipReader {
    /// A bundle is reports and a few binaries. Anything past these is not one.
    static let maximumTotalBytes: Int64 = 2 << 30
    static let maximumEntryCount = 20000

    static func extract(_ archive: URL, into directory: URL) throws {
        guard let handle = archive_read_new() else {
            throw BundleArchiveError.cannotRead
        }
        defer { archive_read_free(handle) }
        archive_read_support_format_zip(handle)
        archive_read_support_filter_none(handle)
        try Zip.checkRead(archive_read_open_filename(handle, archive.path, Zip.chunkByteCount))

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BundleArchiveError.cannotRead
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()

        var entryCount = 0
        var totalBytes: Int64 = 0
        while true {
            var entry: OpaquePointer?
            let status = Zip.withUTF8Locale { archive_read_next_header(handle, &entry) }
            if status == ARCHIVE_EOF {
                break
            }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else {
                throw BundleArchiveError.cannotRead
            }
            entryCount += 1
            guard entryCount <= maximumEntryCount else {
                throw BundleArchiveError.cannotRead
            }

            let declared = pathname(of: entry)
            guard let relative = BundleLayout.validated(declared) else {
                throw BundleArchiveError.unsafeEntryPath(declared)
            }
            let destination = root.appendingPathComponent(relative).standardizedFileURL
            guard isInside(destination, root: root) else {
                throw BundleArchiveError.unsafeEntryPath(declared)
            }
            // Symlinks, hard links, devices and fifos: a bundle has no use for
            // any of them, and each is a way out of this directory.
            guard mode_t(archive_entry_filetype(entry)) == S_IFREG,
                  archive_entry_hardlink(entry) == nil,
                  archive_entry_hardlink_utf8(entry) == nil else { continue }

            totalBytes += try write(handle, to: destination, budget: maximumTotalBytes - totalBytes)
        }
    }

    /// Streams the current entry to `destination`, refusing to pass `budget`.
    private static func write(_ handle: OpaquePointer, to destination: URL, budget: Int64) throws -> Int64 {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw BundleArchiveError.cannotRead
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: destination)
        else {
            throw BundleArchiveError.cannotRead
        }
        defer { try? writer.close() }

        var written: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: Zip.chunkByteCount)
        while true {
            let read = buffer.withUnsafeMutableBytes { archive_read_data(handle, $0.baseAddress, $0.count) }
            if read == 0 {
                break
            }
            guard read > 0 else { throw BundleArchiveError.cannotRead }
            written += Int64(read)
            guard written <= budget else {
                throw BundleArchiveError.cannotRead
            }
            do {
                try writer.write(contentsOf: Data(buffer[0 ..< read]))
            } catch {
                throw BundleArchiveError.cannotRead
            }
        }
        return written
    }

    /// The manifest of an already-extracted bundle.
    ///
    /// The schema is read on its own first: a bundle from a newer Xrash must
    /// say so rather than fail as a damaged plist.
    static func manifest(in directory: URL) throws -> BundleManifest {
        let path = directory.appendingPathComponent(BundleLayout.manifest).path
        guard let data = FileManager.default.contents(atPath: path) else {
            throw BundleArchiveError.missingManifest
        }
        let decoder = PropertyListDecoder()
        if let probe = try? decoder.decode(SchemaProbe.self, from: data),
           probe.schemaVersion > BundleManifest.currentSchemaVersion
        {
            throw BundleArchiveError.unsupportedSchema(probe.schemaVersion)
        }
        guard let manifest = try? decoder.decode(BundleManifest.self, from: data) else {
            throw BundleArchiveError.cannotRead
        }
        return manifest
    }

    private struct SchemaProbe: Decodable {
        var schemaVersion: Int
    }

    /// The UTF-8 name when the archive declared one, else the raw bytes read as
    /// UTF-8 — a name this fails to read is a name that fails validation.
    private static func pathname(of entry: OpaquePointer) -> String {
        if let utf8 = archive_entry_pathname_utf8(entry) {
            return String(cString: utf8)
        }
        if let raw = archive_entry_pathname(entry) {
            return String(cString: raw)
        }
        return ""
    }

    /// Component comparison after standardising, never a string prefix:
    /// `/tmp/reportsEvil` starts with `/tmp/reports`.
    private static func isInside(_ url: URL, root: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        return components.count > rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}

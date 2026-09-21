import Darwin
import Foundation
import LibArchive

/// Writes the `.xrashreport` zip.
///
/// The archive is built beside its destination as `<name>.partial` and moved
/// into place only once libarchive has written the central directory: a zip
/// without one is not a zip, and a half-written file under the name the user
/// chose is worse than no file.
enum ZipWriter {
    static func write(
        _ manifest: BundleManifest,
        files: [BundleFile],
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let encoder = PropertyListEncoder()
        // XML rather than binary: a bundle someone mails to a developer should
        // open in any text editor.
        encoder.outputFormat = .xml
        guard let manifestData = try? encoder.encode(manifest) else {
            throw BundleArchiveError.cannotWrite
        }

        let members = try planned(files)
        let total = Int64(manifestData.count) + members.reduce(0) { $0 + $1.byteCount }
        var sent: Int64 = 0
        func report(_ bytes: Int64) {
            sent += bytes
            progress?(min(Double(sent) / Double(max(total, 1)), 1))
        }
        progress?(0)

        let partial = URL(fileURLWithPath: destination.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        guard let handle = archive_write_new() else {
            throw BundleArchiveError.cannotWrite
        }
        do {
            try Zip.checkWrite(archive_write_set_format_zip(handle))
            try Zip.checkWrite(archive_write_set_options(handle, "zip:compression=deflate,zip:compression-level=6"))
            try Zip.checkWrite(archive_write_open_filename(handle, partial.path))

            // First, so a reader can answer "what is this?" from the front of
            // the stream instead of the central directory.
            try addData(handle, path: BundleLayout.manifest, data: manifestData, modified: manifest.created)
            report(Int64(manifestData.count))

            for member in members {
                try addFile(handle, member: member, report: report)
            }
            try Zip.checkWrite(archive_write_close(handle))
        } catch {
            archive_write_free(handle)
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        archive_write_free(handle)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw BundleArchiveError.cannotWrite
        }
        progress?(1)
    }

    private struct Member {
        let path: String
        let source: URL
        let byteCount: Int64
        let modified: Date
    }

    /// Names and sizes settled before a byte is written: the progress fraction
    /// needs the total, and a bad name must fail before a file exists.
    private static func planned(_ files: [BundleFile]) throws -> [Member] {
        var seen = Set<String>()
        return try files.map { file in
            guard let path = BundleLayout.validated(file.archivePath), path == file.archivePath else {
                throw BundleArchiveError.unsafeEntryPath(file.archivePath)
            }
            guard seen.insert(path).inserted else {
                throw BundleArchiveError.unsafeEntryPath(path)
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.source.path),
                  let size = attributes[.size] as? Int64
            else {
                throw BundleArchiveError.cannotWrite
            }
            return Member(
                path: path,
                source: file.source,
                byteCount: size,
                modified: attributes[.modificationDate] as? Date ?? Date()
            )
        }
    }

    private static func addData(
        _ handle: OpaquePointer,
        path: String,
        data: Data,
        modified: Date
    ) throws {
        try header(handle, path: path, byteCount: Int64(data.count), modified: modified)
        try data.withUnsafeBytes { try writeBytes(handle, $0) }
        try Zip.checkWrite(archive_write_finish_entry(handle))
    }

    private static func addFile(
        _ handle: OpaquePointer,
        member: Member,
        report: (Int64) -> Void
    ) throws {
        guard let reader = try? FileHandle(forReadingFrom: member.source) else {
            throw BundleArchiveError.cannotWrite
        }
        defer { try? reader.close() }

        try header(handle, path: member.path, byteCount: member.byteCount, modified: member.modified)
        var written: Int64 = 0
        while let chunk = try? reader.read(upToCount: Zip.chunkByteCount), !chunk.isEmpty {
            try chunk.withUnsafeBytes { try writeBytes(handle, $0) }
            written += Int64(chunk.count)
            report(Int64(chunk.count))
        }
        // The header already promised a length and the format gives no way to
        // take it back, so a file that changed size mid-write loses the archive
        // rather than producing one that opens and lies.
        guard written == member.byteCount else {
            throw BundleArchiveError.cannotWrite
        }
        try Zip.checkWrite(archive_write_finish_entry(handle))
    }

    private static func header(
        _ handle: OpaquePointer,
        path: String,
        byteCount: Int64,
        modified: Date
    ) throws {
        guard let entry = archive_entry_new() else {
            throw BundleArchiveError.cannotWrite
        }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, path)
        // libarchive's `AE_IFREG` is `S_IFREG` with a cast the Swift importer
        // drops; the two are defined to be interchangeable.
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_perm(entry, 0o644)
        archive_entry_set_size(entry, byteCount)
        archive_entry_set_mtime(entry, Zip.unixTime(modified), 0)
        try Zip.withUTF8Locale {
            try Zip.checkWrite(archive_write_header(handle, entry))
        }
    }

    private static func writeBytes(_ handle: OpaquePointer, _ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        var sent = 0
        while sent < buffer.count {
            let put = archive_write_data(handle, base.advanced(by: sent), buffer.count - sent)
            guard put > 0 else { throw BundleArchiveError.cannotWrite }
            sent += put
        }
    }
}

// Copied from Fila (MIT, same owner): FilaFormats/DescriptorReader.swift and
// FilaFormats/FormatFailure.swift, trimmed to what the Mach-O reader uses.

import Foundation

/// Positional reads over a descriptor `xrashd` already opened as root.
///
/// Every read is `pread(2)`, never `lseek` + `read`. The descriptor arrived
/// over XPC and this process has no idea what else holds a reference to the
/// same open file description; moving the shared file offset would corrupt
/// whoever else is reading it. It also means a reader is a value with no
/// mutable state, so two parsers can hold the same one.
struct DescriptorReader: Sendable {
    let descriptor: Int32

    /// `st_size` as of construction. A file on a live filesystem can be
    /// truncated underneath a viewer, so reads past the end come back short
    /// rather than failing.
    let byteCount: Int64

    init(descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw FormatFailure.system(errno: errno) }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else { throw FormatFailure.system(errno: EINVAL) }
        self.descriptor = descriptor
        byteCount = Int64(status.st_size)
    }

    /// Up to `count` bytes at `offset`. Short at the end of the file.
    func readUpTo(at offset: Int64, count: Int) throws -> Data {
        guard count > 0, offset >= 0, offset < byteCount else { return Data() }
        let count = min(count, Int(byteCount - offset))
        var buffer = Data(count: count)
        var filled = 0
        while filled < count {
            let got: Int = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress!.advanced(by: filled), count - filled, off_t(offset) + off_t(filled))
            }
            if got < 0 {
                if errno == EINTR {
                    continue
                }
                throw FormatFailure.system(errno: errno)
            }
            if got == 0 {
                break
            }
            filled += got
        }
        buffer.removeSubrange(filled...)
        return buffer
    }

    /// Exactly `count` bytes, or `damaged`. Used wherever a structure's own
    /// header said the bytes are there — if they are not, the file is lying
    /// about its shape and no amount of parsing recovers it.
    func read(at offset: Int64, count: Int) throws -> Data {
        let data = try readUpTo(at: offset, count: count)
        guard data.count == count else {
            throw FormatFailure.damaged("it is truncated")
        }
        return data
    }
}

/// Why a Mach-O read over a descriptor stopped.
///
/// Separate from `MachOReadFailure`, which is what the symbolicator's own
/// `Data`-backed slice reader throws: this one carries a sentence, because the
/// inspector is a screen a person reads and "malformed" is not one.
public enum FormatFailure: Error, Sendable, Hashable {
    /// The magic is not what this reader parses. Not a corruption: it is the
    /// answer to "is this a Mach-O", and callers use it to say so plainly.
    case notRecognised

    /// Structurally broken, with where. Mach-O headers are attacker-controlled
    /// input — every length in them is checked against the bytes actually
    /// present, and this is what a failed check throws rather than reading
    /// whatever `Data` happens to hold next.
    case damaged(String)

    /// Refused before allocating. Reaching for `Data(count:)` with a number
    /// that came out of a file is how a viewer for a 4 GB file becomes a
    /// 4 GB allocation.
    case tooLarge(byteCount: Int64, limit: Int64)

    /// A syscall failed and left this `errno`.
    case system(errno: Int32)
}

extension Data {
    /// Reads a fixed-width integer at a byte offset from the start of this
    /// value, throwing rather than trapping when the bytes are not there.
    ///
    /// Mach-O headers are untrusted input and their length fields routinely
    /// point past the end of a truncated file. A subscript would trap; a slice
    /// would silently read whatever came after. This throws.
    func littleEndian<T: FixedWidthInteger>(at offset: Int) throws -> T {
        try T(littleEndian: load(at: offset))
    }

    func bigEndian<T: FixedWidthInteger>(at offset: Int) throws -> T {
        try T(bigEndian: load(at: offset))
    }

    /// The same read with the byte order decided at run time, which is what a
    /// Mach-O parser needs: the header says which order the rest of the file is
    /// in, so it cannot be a choice between two call sites.
    func integer<T: FixedWidthInteger>(at offset: Int, bigEndian isBigEndian: Bool) throws -> T {
        if isBigEndian {
            return try bigEndian(at: offset)
        }
        return try littleEndian(at: offset)
    }

    private func load<T: FixedWidthInteger>(at offset: Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset <= count - size else {
            throw FormatFailure.damaged("it is truncated")
        }
        var value = T.zero
        _ = Swift.withUnsafeMutableBytes(of: &value) { destination in
            copyBytes(to: destination, from: (startIndex + offset) ..< (startIndex + offset + size))
        }
        return value
    }

    /// A fixed-width field holding a NUL-padded C string, as a Mach-O load
    /// command does. Bytes after the first NUL are ignored, and invalid UTF-8 is
    /// replaced rather than rejected: a dylib with a mangled name still has to
    /// appear in the listing.
    func string(at offset: Int, count length: Int) throws -> String {
        guard offset >= 0, offset <= count - length else {
            throw FormatFailure.damaged("a name inside it is truncated")
        }
        return String(decoding: self[(startIndex + offset)...].prefix(length).prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

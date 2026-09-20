import Foundation

/// Bounds-checked reading over a region of a `Data`.
///
/// Everything this module parses arrived from somewhere else — a dSYM off a
/// build server, a binary out of a package, a file that stopped downloading
/// half way — so every read either stays inside the region or throws. Nothing
/// here may trap: a malformed file has to come back as "no symbols", not as a
/// crash in the crash reporter.
struct ByteReader {
    enum Failure: Error {
        case outOfBounds
    }

    private let data: Data
    /// Absolute index in `data` that relative offset 0 refers to.
    private let start: Int
    private let end: Int
    private var index: Int

    /// `count` nil means "to the end of `data`".
    init(_ data: Data, start: Int = 0, count: Int? = nil) throws {
        let base = data.startIndex + start
        let limit = count.map { base + $0 } ?? data.endIndex
        guard start >= 0, base >= data.startIndex, base <= limit, limit <= data.endIndex else {
            throw Failure.outOfBounds
        }
        self.data = data
        self.start = base
        end = limit
        index = base
    }

    /// How far the cursor has moved from the start of the region.
    var offset: Int {
        index - start
    }

    var count: Int {
        end - start
    }

    var remaining: Int {
        end - index
    }

    var isAtEnd: Bool {
        index >= end
    }

    mutating func seek(to offset: Int) throws {
        guard offset >= 0, offset <= count else { throw Failure.outOfBounds }
        index = start + offset
    }

    mutating func skip(_ byteCount: Int) throws {
        guard byteCount >= 0, byteCount <= remaining else { throw Failure.outOfBounds }
        index += byteCount
    }

    mutating func integer<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= remaining else { throw Failure.outOfBounds }
        defer { index += size }
        return load(at: index)
    }

    mutating func byte() throws -> UInt8 {
        try integer(UInt8.self)
    }

    /// A big-endian field — fat headers are big-endian whatever the slices are.
    mutating func bigEndianInteger<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
        try T(bigEndian: integer(T.self).littleEndian)
    }

    mutating func bytes(_ byteCount: Int) throws -> Data {
        guard byteCount >= 0, byteCount <= remaining else { throw Failure.outOfBounds }
        defer { index += byteCount }
        return data.subdata(in: index ..< index + byteCount)
    }

    /// An unsigned LEB128, as DWARF and the Mach-O link edit write them.
    /// Refuses a run longer than fits in 64 bits rather than looping forever.
    mutating func unsignedLEB() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try byte()
            if shift < 64 {
                value |= UInt64(byte & 0x7F) << shift
            }
            shift += 7
            if byte & 0x80 == 0 {
                return value
            }
            guard shift <= 70 else { throw Failure.outOfBounds }
        }
    }

    mutating func signedLEB() throws -> Int64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var last: UInt8 = 0
        while true {
            let byte = try byte()
            last = byte
            if shift < 64 {
                value |= UInt64(byte & 0x7F) << shift
            }
            shift += 7
            if byte & 0x80 == 0 {
                break
            }
            guard shift <= 70 else { throw Failure.outOfBounds }
        }
        if shift < 64, last & 0x40 != 0 {
            value |= ~0 << shift
        }
        return Int64(bitPattern: value)
    }

    /// A NUL-terminated string. The terminator is consumed; a run to the end of
    /// the region without one is malformed.
    mutating func cString() throws -> String {
        var scan = index
        while scan < end, data[scan] != 0 {
            scan += 1
        }
        guard scan < end else { throw Failure.outOfBounds }
        let text = String(decoding: data[index ..< scan], as: UTF8.self)
        index = scan + 1
        return text
    }

    /// A fixed-width name field, as Mach-O writes segment and section names:
    /// 16 bytes, NUL-padded, and not NUL-terminated when it fills the field.
    mutating func paddedName(_ byteCount: Int) throws -> String {
        let field = try bytes(byteCount)
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    private func load<T: FixedWidthInteger>(at absolute: Int) -> T {
        data.withUnsafeBytes {
            T(littleEndian: $0.loadUnaligned(fromByteOffset: absolute - data.startIndex, as: T.self))
        }
    }
}

extension Data {
    /// The whole of a file, mapped rather than copied: a dSYM or a system
    /// binary is tens of megabytes and only a few pages of it are ever read.
    ///
    /// The descriptor may be one `xrashd` opened for us, which is why this
    /// takes a handle and not a path — and why it closes it. A mapping
    /// outlives the descriptor it was made from, so holding one open past this
    /// buys nothing and leaks when the file was opened over XPC.
    static func mapping(_ handle: FileHandle) throws -> Data {
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            throw ByteReader.Failure.outOfBounds
        }
        let byteCount = Int(status.st_size)
        guard byteCount > 0 else { return Data() }
        let address = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0)
        guard let address, address != MAP_FAILED else { throw ByteReader.Failure.outOfBounds }
        return Data(bytesNoCopy: address, count: byteCount, deallocator: .unmap)
    }
}

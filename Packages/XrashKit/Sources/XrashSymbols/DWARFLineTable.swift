import Foundation

/// The `__DWARF,__debug_line` line-number program of a dSYM, run out into rows.
///
/// Only the line table. Function names come from the dSYM's own symbol table,
/// so `__debug_info` — the abbreviation tables, the DIE tree, the form zoo —
/// never has to be parsed, which is most of DWARF and none of what a crash
/// report needs.
///
/// ponytail: inlined frames are not expanded. That needs `__debug_info`'s
/// `DW_TAG_inlined_subroutine` ranges as well as this table, so a frame inside
/// an inlined call reports the function it was inlined into and `isInlined`
/// stays false. Add it when a report actually reads wrong because of it.
///
/// Nothing here throws out of `init`: a unit that does not parse is skipped —
/// `unit_length` says where the next one starts even when the body is nonsense —
/// and the units that did parse still answer.
public struct DWARFLineTable: Sendable {
    public struct Location: Sendable, Equatable {
        /// The path as the compiler wrote it: a directory from the table joined
        /// to the file name. The viewer shortens it; symbolication keeps it whole.
        public var file: String
        public var line: Int
    }

    private struct Row {
        var address: UInt64
        var file: Int32
        var line: Int32
    }

    /// One run of the state machine, from `DW_LNE_set_address` to
    /// `DW_LNE_end_sequence`. Rows only mean anything inside their own sequence:
    /// two sequences can cover the same addresses in a linked image.
    private struct Sequence {
        var start: UInt64
        var end: UInt64
        var rows: Range<Int>
    }

    private var rows = [Row]()
    private var sequences = [Sequence]()
    private var files = [String]()

    public var isEmpty: Bool {
        sequences.isEmpty
    }

    /// `debugLineStr` and `debugStr` are the sections a version 5 header may
    /// point its file names into; pass what the image has and nil for the rest.
    public init(debugLine: Data, debugLineStr: Data? = nil, debugStr: Data? = nil) {
        var cursor = 0
        // A malformed unit costs us its own rows and nothing else, so long as
        // the length field itself was readable.
        while cursor + 4 <= debugLine.count {
            guard var header = try? ByteReader(debugLine, start: cursor) else { return }
            guard let first = try? header.integer(UInt32.self) else { return }
            var isDWARF64 = false
            var length = UInt64(first)
            if first == 0xFFFF_FFFF {
                isDWARF64 = true
                guard let wide = try? header.integer(UInt64.self) else { return }
                length = wide
            } else if first >= 0xFFFF_FFF0 {
                return // reserved: the rest of the section cannot be walked
            }
            let bodyStart = cursor + header.offset
            guard length > 0, length <= UInt64(debugLine.count - bodyStart) else { return }
            let unitEnd = bodyStart + Int(length)

            try? readUnit(
                debugLine,
                from: bodyStart,
                to: unitEnd,
                isDWARF64: isDWARF64,
                debugLineStr: debugLineStr,
                debugStr: debugStr,
            )
            cursor = unitEnd
        }
        sequences.sort { $0.start < $1.start }
    }

    /// The file and line for an address in the dSYM's own address space — for a
    /// frame that is `__TEXT`'s vmaddr plus the report's image offset.
    public func lookup(address: UInt64) -> Location? {
        guard let sequence = sequence(containing: address) else { return nil }
        guard let row = row(notAfter: address, in: sequence) else { return nil }
        let file = Int(rows[row].file)
        guard files.indices.contains(file) else { return nil }
        return Location(file: files[file], line: Int(rows[row].line))
    }

    private func sequence(containing address: UInt64) -> Sequence? {
        var low = 0
        var high = sequences.count
        while low < high {
            let middle = low + (high - low) / 2
            if sequences[middle].start <= address {
                low = middle + 1
            } else {
                high = middle
            }
        }
        // Sequences do not overlap in practice, but a linker can leave a dead
        // one behind at address 0; walking back a few is cheaper than a tree.
        var index = low - 1
        while index >= 0 {
            if address < sequences[index].end {
                return sequences[index]
            }
            index -= 1
            if low - index > 8 {
                return nil
            }
        }
        return nil
    }

    private func row(notAfter address: UInt64, in sequence: Sequence) -> Int? {
        var low = sequence.rows.lowerBound
        var high = sequence.rows.upperBound
        while low < high {
            let middle = low + (high - low) / 2
            if rows[middle].address <= address {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == sequence.rows.lowerBound ? nil : low - 1
    }

    // MARK: Reading one unit

    private struct Header {
        var minimumInstructionLength: UInt64 = 1
        var maximumOperationsPerInstruction: UInt64 = 1
        var lineBase: Int64 = 0
        var lineRange: UInt64 = 1
        var opcodeBase: UInt8 = 1
        var standardOpcodeLengths = [UInt8]()
        var addressSize = 8
        /// The `file` register's value → an index into `files`, or -1 for a
        /// file number this unit does not describe. Version 5 numbers files
        /// from 0; earlier versions from 1 and leave 0 meaning "the unit's own
        /// file", which this table does not carry — so slot 0 is -1 there and
        /// both versions index by the register's value unchanged.
        var fileIndices = [Int]()
    }

    private mutating func readUnit(
        _ section: Data,
        from start: Int,
        to end: Int,
        isDWARF64: Bool,
        debugLineStr: Data?,
        debugStr: Data?,
    ) throws {
        var reader = try ByteReader(section, start: start, count: end - start)
        let version = try reader.integer(UInt16.self)
        guard (2 ... 5).contains(version) else { return }

        var header = Header()
        if version >= 5 {
            header.addressSize = try Int(reader.byte())
            guard header.addressSize == 4 || header.addressSize == 8 else { return }
            try reader.skip(1) // segment_selector_size
        }
        let headerLength = try isDWARF64 ? reader.integer(UInt64.self) : UInt64(reader.integer(UInt32.self))
        // Bounded before it is narrowed: a DWARF64 header_length is 64 bits
        // wide, and `Int(clamping:)` on a large one would overflow the addition.
        guard headerLength <= UInt64(reader.remaining) else { throw ByteReader.Failure.outOfBounds }
        let programStart = reader.offset + Int(headerLength)

        header.minimumInstructionLength = try UInt64(reader.byte())
        if version >= 4 {
            header.maximumOperationsPerInstruction = try UInt64(reader.byte())
        }
        try reader.skip(1) // default_is_stmt
        header.lineBase = try Int64(Int8(bitPattern: reader.byte()))
        header.lineRange = try UInt64(reader.byte())
        header.opcodeBase = try reader.byte()
        guard header.lineRange > 0, header.minimumInstructionLength > 0,
              header.maximumOperationsPerInstruction > 0, header.opcodeBase > 0
        else { return }
        header.standardOpcodeLengths = try (1 ..< Int(header.opcodeBase)).map { _ in try reader.byte() }

        if version >= 5 {
            try readVersion5Files(
                &reader,
                into: &header,
                isDWARF64: isDWARF64,
                debugLineStr: debugLineStr,
                debugStr: debugStr,
            )
        } else {
            try readEarlyFiles(&reader, into: &header)
        }

        try reader.seek(to: programStart)
        try runProgram(&reader, header: header)
    }

    private func directoryJoined(_ directory: String?, _ name: String) -> String {
        guard let directory, !directory.isEmpty, !name.hasPrefix("/") else { return name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private mutating func readEarlyFiles(_ reader: inout ByteReader, into header: inout Header) throws {
        var directories = [""]
        while true {
            let entry = try reader.cString()
            if entry.isEmpty {
                break
            }
            directories.append(entry)
        }
        // Version 2–4 number files from 1, so slot 0 stands for "the unit's own
        // file", which only `__debug_info` names.
        header.fileIndices = [-1]
        while true {
            let name = try reader.cString()
            if name.isEmpty {
                break
            }
            let directory = try Int(reader.unsignedLEB())
            _ = try reader.unsignedLEB() // mtime
            _ = try reader.unsignedLEB() // length
            header.fileIndices.append(files.count)
            files.append(directoryJoined(directories.indices.contains(directory) ? directories[directory] : nil, name))
        }
    }

    private mutating func readVersion5Files(
        _ reader: inout ByteReader,
        into header: inout Header,
        isDWARF64: Bool,
        debugLineStr: Data?,
        debugStr: Data?,
    ) throws {
        let directories = try readEntries(
            &reader,
            isDWARF64: isDWARF64,
            debugLineStr: debugLineStr,
            debugStr: debugStr,
        )
        .map(\.path)
        let entries = try readEntries(
            &reader,
            isDWARF64: isDWARF64,
            debugLineStr: debugLineStr,
            debugStr: debugStr,
        )
        header.fileIndices = entries.map { entry in
            let directory = entry.directory.flatMap { directories.indices.contains($0) ? directories[$0] : nil }
            files.append(directoryJoined(directory, entry.path))
            return files.count - 1
        }
    }

    private struct FileEntry {
        var path = ""
        var directory: Int?
    }

    /// One `*_entry_format` table and the entries that follow it. A form this
    /// does not know throws, because its size is unknown and the rest of the
    /// header cannot be walked past it.
    private func readEntries(
        _ reader: inout ByteReader,
        isDWARF64: Bool,
        debugLineStr: Data?,
        debugStr: Data?,
    ) throws -> [FileEntry] {
        let formatCount = try Int(reader.byte())
        var formats = [(content: UInt64, form: UInt64)]()
        for _ in 0 ..< formatCount {
            try formats.append((content: reader.unsignedLEB(), form: reader.unsignedLEB()))
        }
        let count = try Int(clamping: reader.unsignedLEB())
        // Every entry costs at least one byte, so a count past what is left is
        // a length field asking us to allocate.
        guard count <= reader.remaining else { throw ByteReader.Failure.outOfBounds }

        var entries = [FileEntry]()
        entries.reserveCapacity(count)
        for _ in 0 ..< count {
            var entry = FileEntry()
            for format in formats {
                let value = try readForm(
                    &reader,
                    form: format.form,
                    isDWARF64: isDWARF64,
                    debugLineStr: debugLineStr,
                    debugStr: debugStr,
                )
                switch format.content {
                case contentTypePath:
                    if case let .text(path) = value {
                        entry.path = path
                    }
                case contentTypeDirectoryIndex:
                    if case let .number(index) = value {
                        entry.directory = Int(clamping: index)
                    }
                default:
                    break
                }
            }
            entries.append(entry)
        }
        return entries
    }

    private enum FormValue {
        case text(String)
        case number(UInt64)
        case other
    }

    private func readForm(
        _ reader: inout ByteReader,
        form: UInt64,
        isDWARF64: Bool,
        debugLineStr: Data?,
        debugStr: Data?,
    ) throws -> FormValue {
        switch form {
        case formString:
            return try .text(reader.cString())
        case formLineStrp, formStrp, formStrpSup:
            let offset = try isDWARF64 ? reader.integer(UInt64.self) : UInt64(reader.integer(UInt32.self))
            let strings = form == formLineStrp ? debugLineStr : debugStr
            return .text(string(in: strings, at: offset) ?? "")
        case formUData:
            return try .number(reader.unsignedLEB())
        case formSData:
            return try .number(UInt64(bitPattern: reader.signedLEB()))
        case formData1:
            return try .number(UInt64(reader.byte()))
        case formData2:
            return try .number(UInt64(reader.integer(UInt16.self)))
        case formData4:
            return try .number(UInt64(reader.integer(UInt32.self)))
        case formData8:
            return try .number(reader.integer(UInt64.self))
        case formData16:
            try reader.skip(16) // an MD5, which nothing here compares
            return .other
        case formBlock:
            let length = try Int(clamping: reader.unsignedLEB())
            try reader.skip(length)
            return .other
        case formBlock1:
            let length = try Int(reader.byte())
            try reader.skip(length)
            return .other
        default:
            throw ByteReader.Failure.outOfBounds
        }
    }

    private func string(in section: Data?, at offset: UInt64) -> String? {
        guard let section, offset < UInt64(section.count),
              var reader = try? ByteReader(section, start: Int(offset))
        else { return nil }
        return try? reader.cString()
    }

    // MARK: The state machine

    private mutating func runProgram(_ reader: inout ByteReader, header: Header) throws {
        var address: UInt64 = 0
        var operationIndex: UInt64 = 0
        // The `file` register starts at 1 in every version, including 5, where
        // file numbering nevertheless starts at 0. Clang emits an explicit
        // `DW_LNS_set_file 0` for a version 5 unit's own file because of it.
        var file = 1
        var line: Int64 = 1
        var sequenceStart = rows.count

        /// `advance` counts operations, which on a VLIW target are not one per
        /// instruction. Nothing Apple ships is VLIW, but the arithmetic is the
        /// standard's and costs a division only when it has to.
        func advance(_ operations: UInt64) {
            if header.maximumOperationsPerInstruction == 1 {
                address &+= header.minimumInstructionLength &* operations
            } else {
                let total = operationIndex &+ operations
                address &+= header.minimumInstructionLength
                    &* (total / header.maximumOperationsPerInstruction)
                operationIndex = total % header.maximumOperationsPerInstruction
            }
        }

        func emit() {
            let index = header.fileIndices.indices.contains(file) ? header.fileIndices[file] : -1
            rows.append(Row(address: address, file: Int32(clamping: index), line: Int32(clamping: line)))
        }

        func endSequence() {
            emit()
            if rows.count > sequenceStart + 1 {
                // The last row marks the end of the sequence, not a statement.
                sequences.append(Sequence(
                    start: rows[sequenceStart].address,
                    end: address,
                    rows: sequenceStart ..< rows.count - 1,
                ))
                rows.removeLast()
            } else {
                rows.removeSubrange(sequenceStart ..< rows.count)
            }
            sequenceStart = rows.count
            address = 0
            operationIndex = 0
            file = 1
            line = 1
        }

        while !reader.isAtEnd {
            let opcode = try reader.byte()
            if opcode >= header.opcodeBase {
                let adjusted = UInt64(opcode - header.opcodeBase)
                advance(adjusted / header.lineRange)
                line &+= header.lineBase &+ Int64(adjusted % header.lineRange)
                emit()
                continue
            }
            switch opcode {
            case 0:
                let length = try Int(clamping: reader.unsignedLEB())
                guard length > 0, length <= reader.remaining else { throw ByteReader.Failure.outOfBounds }
                let next = reader.offset + length
                let extended = try reader.byte()
                switch extended {
                case extendedEndSequence:
                    endSequence()
                case extendedSetAddress:
                    address = try header.addressSize == 8
                        ? reader.integer(UInt64.self)
                        : UInt64(reader.integer(UInt32.self))
                    operationIndex = 0
                case extendedDefineFile:
                    _ = try reader.cString()
                    _ = try reader.unsignedLEB() // directory
                    _ = try reader.unsignedLEB() // mtime
                    _ = try reader.unsignedLEB() // length
                default:
                    break // including DW_LNE_set_discriminator, which changes no row
                }
                try reader.seek(to: next)
            case standardCopy:
                emit()
            case standardAdvancePC:
                try advance(reader.unsignedLEB())
            case standardAdvanceLine:
                line &+= try reader.signedLEB()
            case standardSetFile:
                file = try Int(clamping: reader.unsignedLEB())
            case standardConstAddPC:
                advance(UInt64(255 - header.opcodeBase) / header.lineRange)
            case standardFixedAdvancePC:
                // The one opcode that does not scale by the instruction length.
                address &+= try UInt64(reader.integer(UInt16.self))
                operationIndex = 0
            default:
                // set_column, negate_stmt, basic_block, prologue_end,
                // epilogue_begin, set_isa — and any vendor opcode the header
                // declared, whose operands it also told us how to count.
                let lengths = header.standardOpcodeLengths
                let count = lengths.indices.contains(Int(opcode) - 1) ? Int(lengths[Int(opcode) - 1]) : 0
                for _ in 0 ..< count {
                    _ = try reader.unsignedLEB()
                }
            }
        }
        // A program that stopped without DW_LNE_end_sequence describes nothing
        // we can bound, so its trailing rows go.
        rows.removeSubrange(sequenceStart ..< rows.count)
    }
}

// MARK: Constants

// DWARF 5, section 6.2 and table 7.27. Spelled out for the same reason the
// Mach-O ones are: they are part of the format, not of a header on this machine.

private let standardCopy: UInt8 = 1
private let standardAdvancePC: UInt8 = 2
private let standardAdvanceLine: UInt8 = 3
private let standardSetFile: UInt8 = 4
private let standardConstAddPC: UInt8 = 8
private let standardFixedAdvancePC: UInt8 = 9

private let extendedEndSequence: UInt8 = 1
private let extendedSetAddress: UInt8 = 2
private let extendedDefineFile: UInt8 = 3

private let contentTypePath: UInt64 = 1
private let contentTypeDirectoryIndex: UInt64 = 2

private let formData2: UInt64 = 0x05
private let formData4: UInt64 = 0x06
private let formData8: UInt64 = 0x07
private let formString: UInt64 = 0x08
private let formBlock: UInt64 = 0x09
private let formBlock1: UInt64 = 0x0A
private let formData1: UInt64 = 0x0B
private let formSData: UInt64 = 0x0D
private let formStrp: UInt64 = 0x0E
private let formUData: UInt64 = 0x0F
private let formStrpSup: UInt64 = 0x1D
private let formData16: UInt64 = 0x1E
private let formLineStrp: UInt64 = 0x1F

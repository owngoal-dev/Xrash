import Foundation

/// A file this reader will not parse: the magic is not a Mach-O's or a fat
/// file's, or a length, an offset or a load command points outside the file.
/// One case, because a dSYM that cannot be read is a dSYM that cannot be
/// imported and no caller acts on the difference; the guard that refused says
/// which check it was.
public enum MachOReadFailure: Error, Equatable {
    case unreadable
}

/// One Mach-O — a thin file, or one architecture of a fat one — read straight
/// out of the bytes with every offset checked against the slice it came from.
///
/// MachOKit parses this shape too, and this module uses it for the dyld shared
/// cache. It is not used here: it takes a URL (we may hold nothing but a
/// descriptor `xrashd` opened), it maps the file and trusts it, and its symbol
/// iterator walks the string table by an index it never bounds-checks. A dSYM
/// arrives from outside; its string table has to be read defensively.
public struct MachOSlice: Sendable {
    /// `LC_UUID` — what a report and a dSYM are matched on.
    public let uuid: UUID?
    /// What `lipo -info` would print.
    public let arch: String
    /// The `__TEXT` segment's vmaddr. A report's image offset is relative to
    /// the Mach-O header, which is where `__TEXT` begins, so this is what turns
    /// an offset from a report into an address in this file.
    public let textVMAddress: UInt64
    /// `__TEXT`'s vmsize: past this, an offset belongs to no function here.
    private let textVMSize: UInt64

    /// The whole file, and where this slice sits in it — offsets from
    /// `data.startIndex`, as `ByteReader` counts them, because a `Data` handed
    /// in from outside can be a slice whose indices do not start at zero.
    private let data: Data
    private let range: Range<Int>
    private let sections: [Section]
    private let symbolTableCommand: SymbolTableCommand?
    private let functionStartsCommand: LinkEditCommand?

    private struct Section {
        let segment: String
        let name: String
        let offset: UInt32
        let size: UInt64
        /// `S_ZEROFILL` and friends: no bytes on disk, so `offset` means nothing.
        let hasContents: Bool
    }

    private struct SymbolTableCommand {
        let symbolOffset: UInt32, symbolCount: UInt32
        let stringOffset: UInt32, stringSize: UInt32
    }

    private struct LinkEditCommand {
        let offset: UInt32, size: UInt32
    }

    /// The slice's own bytes. Copies, so it is for writing a slice out, not for
    /// reading fields.
    public var bytes: Data {
        subdata(from: range.lowerBound, count: range.count)
    }

    public var byteCount: UInt64 {
        UInt64(range.count)
    }

    // MARK: Finding the slices of a file

    /// Every 64-bit little-endian slice of a file, in the order the fat header
    /// lists them. A slice of another architecture is left out rather than
    /// failing the file: a fat dSYM with an armv7 slice still has its arm64 one.
    public static func slices(of data: Data) throws -> [MachOSlice] {
        var reader = try ByteReader(data)
        let magic: UInt32 = try reader.integer()
        switch magic {
        case machO64Magic:
            return try [MachOSlice(data, 0 ..< data.count)]
        case machO32Magic, machO64SwappedMagic, machO32SwappedMagic:
            // A 32-bit or big-endian slice: a real Mach-O, and not one this app
            // has anything to symbolicate against on iOS 15 and later.
            return []
        case fatMagic, fat64Magic:
            return try fatSlices(data, is64: magic == fat64Magic)
        default:
            throw MachOReadFailure.unreadable
        }
    }

    /// The slice a report's image UUID names, or nil when this file holds none.
    public static func slice(of data: Data, uuid: UUID) -> MachOSlice? {
        (try? slices(of: data))?.first { $0.uuid == uuid }
    }

    private static func fatSlices(_ data: Data, is64: Bool) throws -> [MachOSlice] {
        var reader = try ByteReader(data)
        try reader.skip(4)
        let count = try reader.bigEndianInteger(UInt32.self)
        // `lipo` refuses more than a handful. A Java class file opens with the
        // same four bytes, and its next field is a version, so a large count is
        // most likely not a fat header at all.
        guard count > 0, count <= 32 else { throw MachOReadFailure.unreadable }

        var slices = [MachOSlice]()
        for index in 0 ..< Int(count) {
            let entry = 8 + index * (is64 ? 32 : 20)
            var arch = try ByteReader(data, start: entry, count: is64 ? 32 : 20)
            try arch.skip(8)
            let offset: UInt64, size: UInt64
            if is64 {
                offset = try arch.bigEndianInteger()
                size = try arch.bigEndianInteger()
            } else {
                offset = try UInt64(arch.bigEndianInteger(UInt32.self))
                size = try UInt64(arch.bigEndianInteger(UInt32.self))
            }
            guard offset <= UInt64(data.count), size <= UInt64(data.count) - offset else {
                throw MachOReadFailure.unreadable
            }
            let start = Int(offset)
            let range = start ..< start + Int(size)
            guard range.count >= headerSize else { continue }
            var head = try ByteReader(data, start: start)
            guard try head.integer(UInt32.self) == machO64Magic else { continue }
            try slices.append(MachOSlice(data, range))
        }
        return slices
    }

    // MARK: Reading one slice

    /// Walks the load commands, checking each against the slice before it is
    /// believed. This is the only place that decides a file is sound; every
    /// accessor below reads within what this recorded.
    private init(_ data: Data, _ range: Range<Int>) throws {
        guard range.count >= headerSize else { throw MachOReadFailure.unreadable }
        self.data = data
        self.range = range

        var header = try ByteReader(data, start: range.lowerBound, count: range.count)
        guard try header.integer(UInt32.self) == machO64Magic else { throw MachOReadFailure.unreadable }
        let cpuType = try Int32(bitPattern: header.integer(UInt32.self))
        let cpuSubtype = try Int32(bitPattern: header.integer(UInt32.self))
        arch = architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype)
        try header.skip(4) // filetype
        let commandCount = try header.integer(UInt32.self)
        let commandsSize = try Int(header.integer(UInt32.self))
        guard commandsSize <= range.count - headerSize,
              commandCount <= 16384, Int(commandCount) * 8 <= commandsSize
        else { throw MachOReadFailure.unreadable }

        var uuid: UUID?
        var textVMAddress: UInt64 = 0
        var textVMSize: UInt64 = 0
        var sections = [Section]()
        var symbolTableCommand: SymbolTableCommand?
        var functionStartsCommand: LinkEditCommand?

        var commands = try ByteReader(data, start: range.lowerBound + headerSize, count: commandsSize)
        for _ in 0 ..< commandCount {
            let commandStart = commands.offset
            guard commands.remaining >= 8 else { throw MachOReadFailure.unreadable }
            let kind = try commands.integer(UInt32.self)
            let size = try Int(commands.integer(UInt32.self))
            guard size >= 8, size % 8 == 0, size <= commandsSize - commandStart else {
                throw MachOReadFailure.unreadable
            }
            var body = try ByteReader(data, start: range.lowerBound + headerSize + commandStart, count: size)
            try body.skip(8)

            switch kind {
            case loadCommandUUID:
                guard size >= 24 else { throw MachOReadFailure.unreadable }
                let field = try body.bytes(16)
                uuid = UUID(uuid: (
                    field[0], field[1], field[2], field[3], field[4], field[5], field[6], field[7],
                    field[8], field[9], field[10], field[11], field[12], field[13], field[14], field[15],
                ))

            case loadCommandSegment64:
                guard size >= 72 else { throw MachOReadFailure.unreadable }
                let name = try body.paddedName(16)
                let vmAddress = try body.integer(UInt64.self)
                let vmSize = try body.integer(UInt64.self)
                let fileOffset = try body.integer(UInt64.self)
                let fileSize = try body.integer(UInt64.self)
                guard fileOffset <= UInt64(range.count), fileSize <= UInt64(range.count) - fileOffset else {
                    throw MachOReadFailure.unreadable
                }
                try body.skip(8) // maxprot, initprot
                let sectionCount = try Int(body.integer(UInt32.self))
                guard sectionCount <= (size - 72) / sectionSize else { throw MachOReadFailure.unreadable }
                if name == "__TEXT" {
                    textVMAddress = vmAddress
                    textVMSize = vmSize
                }
                try body.skip(4) // flags
                try sections.append(contentsOf: Self.readSections(&body, count: sectionCount))

            case loadCommandSymbolTable:
                guard size >= 24 else { throw MachOReadFailure.unreadable }
                symbolTableCommand = try SymbolTableCommand(
                    symbolOffset: body.integer(),
                    symbolCount: body.integer(),
                    stringOffset: body.integer(),
                    stringSize: body.integer(),
                )

            case loadCommandFunctionStarts:
                guard size >= 16 else { throw MachOReadFailure.unreadable }
                functionStartsCommand = try LinkEditCommand(offset: body.integer(), size: body.integer())

            default:
                break
            }
            try commands.seek(to: commandStart + size)
        }

        self.uuid = uuid
        self.textVMAddress = textVMAddress
        self.textVMSize = textVMSize
        self.sections = sections
        self.symbolTableCommand = symbolTableCommand
        self.functionStartsCommand = functionStartsCommand
    }

    /// The `section_64` array that follows a `segment_command_64`.
    private static func readSections(_ body: inout ByteReader, count: Int) throws -> [Section] {
        var sections = [Section]()
        for _ in 0 ..< count {
            let sectionName = try body.paddedName(16)
            let segmentName = try body.paddedName(16)
            try body.skip(8) // addr
            let size = try body.integer(UInt64.self)
            let offset = try body.integer(UInt32.self)
            try body.skip(12) // align, reloff, nreloc
            let flags = try body.integer(UInt32.self)
            try body.skip(12) // reserved1, reserved2, reserved3
            sections.append(Section(
                segment: segmentName,
                name: sectionName,
                offset: offset,
                size: size,
                hasContents: flags & sectionTypeMask != sectionTypeZeroFill,
            ))
        }
        return sections
    }

    // MARK: What the symbolicator reads

    /// A section's bytes — `__DWARF,__debug_line` and its string sections.
    /// Nil when the section is absent or does not sit inside the slice.
    public func section(segment: String, name: String) -> Data? {
        guard let section = sections.first(where: { $0.segment == segment && $0.name == name }),
              section.hasContents, section.size > 0, section.size <= UInt64(range.count),
              UInt64(section.offset) <= UInt64(range.count) - section.size
        else { return nil }
        return subdata(from: range.lowerBound + Int(section.offset), count: Int(section.size))
    }

    /// `count` bytes at an offset already checked against `range`.
    private func subdata(from offset: Int, count: Int) -> Data {
        let start = data.startIndex + offset
        return data.subdata(in: start ..< start + count)
    }

    /// Every function this slice can name, plus a boundary at every function
    /// start whose name was stripped, so that a frame in a nameless function
    /// comes back nameless instead of wearing its neighbour's name.
    public func symbolTable() -> SymbolTable {
        var entries = [SymbolTable.Entry]()
        entries.reserveCapacity(1024)
        appendSymbols(to: &entries)
        appendFunctionStarts(to: &entries)
        if textVMSize > 0 {
            // Past the end of __TEXT there is no code, so the last function
            // stops here rather than running to infinity.
            entries.append(SymbolTable.Entry(offset: textVMSize, name: nil))
        }
        return SymbolTable(entries: entries)
    }

    private func appendSymbols(to entries: inout [SymbolTable.Entry]) {
        guard let symbolTableCommand else { return }
        let symbolBytes = Int(symbolTableCommand.symbolCount) * nlist64Size
        guard Int(symbolTableCommand.symbolOffset) <= range.count,
              symbolBytes <= range.count - Int(symbolTableCommand.symbolOffset),
              Int(symbolTableCommand.stringOffset) <= range.count,
              Int(symbolTableCommand.stringSize) <= range.count - Int(symbolTableCommand.stringOffset),
              var symbols = try? ByteReader(
                  data,
                  start: range.lowerBound + Int(symbolTableCommand.symbolOffset),
                  count: symbolBytes,
              ),
              let strings = try? ByteReader(
                  data,
                  start: range.lowerBound + Int(symbolTableCommand.stringOffset),
                  count: Int(symbolTableCommand.stringSize),
              )
        else { return }

        for _ in 0 ..< Int(symbolTableCommand.symbolCount) {
            guard let nameIndex = try? symbols.integer(UInt32.self),
                  let type = try? symbols.byte(),
                  let sectionNumber = try? symbols.byte(),
                  (try? symbols.skip(2)) != nil,
                  let value = try? symbols.integer(UInt64.self)
            else { return }
            // Debug map entries (N_STAB) describe the source, not the code, and
            // anything that is not defined in a section of this file has no
            // address here.
            guard type & symbolStabMask == 0, type & symbolTypeMask == symbolTypeSection,
                  sectionNumber != 0, value >= textVMAddress
            else { continue }
            var name = strings
            guard (try? name.seek(to: Int(nameIndex))) != nil,
                  let text = try? name.cString(), !text.isEmpty
            else { continue }
            entries.append(SymbolTable.Entry(offset: value - textVMAddress, name: text))
        }
    }

    private func appendFunctionStarts(to entries: inout [SymbolTable.Entry]) {
        guard let functionStartsCommand,
              Int(functionStartsCommand.offset) <= range.count,
              Int(functionStartsCommand.size) <= range.count - Int(functionStartsCommand.offset),
              var reader = try? ByteReader(
                  data,
                  start: range.lowerBound + Int(functionStartsCommand.offset),
                  count: Int(functionStartsCommand.size),
              )
        else { return }

        var address = textVMAddress
        while !reader.isAtEnd {
            guard let delta = try? reader.unsignedLEB() else { return }
            // The table is padded to a multiple of the pointer size with zeros,
            // and a zero delta would otherwise repeat the last function forever.
            guard delta > 0 else { return }
            address &+= delta
            guard address >= textVMAddress else { return }
            entries.append(SymbolTable.Entry(offset: address - textVMAddress, name: nil))
        }
    }
}

// MARK: Constants

// Spelled out rather than taken from `<mach-o/loader.h>`: these values are part
// of the file format this parser reads, not of whatever the host defines.

private let machO64Magic: UInt32 = 0xFEED_FACF
private let machO32Magic: UInt32 = 0xFEED_FACE
private let machO64SwappedMagic: UInt32 = 0xCFFA_EDFE
private let machO32SwappedMagic: UInt32 = 0xCEFA_EDFE
/// `FAT_CIGAM`: the fat header is big-endian, so on a little-endian host the
/// magic reads back swapped.
private let fatMagic: UInt32 = 0xBEBA_FECA
private let fat64Magic: UInt32 = 0xBFBA_FECA

private let headerSize = 32
private let sectionSize = 80
let nlist64Size = 16

private let loadCommandSegment64: UInt32 = 0x19
private let loadCommandSymbolTable: UInt32 = 0x02
private let loadCommandUUID: UInt32 = 0x1B
private let loadCommandFunctionStarts: UInt32 = 0x26

private let sectionTypeMask: UInt32 = 0xFF
private let sectionTypeZeroFill: UInt32 = 0x01

let symbolStabMask: UInt8 = 0xE0
let symbolTypeMask: UInt8 = 0x0E
let symbolTypeSection: UInt8 = 0x0E

/// The name `lipo` prints. `NXGetArchInfoFromCpuType` does not exist on iOS,
/// and only the architectures this app can meet are worth naming.
private func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
    switch (cpuType, cpuSubtype & 0x00FF_FFFF) {
    case (0x0100_000C, 2): "arm64e"
    case (0x0100_000C, _): "arm64"
    case (0x0200_000C, _): "arm64_32"
    case (0x0100_0007, 8): "x86_64h"
    case (0x0100_0007, _): "x86_64"
    default: "cputype \(cpuType)"
    }
}

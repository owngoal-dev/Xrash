import XCTest
@testable import XrashSymbols

final class DWARFLineTableTests: XCTestCase {
    private func fixtureTable() throws -> DWARFLineTable {
        let slice = try XCTUnwrap(MachOSlice.slice(of: Fixture.data(of: Fixture.dsymBinary), uuid: Fixture.uuid))
        return try DWARFLineTable(
            debugLine: XCTUnwrap(slice.section(segment: "__DWARF", name: "__debug_line")),
            debugLineStr: slice.section(segment: "__DWARF", name: "__debug_line_str"),
            debugStr: slice.section(segment: "__DWARF", name: "__debug_str"),
        )
    }

    func testFindsTheLineEachAddressIsOn() throws {
        let table = try fixtureTable()
        // What `dwarfdump --debug-line` prints for this dSYM.
        for (address, line) in [
            (Fixture.insideGamma, Fixture.gammaLine),
            (Fixture.insideBeta, Fixture.betaLine),
            (Fixture.insideStripped, Fixture.strippedLine),
            (Fixture.insideAlpha, Fixture.alphaLine),
        ] {
            let location = try XCTUnwrap(table.lookup(address: address), "no line for \(address)")
            XCTAssertEqual(location.line, line)
            XCTAssertTrue(location.file.hasSuffix("fixture.c"), location.file)
        }
    }

    func testAnAddressOutsideEverySequenceHasNoLine() throws {
        let table = try fixtureTable()
        XCTAssertNil(table.lookup(address: 0))
        XCTAssertNil(table.lookup(address: 0x1000))
        XCTAssertNil(table.lookup(address: .max))
    }

    func testATruncatedLineProgramIsSkippedRatherThanTrapped() throws {
        let slice = try XCTUnwrap(MachOSlice.slice(of: Fixture.data(of: Fixture.dsymBinary), uuid: Fixture.uuid))
        let section = try XCTUnwrap(slice.section(segment: "__DWARF", name: "__debug_line"))
        for length in 0 ... section.count {
            let table = DWARFLineTable(debugLine: section.prefix(length))
            _ = table.lookup(address: Fixture.insideBeta)
        }
    }

    func testACorruptedLineProgramIsSkippedRatherThanTrapped() throws {
        let slice = try XCTUnwrap(MachOSlice.slice(of: Fixture.data(of: Fixture.dsymBinary), uuid: Fixture.uuid))
        let original = try XCTUnwrap(slice.section(segment: "__DWARF", name: "__debug_line"))
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 2000 {
            var section = original
            for _ in 0 ..< 4 {
                let index = Int.random(in: 0 ..< section.count, using: &generator)
                section[section.startIndex + index] = UInt8.random(in: 0 ... 255, using: &generator)
            }
            let table = DWARFLineTable(debugLine: section)
            _ = table.lookup(address: Fixture.insideBeta)
        }
    }

    // MARK: Version 4, which the fixture cannot cover

    /// A version 4 `__debug_line` unit built by hand. The fixture dSYM is
    /// version 5, and the two number their files differently: 5 starts at 0,
    /// 4 starts at 1 and keeps 0 for the unit's own file, which only
    /// `__debug_info` names.
    private func dwarf4Section(setFile: UInt8?) -> Data {
        var header = Data([1, 1, 1, 0xFB, 14, 13]) // min_inst_len … opcode_base, line_base -5
        header.append(contentsOf: [0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1]) // standard_opcode_lengths
        header.append(contentsOf: Array("src".utf8) + [0, 0]) // include_directories[1], then the end
        header.append(contentsOf: Array("one.c".utf8) + [0, 1, 0, 0]) // file 1, in "src"
        header.append(contentsOf: Array("two.c".utf8) + [0, 0, 0, 0]) // file 2, in the compilation dir
        header.append(0) // end of the file table

        var program = Data([0, 9, 2]) // DW_LNE_set_address
        withUnsafeBytes(of: UInt64(0x1000).littleEndian) { program.append(contentsOf: $0) }
        if let setFile {
            program.append(contentsOf: [4, setFile])
        } // DW_LNS_set_file
        program.append(contentsOf: [3, 41]) // DW_LNS_advance_line, line 1 → 42
        program.append(1) // DW_LNS_copy
        program.append(contentsOf: [2, 0x10]) // DW_LNS_advance_pc 16
        program.append(contentsOf: [0, 1, 1]) // DW_LNE_end_sequence

        var unit = Data([4, 0]) // version
        unit.append(littleEndian: UInt32(header.count))
        unit.append(header)
        unit.append(program)

        var section = Data()
        section.append(littleEndian: UInt32(unit.count))
        section.append(unit)
        return section
    }

    func testVersion4NumbersItsFilesFromOne() {
        // Without `set_file` the file register starts at 1, which is "one.c".
        let implied = DWARFLineTable(debugLine: dwarf4Section(setFile: nil))
        XCTAssertEqual(implied.lookup(address: 0x1008), .init(file: "src/one.c", line: 42))

        XCTAssertEqual(
            DWARFLineTable(debugLine: dwarf4Section(setFile: 1)).lookup(address: 0x1000),
            .init(file: "src/one.c", line: 42),
        )
        XCTAssertEqual(
            DWARFLineTable(debugLine: dwarf4Section(setFile: 2)).lookup(address: 0x1000),
            .init(file: "two.c", line: 42),
        )
        // File 0 is the unit's own file, which this table does not carry.
        XCTAssertNil(DWARFLineTable(debugLine: dwarf4Section(setFile: 0)).lookup(address: 0x1000))
        // `end_sequence` bounds the sequence: its own address is past the last row.
        XCTAssertNil(implied.lookup(address: 0x1010))
    }

    func testRandomBytesAreNotALineProgram() {
        var generator = SystemRandomNumberGenerator()
        for count in [0, 1, 4, 5, 64, 4096] {
            let bytes = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
            let table = DWARFLineTable(debugLine: Data(bytes))
            _ = table.lookup(address: 0x1234)
        }
    }
}

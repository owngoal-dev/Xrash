import XCTest
@testable import XrashSymbols

final class MachOSliceTests: XCTestCase {
    func testReadsTheUUIDAndTextAddressOfATheDSYM() throws {
        let slices = try MachOSlice.slices(of: Fixture.data(of: Fixture.dsymBinary))
        XCTAssertEqual(slices.count, 1)
        // What `dwarfdump --uuid` prints for this file.
        XCTAssertEqual(slices.first?.uuid, Fixture.uuid)
        XCTAssertEqual(slices.first?.arch, "arm64")
        XCTAssertEqual(slices.first?.textVMAddress, 0)
    }

    func testFindsTheSliceByUUID() throws {
        let data = try Fixture.data(of: Fixture.dylib)
        XCTAssertNotNil(MachOSlice.slice(of: data, uuid: Fixture.uuid))
        XCTAssertNil(MachOSlice.slice(of: data, uuid: UUID()))
    }

    func testNamesTheFunctionAnOffsetFallsIn() throws {
        let data = try Fixture.data(of: Fixture.dylib)
        let table = try XCTUnwrap(MachOSlice.slice(of: data, uuid: Fixture.uuid)).symbolTable()

        let found = try XCTUnwrap(table.lookup(offset: Fixture.insideBeta))
        XCTAssertEqual(found.name, "_beta")
        XCTAssertEqual(found.startOffset, Fixture.betaStart)
        XCTAssertEqual(Fixture.insideBeta - found.startOffset, 0x10)

        XCTAssertEqual(table.lookup(offset: Fixture.gammaStart)?.name, "_gamma")
        XCTAssertEqual(table.lookup(offset: Fixture.alphaStart)?.name, "_alpha")
    }

    func testAStrippedFunctionDoesNotWearItsNeighboursName() throws {
        let data = try Fixture.data(of: Fixture.dylib)
        let table = try XCTUnwrap(MachOSlice.slice(of: data, uuid: Fixture.uuid)).symbolTable()
        // `stripped` follows `beta` and has no name in the stripped dylib.
        // Without the LC_FUNCTION_STARTS boundary this would answer `_beta`.
        XCTAssertNil(table.lookup(offset: Fixture.insideStripped))
        XCTAssertEqual(table.lookup(offset: Fixture.insideBeta)?.name, "_beta")

        // The dSYM kept the local symbol, so there it has a name.
        let dsym = try XCTUnwrap(MachOSlice.slice(of: Fixture.data(of: Fixture.dsymBinary), uuid: Fixture.uuid))
        XCTAssertEqual(dsym.symbolTable().lookup(offset: Fixture.insideStripped)?.name, "_stripped")
    }

    func testAnOffsetPastTheImageNamesNothing() throws {
        let data = try Fixture.data(of: Fixture.dylib)
        let table = try XCTUnwrap(MachOSlice.slice(of: data, uuid: Fixture.uuid)).symbolTable()
        XCTAssertNil(table.lookup(offset: 0))
        XCTAssertNil(table.lookup(offset: 0x4000))
        XCTAssertNil(table.lookup(offset: .max))
    }

    func testReadsAMachOThatIsASliceOfALargerData() throws {
        // A `Data` handed in from outside can be a slice: `dropFirst` leaves
        // its indices where they were, and every offset in the file is still
        // counted from its own start.
        let original = try Fixture.data(of: Fixture.dsymBinary)
        let padded = Data(repeating: 0xAB, count: 7) + original
        let slice = try XCTUnwrap(MachOSlice.slice(of: padded.dropFirst(7), uuid: Fixture.uuid))
        XCTAssertEqual(slice.bytes, original)
        XCTAssertNotNil(slice.section(segment: "__DWARF", name: "__debug_line"))
        XCTAssertEqual(slice.symbolTable().lookup(offset: Fixture.insideBeta)?.name, "_beta")
    }

    func testReadsASection() throws {
        let slice = try XCTUnwrap(MachOSlice.slice(of: Fixture.data(of: Fixture.dsymBinary), uuid: Fixture.uuid))
        XCTAssertNotNil(slice.section(segment: "__DWARF", name: "__debug_line"))
        XCTAssertNil(slice.section(segment: "__DWARF", name: "__no_such_section"))
    }

    func testSymbolTableSurvivesAnEncodeAndDecode() throws {
        let data = try Fixture.data(of: Fixture.dylib)
        let table = try XCTUnwrap(MachOSlice.slice(of: data, uuid: Fixture.uuid)).symbolTable()
        let decoded = try XCTUnwrap(SymbolTable(data: table.data))
        XCTAssertEqual(decoded.count, table.count)
        XCTAssertEqual(decoded.lookup(offset: Fixture.insideBeta)?.name, "_beta")
        XCTAssertNil(decoded.lookup(offset: Fixture.insideStripped))
        XCTAssertNil(SymbolTable(data: table.data.prefix(20)))
        XCTAssertNil(SymbolTable(data: Data("not a symbol table".utf8)))
    }

    // MARK: Nothing from outside may trap

    func testATruncatedMachOIsRefusedRatherThanTrapped() throws {
        let data = try Fixture.data(of: Fixture.dsymBinary)
        for length in stride(from: 0, to: data.count, by: 7) {
            let slices = (try? MachOSlice.slices(of: data.prefix(length))) ?? []
            for slice in slices {
                // Whatever survived truncation still has to answer without
                // reading past what is there.
                _ = slice.symbolTable()
                _ = slice.section(segment: "__DWARF", name: "__debug_line")
            }
        }
    }

    func testCorruptedHeadersAreRefusedRatherThanTrapped() throws {
        let original = try Fixture.data(of: Fixture.dsymBinary)
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 400 {
            var data = original.prefix(4096)
            // The load commands are what a length field can lie in; corrupt
            // only those, so most rounds still reach the parser.
            for _ in 0 ..< 8 {
                let index = Int.random(in: 4 ..< 2048, using: &generator)
                data[data.startIndex + index] = UInt8.random(in: 0 ... 255, using: &generator)
            }
            for slice in (try? MachOSlice.slices(of: data)) ?? [] {
                _ = slice.symbolTable()
                _ = slice.section(segment: "__DWARF", name: "__debug_line")
            }
        }
    }

    func testGarbageIsNotAMachO() {
        XCTAssertThrowsError(try MachOSlice.slices(of: Data()))
        XCTAssertThrowsError(try MachOSlice.slices(of: Data([0, 1, 2, 3, 4, 5, 6, 7])))
        XCTAssertThrowsError(try MachOSlice.slices(of: Data(repeating: 0xAB, count: 4096)))
    }
}

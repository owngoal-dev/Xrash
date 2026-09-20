// The cases are Fila's (MIT, same owner): FilaFormatsTests/MachOTests.swift and
// MachOInspectionTests.swift, rewritten in XCTest, which is what this harness
// uses. The scratch helpers are Fila's FilaFormatsTests/Scratch.swift.

import Foundation
import XCTest
@testable import XrashSymbols

/// Parsed against the binaries the machine already has. `/bin/ls` is a fat
/// binary on every Mac and a thin one on a device, which is exactly the pair of
/// shapes the parser has to get right, and no fixture reproduces a real code
/// signature.
final class MachOInspectTests: XCTestCase {
    // MARK: Reading

    func testParsesASystemBinary() throws {
        try withDescriptor(reading: URL(fileURLWithPath: "/bin/ls")) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            XCTAssertFalse(image.slices.isEmpty)

            for slice in image.slices {
                XCTAssertEqual(slice.fileType, .executable)
                XCTAssertTrue(slice.isSixtyFourBit)
                XCTAssertFalse(slice.isBigEndian)
                XCTAssertNotNil(slice.uuid)
                XCTAssertTrue(slice.isCodeSigned)
                XCTAssertFalse(slice.isEncrypted)
                XCTAssertTrue(slice.linkedLibraries.contains { $0.hasSuffix("libSystem.B.dylib") })
                XCTAssertNil(slice.installName)
            }
            // Every architecture Apple ships is named, never numbered.
            XCTAssertTrue(image.slices.allSatisfy { !$0.architecture.hasPrefix("cputype") })
        }
    }

    func testReadsEntitlementsOutOfTheCodeSignature() throws {
        let url = URL(fileURLWithPath: "/usr/libexec/lsd")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        try withDescriptor(reading: url) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            let slice = try XCTUnwrap(image.slices.first)
            let plist = try XCTUnwrap(image.entitlements(of: slice))
            let claims = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            XCTAssertFalse(try XCTUnwrap(claims).isEmpty)
        }
    }

    /// An ad-hoc `ldid` signature with no entitlements is the normal state of
    /// half the binaries on a custom firmware device, and not an error.
    func testABinaryWithNoEntitlementsIsNilRatherThanAFailure() throws {
        try withDescriptor(reading: URL(fileURLWithPath: "/bin/ls")) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            for slice in image.slices {
                XCTAssertNil(try image.entitlements(of: slice))
            }
        }
    }

    func testAnythingThatIsNotAMachOIsNotRecognised() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("text.txt")
            try Data("this is not a binary".utf8).write(to: url)
            try withDescriptor(reading: url) { descriptor in
                XCTAssertThrowsError(try MachOImage(descriptor: descriptor)) { error in
                    XCTAssertEqual(error as? FormatFailure, .notRecognised)
                }
            }
        }
    }

    // MARK: Inspecting

    func testInspectsRealSegmentsCommandsAndBuildVersions() throws {
        try withDescriptor(reading: URL(fileURLWithPath: "/bin/ls")) { descriptor in
            let image = try MachOImage(descriptor: descriptor)
            for slice in image.slices {
                let details = try image.inspect(slice)
                XCTAssertTrue(details.loadCommands.contains { $0.hasPrefix("LC_SEGMENT_64") })
                XCTAssertTrue(details.segments.contains { $0.name == "__TEXT" && $0.protections.contains("x") })
                XCTAssertTrue(details.segments.flatMap(\.sections).contains("__text"))
                XCTAssertNotNil(details.minimumOS)
                XCTAssertNotNil(details.sdk)
                XCTAssertNotNil(details.signingIdentifier)
            }
        }
    }

    /// The whole point of reading through a descriptor: no path is reopened, so
    /// a binary replaced by an update mid-read still inspects.
    func testAnOpenDescriptorRemainsTheSourceAfterThePathnameDisappears() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("image")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: url)
            try withDescriptor(reading: url) { descriptor in
                try FileManager.default.removeItem(at: url)
                let image = try MachOImage(descriptor: descriptor)
                let slice = try XCTUnwrap(image.slices.first)
                XCTAssertFalse(try image.inspect(slice).segments.isEmpty)
            }
        }
    }

    func testInspectionDoesNotReadOrAllocateALargeSparsePayload() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("sparse-image")
            // A valid empty 64-bit object header; the remainder has no commands
            // or signature and is deliberately a sparse four-gigabyte extent.
            try Self.words([0xFEED_FACF, 0x0100_000C, 0, 1, 0, 0, 0, 0]).write(to: url)
            let descriptor = open(url.path, O_RDWR)
            defer {
                if descriptor >= 0 {
                    close(descriptor)
                }
            }
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(ftruncate(descriptor, 4 * 1024 * 1024 * 1024), 0)
            let image = try MachOImage(descriptor: descriptor)
            let slice = try XCTUnwrap(image.slices.first)
            let details = try image.inspect(slice)
            XCTAssertEqual(slice.byteCount, 4 * 1024 * 1024 * 1024)
            XCTAssertTrue(details.loadCommands.isEmpty)
            XCTAssertTrue(details.segments.isEmpty)
        }
    }

    func testTruncatedHeadersAndCommandRegionsReturnErrors() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("truncated")
            for bytes in [Self.words([0xFEED_FACF, 0x0100_000C, 0, 1, 1, 24, 0, 0]),
                          Self.words([0xFEED_FACF, 0x0100_000C, 0, 1, 0, 0, 0])]
            {
                try bytes.write(to: url)
                try withDescriptor(reading: url) { descriptor in
                    XCTAssertThrowsError(try MachOImage(descriptor: descriptor)) { error in
                        XCTAssertTrue(error is FormatFailure)
                    }
                }
            }
        }
    }

    /// MachOKit's legacy accessor repeats the minimum version; the adapter reads
    /// the actual SDK word, and a big-endian file is where the two diverge.
    func testBigEndianCommandDecodingPreservesDistinctMinimumAndSDKVersions() throws {
        try withScratch { scratch in
            let url = scratch.appendingPathComponent("big-endian-object")
            let values: [UInt32] = [0xFEED_FACE, 18, 0, 1, 1, 16, 0,
                                    0x24, 16, 0x000A_0900, 0x000A_0A00]
            let data = values.reduce(into: Data()) { data, value in
                var big = value.bigEndian
                withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
            }
            try data.write(to: url)
            try withDescriptor(reading: url) { descriptor in
                let image = try MachOImage(descriptor: descriptor)
                let slice = try XCTUnwrap(image.slices.first)
                XCTAssertTrue(slice.isBigEndian)
                let details = try image.inspect(slice)
                XCTAssertEqual(details.platform, "macOS")
                XCTAssertEqual(details.minimumOS, "10.9.0")
                XCTAssertEqual(details.sdk, "10.10.0")
            }
        }
    }

    private static func words(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
    }
}

// MARK: Scratch

/// Every test here runs against a real directory and real descriptors. That is
/// the point: this reader exists to work on a descriptor the daemon opened, it
/// is built on `pread`, and a fake in front of it would prove nothing about the
/// one thing that can go wrong.
private func withScratch(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xrash-macho-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private struct OpenFailed: Error {
    var path: String
    var code: Int32
}

/// Runs `body` with a descriptor on `url` and closes it afterwards, which is
/// what keeps a failing expectation from leaking one into the next test.
@discardableResult
private func withDescriptor<Result>(reading url: URL, _ body: (Int32) throws -> Result) throws -> Result {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw OpenFailed(path: url.path, code: errno) }
    defer { close(descriptor) }
    return try body(descriptor)
}

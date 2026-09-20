import Foundation
import XCTest

/// What `Fixtures/build.sh` produced, written down. A rebuild moves all of it,
/// which is why the script says so and why it is not run from the tests.
enum Fixture {
    static let uuid = UUID(uuidString: "318825C4-F827-3443-831E-F5F983D15001")!

    /// Offsets from the start of the image — `__TEXT` sits at vmaddr 0 in a
    /// dylib, so these are also the addresses the DWARF uses.
    static let gammaStart: UInt64 = 0x2D0
    static let betaStart: UInt64 = 0x2EC
    /// `stripped`: named in the dSYM, nameless in the dylib, and between two
    /// functions that are named in both.
    static let strippedStart: UInt64 = 0x318
    static let alphaStart: UInt64 = 0x330

    /// Addresses inside the body of each, and the line each is on.
    static let insideGamma: UInt64 = 0x2D8, gammaLine = 10
    static let insideBeta: UInt64 = 0x2FC, betaLine = 18
    static let insideStripped: UInt64 = 0x320, strippedLine = 14
    static let insideAlpha: UInt64 = 0x340, alphaLine = 22

    static var directory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    /// The stripped dylib: the shape of a binary found on a device.
    static var dylib: URL {
        directory.appendingPathComponent("fixture.dylib")
    }

    /// The dSYM bundle, as it would be dropped on the app.
    static var dsymBundle: URL {
        directory.appendingPathComponent("fixture.dylib.dSYM")
    }

    /// The DWARF Mach-O inside the bundle.
    static var dsymBinary: URL {
        dsymBundle.appendingPathComponent("Contents/Resources/DWARF/fixture.dylib")
    }

    static func data(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Somewhere a `@Sendable` progress block can write without the compiler
    /// objecting to a captured `var`.
    final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = [Value]()

        func record(_ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(value)
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// A scratch directory that goes away with the test.
    static func temporaryDirectory(_ test: XCTestCase) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xrash-symbols-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

import XCTest
@testable import XrashSymbols

final class DemanglerTests: XCTestCase {
    func testDemanglesSwift() {
        XCTAssertTrue(Demangler.demangle("$s4main3fooyyF").contains("foo"))
        XCTAssertTrue(Demangler.demangle("_$s4main3fooyyF").contains("foo"))
    }

    func testDemanglesCXX() {
        XCTAssertEqual(Demangler.demangle("_ZN3foo3barEv"), "foo::bar()")
        XCTAssertEqual(Demangler.demangle("__ZN3foo3barEv"), "foo::bar()")
    }

    func testDropsTheLinkersUnderscoreFromACName() {
        XCTAssertEqual(Demangler.demangle("_abort"), "abort")
        // Two underscores are the name's own.
        XCTAssertEqual(Demangler.demangle("__mh_execute_header"), "__mh_execute_header")
    }

    /// `__cxa_demangle` recurses per pointer level; this one would overflow
    /// the stack rather than fail the assertion.
    func testLeavesANameTooLongToBeRealAlone() {
        let hostile = "_Z1f" + String(repeating: "P", count: 1_000_000) + "i"
        XCTAssertEqual(Demangler.demangle(hostile), hostile)
    }

    func testLeavesAnythingElseAlone() {
        XCTAssertEqual(Demangler.demangle(""), "")
        XCTAssertEqual(Demangler.demangle("main"), "main")
        XCTAssertEqual(Demangler.demangle("-[NSString length]"), "-[NSString length]")
        // A prefix that promises a mangled name and then is not one: the
        // demangler declines and the name is left as it reads.
        XCTAssertEqual(Demangler.demangle("$s"), "$s")
        XCTAssertEqual(Demangler.demangle("_Z"), "Z")
    }
}

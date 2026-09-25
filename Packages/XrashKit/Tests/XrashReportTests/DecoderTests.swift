import XCTest
@testable import XrashReport

final class DecoderTests: XCTestCase {
    // MARK: Header and enrichment

    func testHeaderFromPrefix() throws {
        let header = try XCTUnwrap(ReportDecoder.header(fromPrefix: Fixture.data(Fixture.fila)))
        XCTAssertEqual(header.bugType, "309")
        XCTAssertEqual(header.appName, "Fila")
        XCTAssertEqual(header.name, "Fila")
        XCTAssertEqual(header.bundleID, "wiki.qaq.fila")
        XCTAssertEqual(header.appVersion, "0.3.8")
        XCTAssertEqual(header.buildVersion, "62")
        XCTAssertEqual(header.osVersion, "iPhone OS 26.6.1 (23G83)")
        XCTAssertEqual(header.incidentID, "AAAAAAAA-0000-0000-0000-000000000001")
        XCTAssertEqual(header.isFirstParty, true)
        XCTAssertNotNil(header.timestamp)
    }

    /// A command line tool writes `"app_version": ""` — an empty string is an
    /// absent field, not a version.
    func testHeaderTreatsEmptyStringsAsAbsent() throws {
        let header = try XCTUnwrap(ReportDecoder.header(fromPrefix: Fixture.data(Fixture.sudo)))
        XCTAssertNil(header.appVersion)
        XCTAssertNil(header.bundleID)
        XCTAssertEqual(header.appName, "sudo")
    }

    func testHeaderRefusesNonHeaders() {
        XCTAssertNil(ReportDecoder.header(fromPrefix: Data()))
        XCTAssertNil(ReportDecoder.header(fromPrefix: Data("not json at all\n{}".utf8)))
        XCTAssertNil(ReportDecoder.header(fromPrefix: Data(#"{"name":"Fila"}"#.utf8)))
    }

    func testEnrichSeparatesAppFromService() throws {
        let app = try enriched(Fixture.fila, executablePath: nil)
        XCTAssertEqual(app.kind, .crash)
        XCTAssertEqual(app.group, .app)
        XCTAssertEqual(app.processName, "Fila")
        XCTAssertEqual(app.appVersion, "0.3.8 (62)")

        let service = try enriched(Fixture.sudo, executablePath: nil)
        XCTAssertEqual(service.group, .service)
        XCTAssertNil(service.bundleID)

        // The executable's path is the better answer when the caller has it.
        XCTAssertEqual(try enriched(Fixture.fila, executablePath: "/usr/libexec/xrashd").group, .service)
        XCTAssertEqual(try enriched(Fixture.sudo, executablePath: "/Applications/Sudo.app/Sudo").group, .app)
        XCTAssertEqual(try enriched(Fixture.jetsam, executablePath: nil).group, .jetsam)
        XCTAssertEqual(try enriched(Fixture.siri, executablePath: nil).group, .other)
    }

    func testEnrichKeepsDaemonsOutOfTheAppSection() {
        var header = ReportHeader(bugType: "309")
        header.bundleID = "com.apple.backboardd"
        header.name = "backboardd"
        let row = ReportDecoder.enrich(summary(), header: header, executablePath: nil)
        XCTAssertEqual(row.group, .service)
    }

    // MARK: A real crash

    func testDecodeCrash() throws {
        let report = try decode(Fixture.fila)
        XCTAssertEqual(report.kind, .crash)
        let crash = try XCTUnwrap(report.crash)

        XCTAssertEqual(crash.process.name, "Fila")
        XCTAssertEqual(crash.process.bundleID, "wiki.qaq.fila")
        XCTAssertEqual(crash.process.version, "0.3.8")
        XCTAssertEqual(crash.process.pid, 2400)
        XCTAssertEqual(crash.process.parentName, "launchd")
        XCTAssertEqual(crash.process.userID, 501)
        XCTAssertEqual(crash.device.model, "iPhone99,11")
        XCTAssertEqual(crash.device.osBuild, "23G83")
        XCTAssertNotNil(crash.device.captureDate)
        XCTAssertEqual(crash.exception?.type, "EXC_CRASH")
        XCTAssertEqual(crash.exception?.signal, "SIGABRT")
        XCTAssertEqual(crash.termination?.namespace, "SIGNAL")
        XCTAssertEqual(crash.termination?.code, 6)
        XCTAssertEqual(crash.applicationInfo, ["libsystem_c.dylib: abort() called"])
        XCTAssertEqual(crash.faultingThreadIndex, 0)
        XCTAssertEqual(crash.threads.count, 3)
        XCTAssertEqual(crash.threads[0].queue, "com.apple.uikit.datasource.diffing")
        XCTAssertEqual(crash.threads[2].name, "com.apple.uikit.eventfetch-thread")
        XCTAssertTrue(crash.threads[0].isTriggered)
        XCTAssertEqual(crash.vmSummary?.hasPrefix("ReadOnly portion"), true)
        XCTAssertEqual(crash.sharedCache?.uuid, "124D4201-4AAF-32FA-B2A9-A1EC2AE76618")
    }

    /// `address = images[imageIndex].base + imageOffset` — and for the top
    /// frame of the faulting thread that has to land on `pc`.
    func testFrameAddressMath() throws {
        let crash = try XCTUnwrap(decode(Fixture.fila).crash)
        let frame = crash.threads[0].frames[0]
        XCTAssertEqual(frame.imageIndex, 4)
        XCTAssertEqual(frame.imageOffset, 45520)
        XCTAssertEqual(crash.images[4].base, 9_573_183_488)
        XCTAssertEqual(frame.address, 9_573_183_488 + 45520)
        XCTAssertEqual(frame.symbol, "__pthread_kill")
        XCTAssertEqual(frame.symbolSource, .report)

        let pc = try XCTUnwrap(crash.threads[0].registers.first { $0.name == "pc" })
        XCTAssertEqual(pc.value, frame.address)

        // A frame Apple could not name keeps its offset and gains no source.
        let unnamed = crash.lastExceptionBacktrace[4]
        XCTAssertNil(unnamed.symbol)
        XCTAssertNil(unnamed.symbolSource)
        XCTAssertEqual(unnamed.imageIndex, 10)
    }

    func testRegisterOrderAndWideValues() throws {
        let crash = try XCTUnwrap(decode(Fixture.fila).crash)
        let names = crash.threads[0].registers.map(\.name)
        XCTAssertEqual(Array(names.prefix(3)), ["x0", "x1", "x2"])
        XCTAssertEqual(Array(names.suffix(7)), ["fp", "lr", "sp", "pc", "cpsr", "far", "esr"])
        XCTAssertEqual(names.count, 36)
        // x7 is above Int64.max; reading it through Int would have wrapped.
        XCTAssertEqual(crash.threads[0].registers[7].value, 18_446_726_482_597_246_976)
        XCTAssertGreaterThan(crash.threads[0].registers[7].value, UInt64(Int64.max))
    }

    func testImagesAreUppercasedAndTolerateMissingFields() throws {
        let crash = try XCTUnwrap(decode(Fixture.fila).crash)
        XCTAssertEqual(crash.images.count, 15)
        XCTAssertEqual(crash.images[4].uuid, "18665B3F-6D51-33AB-B9E9-63062200EC42")
        XCTAssertEqual(crash.images[4].name, "libsystem_kernel.dylib")
        // Index 13 is the placeholder image: no path, no name, no arch.
        XCTAssertEqual(crash.images[13].name, "")
        XCTAssertEqual(crash.images[13].path, "")
        XCTAssertNil(crash.images[13].arch)
    }

    func testDecodeServiceCrashWithoutBundle() throws {
        let crash = try XCTUnwrap(decode(Fixture.sudo).crash)
        XCTAssertNil(crash.process.bundleID)
        XCTAssertEqual(crash.process.userID, 0)
        XCTAssertEqual(crash.applicationInfo, [])
        XCTAssertTrue(crash.lastExceptionBacktrace.isEmpty)
        XCTAssertEqual(crash.threads[0].frames.last?.symbol, "start")
    }

    // MARK: The other kinds

    func testDecodeJetsam() throws {
        let report = try decode(Fixture.jetsam)
        XCTAssertEqual(report.kind, .jetsam)
        let jetsam = try XCTUnwrap(report.jetsam)
        XCTAssertEqual(jetsam.pageSize, 16384)
        XCTAssertEqual(jetsam.largestProcess, "Fila")
        XCTAssertEqual(jetsam.processes.count, 3)
        XCTAssertEqual(jetsam.processes[0].name, "Fila")
        XCTAssertEqual(jetsam.processes[0].residentPages, 47000)
        XCTAssertEqual(jetsam.processes[0].reason, "per-process-limit")
        XCTAssertEqual(jetsam.processes[0].states, ["frontmost"])
        XCTAssertNil(report.crash)
    }

    func testDecodePanic() throws {
        let report = try decode(Fixture.panic)
        XCTAssertEqual(report.kind, .panic)
        let panic = try XCTUnwrap(report.panic)
        XCTAssertTrue(panic.panicString.hasPrefix("panic(cpu 3 caller"))
        XCTAssertEqual(panic.product, "iPhone99,11")
        XCTAssertNil(report.crash)
    }

    /// Analytics payloads are a header plus whatever the agent felt like
    /// writing — sometimes several objects on several lines. Keeping the text
    /// is the whole job.
    func testDecodeAnalytics() throws {
        for name in [Fixture.siri, Fixture.census] {
            let report = try decode(name)
            XCTAssertEqual(report.kind, .analytics, name)
            XCTAssertNil(report.crash, name)
            XCTAssertFalse(report.rawText.isEmpty, name)
        }
        XCTAssertEqual(try decode(Fixture.census).header.bugType, "211")
        XCTAssertEqual(try decode(Fixture.siri).header.bugType, "313")
    }

    // MARK: The legacy text format

    func testDecodeLegacyCrash() throws {
        let report = try decode(Fixture.legacy)
        XCTAssertEqual(report.kind, .crash)
        let crash = try XCTUnwrap(report.crash)

        XCTAssertEqual(crash.process.name, "Crasher")
        XCTAssertEqual(crash.process.pid, 412)
        XCTAssertEqual(crash.process.bundleID, "wiki.qaq.crasher")
        XCTAssertEqual(crash.process.version, "1.4")
        XCTAssertEqual(crash.process.build, "17")
        XCTAssertEqual(crash.process.cpuType, "ARM-64")
        XCTAssertEqual(crash.process.parentName, "launchd")
        XCTAssertEqual(crash.device.model, "iPhone8,1")
        XCTAssertEqual(crash.device.osTrain, "iPhone OS 15.0")
        XCTAssertEqual(crash.device.osBuild, "19A346")
        XCTAssertNotNil(crash.device.captureDate)

        XCTAssertEqual(crash.exception?.type, "EXC_BAD_ACCESS")
        XCTAssertEqual(crash.exception?.signal, "SIGSEGV")
        XCTAssertEqual(crash.exception?.subtype, "KERN_INVALID_ADDRESS at 0x0000000000000010")
        XCTAssertEqual(crash.termination?.namespace, "SIGNAL")
        XCTAssertEqual(crash.termination?.code, 11)
        XCTAssertEqual(crash.termination?.byProcess, "exc handler")

        XCTAssertEqual(crash.faultingThreadIndex, 0)
        XCTAssertEqual(crash.threads.count, 2)
        XCTAssertTrue(crash.threads[0].isTriggered)
        XCTAssertEqual(crash.threads[0].queue, "com.apple.main-thread")
        XCTAssertEqual(crash.threads[0].frames.count, 4)

        // imageIndex comes from the containing range, imageOffset from the base.
        let top = crash.threads[0].frames[0]
        XCTAssertEqual(top.imageIndex, 0)
        XCTAssertEqual(top.address, 0x1_0008_8410)
        XCTAssertEqual(top.imageOffset, 0x8410)
        XCTAssertEqual(top.symbol, "-[RootViewController tapped:]")
        XCTAssertEqual(top.symbolLocation, 84)

        // "0x1a4000000 + 16644" is an address, not a symbol.
        let unsymbolicated = crash.threads[0].frames[2]
        XCTAssertNil(unsymbolicated.symbol)
        XCTAssertEqual(unsymbolicated.imageIndex, 2)
        XCTAssertEqual(unsymbolicated.imageOffset, 16644)

        XCTAssertEqual(crash.images.count, 4)
        XCTAssertEqual(crash.images[0].uuid, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(crash.images[0].arch, "arm64")
        XCTAssertEqual(crash.images[0].name, "Crasher")
        XCTAssertEqual(crash.images[0].size, 0x28000)

        let registers = crash.threads[0].registers.map(\.name)
        XCTAssertEqual(Array(registers.prefix(2)), ["x0", "x1"])
        XCTAssertTrue(registers.contains("far"))
        XCTAssertTrue(registers.contains("esr"))
        XCTAssertEqual(crash.threads[0].registers.first { $0.name == "pc" }?.value, 0x1_0008_8410)

        XCTAssertEqual(report.header.bundleID, "wiki.qaq.crasher")
        XCTAssertEqual(report.header.appVersion, "1.4")
    }

    /// Not every tool writes "Triggered by Thread:", and one that writes a
    /// number past the last thread has written nonsense.
    func testLegacyFaultingThreadComesFromWhicheverTheFileSays() throws {
        let marked = """
        Process:         Crasher [412]
        Exception Type:  EXC_BAD_ACCESS (SIGSEGV)

        Thread 0:
        0   Crasher   0x0000000100088410 main + 4

        Thread 1 Crashed:
        0   Crasher   0x0000000100088420 boom + 8
        """
        XCTAssertEqual(try legacy(marked).faultingThreadIndex, 1)

        let impossible = """
        Process:         Crasher [412]
        Exception Type:  EXC_CRASH (SIGABRT)
        Triggered by Thread:  9

        Thread 0:
        0   Crasher   0x0000000100088410 main + 4
        """
        XCTAssertNil(try legacy(impossible).faultingThreadIndex)
    }

    /// The line patterns go quadratic on a run of spaces; a line no reporter
    /// would write is skipped rather than matched, and the rest still decodes.
    func testLegacyLineTooLongToBeRealIsSkipped() throws {
        let hostile = """
        Process:         a\(String(repeating: " ", count: 200_000))b [1]
        Exception Type:  EXC_CRASH (SIGABRT)

        Thread 0 Crashed:
        0   Crasher   0x0000000100088410 main + 4
        """
        let started = Date()
        XCTAssertEqual(try legacy(hostile).faultingThreadIndex, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A DYLD kill splits its explanation across two keys; both print as
    /// Termination Description, and the footnote comes last.
    func testTerminationDetailsFollowTheReasons() {
        let crash = CrashBodyDecoder.decode(["termination": [
            "namespace": "DYLD",
            "reasons": ["Library not loaded: /usr/lib/libfoo.dylib"],
            "details": ["(terminated at launch; ignore backtrace)"],
        ]])
        XCTAssertEqual(crash.termination?.reasons, [
            "Library not loaded: /usr/lib/libfoo.dylib",
            "(terminated at launch; ignore backtrace)",
        ])
    }

    // MARK: Nothing traps

    /// A base or a size may exceed `Int64.max`; a negative one is a corrupt
    /// field, not an address a byte below the top of the space.
    func testNegativeNumbersAreNotAddresses() throws {
        let json = #"{"base": -1, "wide": 18446726482597246976, "size": 4096, "half": 40.5}"#
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
        )
        XCTAssertNil(body.uint64("base"))
        XCTAssertEqual(body.uint64("wide"), 18_446_726_482_597_246_976)
        XCTAssertEqual(body.uint64("size"), 4096)
        XCTAssertEqual(body.uint64("half"), 40)
    }

    func testEmptyAndBinaryInputAreRefused() {
        XCTAssertThrowsError(try ReportDecoder.decode(Data(), fileName: "x.ips")) {
            XCTAssertEqual($0 as? ReportDecodingError, .unreadable)
        }
        XCTAssertThrowsError(try ReportDecoder.decode(Data("   \n\n ".utf8), fileName: "x.ips")) {
            XCTAssertEqual($0 as? ReportDecodingError, .unreadable)
        }
        XCTAssertThrowsError(try ReportDecoder.decode(Data([0, 1, 2, 3, 0, 0xFF]), fileName: "x.ips")) {
            XCTAssertEqual($0 as? ReportDecodingError, .unreadable)
        }
    }

    func testGarbageDecodesAsText() throws {
        let report = try ReportDecoder.decode(Data("hello, not a report at all".utf8), fileName: "x.log")
        XCTAssertEqual(report.kind, .other)
        XCTAssertNil(report.crash)
        XCTAssertEqual(report.rawText, "hello, not a report at all")
    }

    /// Every truncation of a real report, plus a few corrupted ones. The point
    /// is that none of them trap: a report arrives as a file descriptor from a
    /// daemon that never looked inside it.
    func testTruncationsNeverTrap() throws {
        let data = try Fixture.data(Fixture.fila)
        for cut in stride(from: 0, to: data.count, by: max(1, data.count / 400)) {
            _ = try? ReportDecoder.decode(data.prefix(cut), fileName: Fixture.fila)
        }
        var corrupted = data
        for offset in stride(from: 0, to: corrupted.count, by: 97) {
            corrupted[corrupted.startIndex + offset] = UInt8(ascii: "}")
        }
        _ = try? ReportDecoder.decode(corrupted, fileName: Fixture.fila)

        // A header with a body that is not JSON keeps the header and the text.
        let headerOnly = try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\n")[0]
        let report = try ReportDecoder.decode(Data("\(headerOnly)\nnot json".utf8), fileName: Fixture.fila)
        XCTAssertEqual(report.kind, .crash)
        XCTAssertNil(report.crash)
        XCTAssertTrue(report.rawText.hasSuffix("not json"))
    }

    // MARK: Text bodies

    /// A Microstackshots report is a JSON header over text, and the text says
    /// which limit was crossed.
    func testResourceReportNamesItsEvent() throws {
        let report = try decode(Fixture.diskWrites)
        XCTAssertEqual(report.kind, .resource)
        XCTAssertNil(report.crash)
        XCTAssertEqual(report.resource?.event, "disk writes")
        XCTAssertEqual(report.reason, "disk writes")
    }

    func testBasebinException() throws {
        let report = try decode(Fixture.basebinException)
        XCTAssertEqual(report.kind, .crash)
        XCTAssertEqual(report.header.name, "launchd")
        XCTAssertEqual(report.header.osVersion, "18.7.1 (22H31)")
        XCTAssertNotNil(report.header.timestamp)
        XCTAssertEqual(report.reason, "EXC_BAD_ACCESS")

        let crash = try XCTUnwrap(report.crash)
        XCTAssertEqual(crash.process.name, "launchd")
        XCTAssertEqual(crash.process.pid, 1)
        XCTAssertEqual(crash.process.path, "/sbin/launchd")
        XCTAssertEqual(crash.device.model, "iPhone11,8")
        XCTAssertEqual(crash.exception?.codes, "0x0000000000000001, 0x0000000000000008")
        XCTAssertEqual(crash.exception?.subtype, "KERN_INVALID_ADDRESS at 0x0000000000000008")

        let thread = try XCTUnwrap(crash.faultingThread)
        XCTAssertEqual(thread.id, 13482)
        XCTAssertEqual(thread.registers.count, 36)
        XCTAssertEqual(thread.registers.first?.name, "x0")
        // The stripped program counter, not the signed one.
        XCTAssertEqual(thread.registers.first { $0.name == "pc" }?.value, 0x1_0309_7BBC)

        // The signed return address is dropped for its stripped repeat.
        XCTAssertEqual(thread.frames.count, 6)
        XCTAssertEqual(thread.frames[0].symbol, "crashreporter_test_bad_access")
        XCTAssertEqual(thread.frames[0].symbolLocation, 0x2C)
        XCTAssertEqual(crash.images.image(for: thread.frames[0])?.name, "libjailbreak.dylib")
        XCTAssertEqual(thread.frames[0].imageOffset, 0x2BBBC)
        XCTAssertNil(thread.frames[3].symbol)
        XCTAssertEqual(crash.images.image(for: thread.frames[3])?.path, "/sbin/launchd")
    }

    func testBasebinSignal() throws {
        let report = try decode(Fixture.basebinSignal)
        XCTAssertEqual(report.reason, "SIGABRT")
        let crash = try XCTUnwrap(report.crash)
        let thread = try XCTUnwrap(crash.faultingThread)
        XCTAssertEqual(thread.frames.map(\.address), [0x1_EBED_81DC, 0x2_2551_3C1C])
        XCTAssertEqual(crash.images.image(for: thread.frames[0])?.name, "libsystem_kernel.dylib")
        XCTAssertEqual(crash.images.image(for: thread.frames[1])?.name, "libsystem_blocks.dylib")
    }

    /// The legacy format has fields that look alike; it must not be taken.
    func testBasebinRefusesOtherText() throws {
        let report = try decode(Fixture.legacy)
        XCTAssertGreaterThan(report.crash?.threads.count ?? 0, 1)
    }

    /// `XRASH_REPORT_DIR=<folder> swift test` — every crash, hang, resource and
    /// panic report in a folder pulled off a device has a line for its row.
    func testEveryReportInAFolderHasAReason() throws {
        guard let folder = ProcessInfo.processInfo.environment["XRASH_REPORT_DIR"] else {
            throw XCTSkip("XRASH_REPORT_DIR is not set")
        }
        let root = URL(fileURLWithPath: folder)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder).sorted() {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let report = try? ReportDecoder.decode(data, fileName: name),
                  [.crash, .hang, .resource, .panic].contains(report.kind) else { continue }
            XCTAssertNotNil(report.reason, name)
        }
    }

    // MARK: Helpers

    private func decode(_ name: String) throws -> Report {
        try ReportDecoder.decode(Fixture.data(name), fileName: name)
    }

    private func legacy(_ text: String) throws -> CrashReport {
        try XCTUnwrap(ReportDecoder.decode(Data(text.utf8), fileName: "Crasher.crash").crash)
    }

    private func summary(_ name: String = "Fila-2026-09-08-191717.ips") -> ReportSummary {
        ReportDecoder.summary(path: "/var/mobile/Library/Logs/CrashReporter/\(name)", byteCount: 1, modified: .now)
    }

    private func enriched(_ name: String, executablePath: String?) throws -> ReportSummary {
        let header = try XCTUnwrap(ReportDecoder.header(fromPrefix: Fixture.data(name)))
        return ReportDecoder.enrich(summary(name), header: header, executablePath: executablePath)
    }
}

import XCTest
@testable import XrashReport

final class RendererTests: XCTestCase {
    func testCrashTextIsTheClassicLayout() throws {
        let text = try ReportRenderer.crashText(decode(Fixture.fila))
        for expected in [
            "Incident Identifier: AAAAAAAA-0000-0000-0000-000000000001",
            "Process:             Fila [2400]",
            "Identifier:          wiki.qaq.fila",
            "Version:             0.3.8 (62)",
            "OS Version:          iPhone OS 26.6.1 (23G83)",
            "Exception Type:  EXC_CRASH (SIGABRT)",
            "Exception Codes: 0x0000000000000000, 0x0000000000000000",
            "Termination Reason: SIGNAL 6 Abort trap: 6",
            "Terminating Process: Fila [2400]",
            "Triggered by Thread:  0",
            "Application Specific Information:",
            "libsystem_c.dylib: abort() called",
            "Last Exception Backtrace:",
            "Thread 0 Crashed::  Dispatch queue: com.apple.uikit.datasource.diffing",
            "Thread 2::  com.apple.uikit.eventfetch-thread",
            "Thread 0 crashed with ARM Thread State (64-bit):",
            "Binary Images:",
        ] {
            XCTAssertTrue(text.contains(expected), "missing: \(expected)")
        }
        XCTAssertTrue(text.contains("0   libsystem_kernel.dylib        \t0x000000023a9be1d0 __pthread_kill + 8"))
        XCTAssertTrue(text.contains("  pc: 0x000000023a9be1d0"))
        XCTAssertTrue(text.contains("<18665b3f-6d51-33ab-b9e9-63062200ec42> /usr/lib/system/libsystem_kernel.dylib"))
    }

    func testJetsamRendersLargestFirst() throws {
        let text = try ReportRenderer.crashText(decode(Fixture.jetsam))
        let processes = text.split(separator: "\n").compactMap { line -> String? in
            ["Fila", "mediaserverd", "Sileo"].first { line.hasPrefix($0) }
        }
        XCTAssertEqual(processes, ["Fila", "mediaserverd", "Sileo"])
        // 47000 pages of 16 KB.
        XCTAssertTrue(text.contains("734 MB"), text)
        XCTAssertTrue(text.contains("per-process-limit"))
    }

    func testPanicRendersThePanicString() throws {
        XCTAssertTrue(try ReportRenderer.crashText(decode(Fixture.panic)).hasPrefix("panic(cpu 3 caller"))
    }

    func testAnalyticsFallsBackToItsText() throws {
        let report = try decode(Fixture.siri)
        XCTAssertEqual(ReportRenderer.crashText(report), report.rawText)
    }

    func testPrettyJSONReparsesAndKeepsWideIntegersExact() throws {
        for name in [Fixture.fila, Fixture.sudo, Fixture.panic, Fixture.siri] {
            let pretty = try ReportRenderer.prettyJSON(decode(name))
            // The blank line between the two objects is the only place a `}`
            // and a `{` sit in column zero with nothing between them.
            let parts = pretty.components(separatedBy: "}\n\n{")
            XCTAssertEqual(parts.count, 2, name)
            for part in [parts[0] + "}", "{" + parts[1]] {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(part.utf8)), name)
            }
        }
        // A kernel image base does not fit in Int64; it must survive verbatim.
        XCTAssertTrue(try ReportRenderer.prettyJSON(decode(Fixture.panic)).contains("18446741874833784832"))
    }

    /// A JSON header over a text body: the header is indented, the text kept.
    func testPrettyJSONIndentsAHeaderOverText() throws {
        let report = try decode(Fixture.diskWrites)
        let pretty = ReportRenderer.prettyJSON(report)
        XCTAssertTrue(pretty.hasPrefix("{\n"))
        XCTAssertTrue(pretty.contains("\"app_name\" : \"Relaxin\""))
        XCTAssertTrue(pretty.contains("\n\nDate/Time:        2026-09-18"))
        XCTAssertTrue(pretty.hasSuffix("Active cpus:      6\n"))
    }

    /// Several JSON objects on several lines: not a header plus a body, so it
    /// comes back untouched rather than half-formatted.
    func testPrettyJSONLeavesNonPairsAlone() throws {
        let report = try decode(Fixture.census)
        XCTAssertEqual(ReportRenderer.prettyJSON(report), report.rawText)
        let legacy = try decode(Fixture.legacy)
        XCTAssertEqual(ReportRenderer.prettyJSON(legacy), legacy.rawText)
    }

    func testMarkdown() throws {
        let markdown = try ReportRenderer.markdown(decode(Fixture.fila))
        XCTAssertTrue(markdown.hasPrefix("## Fila crashed — EXC_CRASH (SIGABRT)"))
        XCTAssertTrue(markdown.contains("| Version | 0.3.8 (62) |"))
        XCTAssertTrue(markdown.contains("| Device | iPhone99,11 |"))
        XCTAssertTrue(markdown.contains("| Incident | AAAAAAAA-0000-0000-0000-000000000001 |"))
        XCTAssertTrue(markdown.contains("abort()"))
        XCTAssertTrue(markdown.contains("```"))
        XCTAssertTrue(markdown.contains("__pthread_kill + 8"))
    }

    /// ISO 8601 has no room for the report's fractional seconds, so the export
    /// is stable rather than lossless: decoding and re-encoding it is a no-op.
    func testModelJSONRoundTrips() throws {
        let data = try ReportRenderer.modelJSON(decode(Fixture.fila))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Report.self, from: data)
        XCTAssertEqual(decoded.crash?.process.name, "Fila")
        XCTAssertEqual(decoded.crash?.threads[0].registers[7].value, 18_446_726_482_597_246_976)
        XCTAssertEqual(decoded.crash?.threads[0].frames[0].address, 9_573_183_488 + 45520)
        XCTAssertEqual(try ReportRenderer.modelJSON(decoded), data)
    }

    // MARK: Explanations

    func testExplanationTable() {
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGABRT").contains("abort()"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGABRT",
                              info: ["CoreFoundation: *** Terminating app due to uncaught exception"])
                .contains("never caught"))
        XCTAssertTrue(explain(type: "EXC_BAD_ACCESS", signal: "SIGSEGV",
                              subtype: "KERN_INVALID_ADDRESS at 0x0000000000000010").contains("null pointer"))
        XCTAssertTrue(explain(type: "EXC_BAD_ACCESS", signal: "SIGSEGV",
                              subtype: "KERN_INVALID_ADDRESS at 0x00000001a0000000").contains("already freed"))
        XCTAssertTrue(explain(type: "EXC_BAD_ACCESS", signal: "SIGSEGV",
                              subtype: "Pointer authentication failure at 0x00000001a0000000")
                .contains("authentication"))
        XCTAssertTrue(explain(type: "EXC_BREAKPOINT", signal: "SIGTRAP").contains("fatalError"))
        XCTAssertTrue(explain(type: "EXC_BAD_INSTRUCTION", signal: "SIGILL").contains("cannot run"))
        XCTAssertTrue(explain(type: "EXC_GUARD", signal: "SIGKILL").contains("guarded"))
        XCTAssertTrue(explain(type: "EXC_RESOURCE", signal: "").contains("resource limit"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "SPRINGBOARD", code: 0x8BAD_F00D)
            .contains("watchdog"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "CODESIGNING",
                              info: ["Invalid Page"]).contains("signature"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGABRT", namespace: "DYLD",
                              reasons: ["Library not loaded: /usr/lib/libfoo.dylib"]).contains("libfoo"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "JETSAM",
                              reasons: ["per-process-limit"]).contains("its own limit"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "RUNNINGBOARD", code: 0xDEAD_10CC)
            .contains("background"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "FRONTBOARD", code: 0xBADD_CAFE)
            .contains("launching"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "TCC").contains("privacy"))
        XCTAssertTrue(explain(type: "EXC_CRASH", signal: "SIGKILL", namespace: "LIBXPC").contains("XPC"))
        XCTAssertTrue(explain(type: "", signal: "").contains("without a recognized exception"))
    }

    func testExplanationOfARealCrash() throws {
        let crash = try XCTUnwrap(decode(Fixture.fila).crash)
        XCTAssertTrue(ReportExplainer.explanation(for: crash).contains("abort()"))
    }

    // MARK: Signatures

    /// Two runs of the same bug differ in every address; the signature must
    /// not.
    func testSignatureIsStableAcrossImageBases() throws {
        let crash = try XCTUnwrap(decode(Fixture.fila).crash)
        var moved = crash
        let slide: UInt64 = 0x1234_0000
        for index in moved.images.indices {
            moved.images[index].base &+= slide
        }
        for index in moved.lastExceptionBacktrace.indices {
            moved.lastExceptionBacktrace[index].address &+= slide
        }
        for thread in moved.threads.indices {
            for frame in moved.threads[thread].frames.indices {
                moved.threads[thread].frames[frame].address &+= slide
            }
        }
        XCTAssertEqual(ReportExplainer.signature(of: crash), ReportExplainer.signature(of: moved))
        XCTAssertNotEqual(crash.images[0].base, moved.images[0].base)
    }

    /// It names the app's own frames, not CoreFoundation's, and never an
    /// absolute address.
    func testSignaturePrefersTheAppsOwnFrames() throws {
        let signature = try ReportExplainer.signature(of: XCTUnwrap(decode(Fixture.fila).crash))
        XCTAssertTrue(signature.hasPrefix("EXC_CRASH|SIGABRT|"))
        XCTAssertTrue(signature.contains("Fila+IconRowCell.showProperties(action:)"))
        XCTAssertFalse(signature.contains("CoreFoundation"))
        XCTAssertFalse(signature.contains("0x23a"))
    }

    /// Every frame is a system one — the fallback keeps the crash groupable
    /// instead of collapsing every daemon crash into one bucket.
    func testSignatureFallsBackToAnyFrames() throws {
        let signature = try ReportExplainer.signature(of: XCTUnwrap(decode(Fixture.sudo).crash))
        XCTAssertTrue(signature.contains("sudo+main"))
    }

    // MARK: Helpers

    private func decode(_ name: String) throws -> Report {
        try ReportDecoder.decode(Fixture.data(name), fileName: name)
    }

    private func explain(
        type: String,
        signal: String,
        subtype: String? = nil,
        namespace: String? = nil,
        code: UInt64? = nil,
        info: [String] = [],
        reasons: [String] = [],
    ) -> String {
        var crash = CrashReport()
        var exception = ExceptionDetails(type: type)
        exception.signal = signal.isEmpty ? nil : signal
        exception.subtype = subtype
        crash.exception = type.isEmpty && signal.isEmpty ? nil : exception
        if namespace != nil || code != nil || !reasons.isEmpty {
            var termination = TerminationDetails()
            termination.namespace = namespace
            termination.code = code
            termination.reasons = reasons
            crash.termination = termination
        }
        crash.applicationInfo = info
        return ReportExplainer.explanation(for: crash)
    }
}

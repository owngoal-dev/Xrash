import Foundation

/// One table, one sentence per row. These sentences are report content, not
/// app chrome: they stay English here so the whole table can be handed to a
/// translator at once rather than scattered through the UI.
enum ExceptionExplainer {
    /// Everything a rule is allowed to look at, read once so the table stays
    /// readable.
    struct Signals {
        let type: String
        let signal: String
        let subtype: String
        let namespace: String
        let code: UInt64
        let reasonLines: String
        /// The address in `KERN_INVALID_ADDRESS at 0x…`, when there is one.
        let address: UInt64?
        /// Everything `mentions` searches, folded once — a report's `asi` runs
        /// to kilobytes and half a dozen rules ask it.
        private let haystack: String

        init(_ crash: CrashReport) {
            type = crash.exception?.type ?? ""
            signal = crash.exception?.signal ?? ""
            subtype = crash.exception?.subtype ?? ""
            namespace = crash.termination?.namespace ?? ""
            code = crash.termination?.code ?? 0
            reasonLines = (crash.applicationInfo + (crash.termination?.reasons ?? [])).joined(separator: "\n")
            address = Signals.address(in: crash.exception?.subtype)
            haystack = (subtype + "\n" + reasonLines).lowercased()
        }

        func mentions(_ needle: String) -> Bool {
            haystack.contains(needle.lowercased())
        }

        private static let at = NSRegularExpression(literal: "at (0x[0-9a-fA-F]+)")

        private static func address(in subtype: String?) -> UInt64? {
            guard let subtype, let groups = at.groups(in: subtype) else { return nil }
            return UInt64(hex: groups[1])
        }
    }

    private struct Rule {
        let matches: (Signals) -> Bool
        let sentence: (Signals) -> String
    }

    static func explanation(for crash: CrashReport) -> String {
        let signals = Signals(crash)
        for rule in rules where rule.matches(signals) {
            return rule.sentence(signals)
        }
        return fallback(signals)
    }

    // Ordered: a termination namespace is a more specific answer than the
    // signal that carried it, so the kills come before the exceptions.
    private static let rules: [Rule] = [
        Rule(matches: { $0.namespace == "SPRINGBOARD" || $0.code == 0x8BAD_F00D }, sentence: { _ in
            "The system's watchdog killed the app because it took too long to launch, resume or quit — "
                + "something blocked the main thread."
        }),
        Rule(matches: { $0.namespace == "CODESIGNING" }, sentence: { signals in
            signals.mentions("invalid page")
                ? "The code signature stopped matching while the app was running: a page of the executable "
                + "changed on disk, usually because it was updated or re-signed underneath it."
                : "The system refused the app's code signature, so it was killed before it could run."
        }),
        Rule(matches: { $0.namespace == "DYLD" }, sentence: { signals in
            let detail = signals.reasonLines.split(separator: "\n").first.map { " — \($0)" } ?? ""
            return "A library the app needs could not be loaded\(detail)."
        }),
        Rule(matches: { $0.namespace == "JETSAM" }, sentence: { signals in
            signals.mentions("per-process-limit")
                ? "The app was killed for using more memory than its own limit allows."
                : "The system killed the app to reclaim memory."
        }),
        Rule(matches: { $0.namespace == "RUNNINGBOARD" || $0.code == 0xDEAD_10CC }, sentence: { _ in
            "The app was killed for holding a system resource — a file lock or a database — while suspended "
                + "in the background."
        }),
        Rule(matches: { $0.namespace == "FRONTBOARD" || $0.code == 0xBADD_CAFE }, sentence: { _ in
            "The app failed to finish launching in the time the system allows."
        }),
        Rule(matches: { $0.namespace == "TCC" }, sentence: { _ in
            "The app used a protected resource without the privacy permission for it, and was killed."
        }),
        Rule(matches: { $0.namespace == "LIBXPC" }, sentence: { _ in
            "An XPC service the app depends on failed, and the app was torn down with it."
        }),
        Rule(matches: { $0.type == "EXC_RESOURCE" }, sentence: { signals in
            let limit = signals.subtype.isEmpty ? "" : " (\(signals.subtype))"
            return "The app went over a resource limit the system enforces\(limit)."
        }),
        Rule(matches: { $0.type == "EXC_GUARD" }, sentence: { _ in
            "The app misused a guarded resource — closing a file descriptor the system owns is the usual cause."
        }),
        Rule(matches: { $0.type.hasPrefix("EXC_BAD_ACCESS") || $0.signal == "SIGSEGV" || $0.signal == "SIGBUS" },
             sentence: { signals in
                 if signals.mentions("pointer authentication") || signals.mentions("ptrauth") {
                     return "The app jumped through a pointer whose authentication code did not check out — "
                         + "a corrupted function pointer or a stack overwrite."
                 }
                 if let address = signals.address, address < 0x4000 {
                     return "The app read or wrote through a null pointer (address "
                         + String(format: "0x%llx", address) + ") — an object was gone or was never set up."
                 }
                 if let address = signals.address {
                     return "The app touched memory it does not own, at address "
                         + String(format: "0x%llx", address) + " — usually an object that was already freed."
                 }
                 return "The app touched memory it does not own — usually an object that was already freed."
             }),
        Rule(matches: { $0.type == "EXC_CRASH" || $0.signal == "SIGABRT" }, sentence: { signals in
            signals.mentions("terminating app due to uncaught exception") || signals.mentions("nsexception")
                ? "An exception was thrown and nobody caught it, so the app aborted."
                : "The app called abort(), usually after an uncaught exception or a failed assertion."
        }),
        Rule(matches: { $0.type == "EXC_BREAKPOINT" || $0.signal == "SIGTRAP" }, sentence: { _ in
            "The Swift runtime trapped: a fatalError, a failed precondition, a force-unwrapped nil or an "
                + "array index out of range."
        }),
        Rule(matches: { $0.type == "EXC_BAD_INSTRUCTION" || $0.signal == "SIGILL" }, sentence: { _ in
            "The app executed an instruction that cannot run — in Swift code this is normally a deliberate trap."
        }),
        Rule(matches: { $0.signal == "SIGKILL" }, sentence: { signals in
            "The system killed the app outright\(signals.namespace.isEmpty ? "" : " (\(signals.namespace))")."
        }),
    ]

    private static func fallback(_ signals: Signals) -> String {
        guard !signals.type.isEmpty else { return "The process ended without a recognised exception." }
        let signal = signals.signal.isEmpty ? "" : " (\(signals.signal))"
        return "The process ended with \(signals.type)\(signal)."
    }
}

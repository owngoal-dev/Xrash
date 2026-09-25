import Combine
import CryptoKit
import Foundation
import XrashClient
import XrashProtocol

#if targetEnvironment(macCatalyst)
    import ServiceManagement
#endif

/// The Mac build's half of the daemon boundary. Ported from iGhostVT's
/// `MacLaunchAgent`, which learned all of this the hard way.
///
/// On the device `xrashd` is a LaunchDaemon the package installed and the app
/// only ever connects to it. On macOS there is no package manager, so the
/// helper ships *inside* the app bundle — `Contents/MacOS/xrashd`, launched by
/// `Contents/Library/LaunchAgents/wiki.qaq.xrashd.plist` — and the app
/// registers it with `SMAppService` on first launch.
///
/// Nothing gates on this. A Mac's reports are readable by the logged-in user
/// already, so a helper that never registers costs nothing but the system
/// directory of a second account; the status is shown in Settings and that is
/// all it is for. `ReportBackend` still decides privileged-or-not by the
/// handshake, the same way it does everywhere else.
///
/// The type exists on every platform so call sites need no `#if`. Off Catalyst
/// it reports `.notApplicable`, which reads as "nothing to gate on".
@MainActor
final class MacLaunchAgent {
    static let shared = MacLaunchAgent()

    enum Status: Equatable {
        /// iOS and iPadOS: the package installed the daemon, there is nothing
        /// to register.
        case notApplicable
        /// macOS 12, where `SMAppService` does not exist.
        case unsupported
        /// Launched from the download, or Gatekeeper-translocated. Registering
        /// now would bind Login Items to a path that is gone by the next
        /// launch, so it waits until the app lives somewhere permanent.
        case needsRelocation
        /// Nothing is registered: a first launch that has not got there yet,
        /// or the helper turned off in Login Items.
        case notRegistered
        /// Registered, but a person still has to allow it in Login Items.
        case needsApproval
        /// The helper in the bundle is not the one Login Items holds — an
        /// update replaced it — and the registration is being redone.
        case rebinding
        case enabled
        case failed(String)
    }

    nonisolated let status: CurrentValueSubject<Status, Never>

    /// The rebind in flight, if any. While it runs, `refresh()` must not
    /// overwrite the status with what `SMAppService` says — a stale item reads
    /// `.enabled` — and a second `activate()` must not start another.
    private var rebindTask: Task<Void, Never>?

    private init() {
        #if targetEnvironment(macCatalyst)
            status = CurrentValueSubject(.unsupported)
        #else
            status = CurrentValueSubject(.notApplicable)
        #endif
    }

    #if targetEnvironment(macCatalyst)

        /// Every launch registers: the plain register is idempotent and
        /// bootstraps the job when launchd has none, and this is where a
        /// replaced helper is caught. Someone who turned the item off in
        /// System Settings keeps it off; a register does not override that.
        func activate() {
            guard #available(macCatalyst 16.0, *) else { return }
            guard rebindTask == nil else { return }
            guard Self.isInApplications else {
                status.send(.needsRelocation)
                return
            }
            let service = SMAppService.agent(plistName: XrashService.macAgentPlistName)
            let digest = Self.helperDigest
            if service.status != .notRegistered, digest != Self.registeredHelperDigest {
                status.send(.rebinding)
                rebindTask = Task { await rebind(service, helperDigest: digest) }
                return
            }
            register(service, helperDigest: digest)
        }

        /// Re-reads the agent's state. Observes only — it never registers, so
        /// it is safe to call when a scene becomes active, where a change made
        /// in System Settings while the app was away gets noticed, without
        /// undoing a person's decision to turn the helper off.
        func refresh() {
            guard #available(macCatalyst 16.0, *) else {
                status.send(.unsupported)
                return
            }
            guard rebindTask == nil else { return }
            guard Self.isInApplications else {
                status.send(.needsRelocation)
                return
            }
            switch SMAppService.agent(plistName: XrashService.macAgentPlistName).status {
            case .enabled: status.send(.enabled)
            case .requiresApproval: status.send(.needsApproval)
            // Apple's `.notFound` is broader than a missing file: after a
            // `launchctl bootout` of an SMAppService job there is no item and
            // this is what comes back although the plist is still in the
            // bundle. Treat it as unregistered so `activate()` runs.
            case .notRegistered, .notFound: status.send(.notRegistered)
            @unknown default: status.send(.needsApproval)
            }
        }

        // MARK: Registering

        /// The plain register: a first launch, or the helper turned back on.
        /// No old item stands in the way here, so the digest is recorded as
        /// soon as the item exists.
        @available(macCatalyst 16.0, *)
        private func register(_ service: SMAppService, helperDigest: String?) {
            do {
                try service.register()
            } catch {
                // A registration refused because approval is pending is not an
                // error worth showing; the status below tells the truth.
                if service.status != .requiresApproval, service.status != .enabled {
                    NSLog("xrash: launch agent register: %@", error.localizedDescription)
                    status.send(.failed(Self.registrationFailure))
                    return
                }
            }
            Self.registeredHelperDigest = helperDigest
            status.send(service.status == .enabled ? .enabled : .needsApproval)
        }

        /// How many unregister → register → answer rounds a rebind gets before
        /// it reports failure. The second round is the one that binds the fresh
        /// item launchd's repair made after the first.
        private static let rebindRounds = 3

        /// How long after a `register()` launchd's repair of a failed spawn has
        /// certainly run. A spawn killed by a launch constraint is pushed out
        /// by ten seconds, and that deferred spawn is where the item is
        /// invalidated. Two seconds of margin.
        private static let repairWindow: TimeInterval = 12

        /// The SDK header says an updated executable must be re-registered,
        /// "and it is recommended to also call unregister before
        /// re-registering". What it does not say, read off the unified log of a
        /// real ad-hoc update (`smd`, `backgroundtaskmanagementd`, `launchd`):
        ///
        /// - `unregister()` does not remove the Background Task Management
        ///   item. It disables it, and the `register()` that follows re-enables
        ///   that same item — with the launch constraint recorded for the *old*
        ///   helper. For an ad-hoc signed helper that constraint pins the
        ///   exact binary, so unregister → register on its own can never mend
        ///   a stale pin, however long it waits in between.
        /// - What does produce a fresh item is launchd. The re-enabled job
        ///   spawns, AMFI kills the new helper, and launchd schedules a repair
        ///   spawn ten seconds out; *that* spawn has BTM invalidate the old
        ///   item and make a new one. An unregister → register after that
        ///   point binds the fresh item to the helper on disk, and it runs.
        /// - A round fired before the repair cancels the throttled spawn and
        ///   re-enables the stale item once more, forever. So a failed round
        ///   waits past `repairWindow` before the next one.
        /// - `status` reads `.enabled` throughout, so it proves nothing. The
        ///   one test that means anything is a round trip to the helper, and
        ///   the digest is recorded only once that succeeds: a rebind that did
        ///   not take is retried on the next launch, never remembered as done.
        ///
        /// The whole class of failure disappears with a Team ID, which keys the
        /// constraint on the team rather than the cdhash.
        @available(macCatalyst 16.0, *)
        private func rebind(_ service: SMAppService, helperDigest digest: String?) async {
            defer { rebindTask = nil }
            var registeredAt: Date?
            for _ in 1 ... Self.rebindRounds {
                if let registeredAt {
                    let remaining = Self.repairWindow - Date().timeIntervalSince(registeredAt)
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                }
                // A `.notFound` item — what `launchctl bootout` leaves — has
                // nothing to unregister; the register still goes on.
                try? await service.unregister()
                await Self.awaitUnregistered(service)
                registeredAt = Date()
                guard await Self.registerThroughSettling(service) else { continue }
                if service.status == .requiresApproval {
                    // Nothing can answer until a person allows it, and the item
                    // is this helper's, so the record is right.
                    Self.registeredHelperDigest = digest
                    status.send(.needsApproval)
                    return
                }
                if await Self.helperAnswers() {
                    Self.registeredHelperDigest = digest
                    status.send(.enabled)
                    return
                }
            }
            status.send(.failed(Self.registrationFailure))
        }

        /// Waits for BTM to stop reporting the item, up to five seconds.
        @available(macCatalyst 16.0, *)
        private static func awaitUnregistered(_ service: SMAppService) async {
            for _ in 0 ..< 20 {
                if service.status == .notRegistered || service.status == .notFound {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        /// Registers, retrying through the settling window in which BTM refuses
        /// it. True once the item exists — approval pending counts.
        @available(macCatalyst 16.0, *)
        private static func registerThroughSettling(_ service: SMAppService) async -> Bool {
            for _ in 0 ..< 12 {
                do {
                    try service.register()
                    return true
                } catch {
                    if service.status == .enabled || service.status == .requiresApproval {
                        return true
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return false
        }

        /// Whether the registered helper actually runs: a handshake over a
        /// connection of its own, which demand-launches the job. A helper AMFI
        /// kills on spawn answers with an error, and an item launchd dropped
        /// with none at all.
        private static func helperAnswers() async -> Bool {
            let client = DaemonClient()
            let answered = await (try? client.connect()) != nil
            await client.disconnect()
            return answered
        }

        private static var registrationFailure: String {
            String(
                localized: "Unable to turn on the Xrash helper. Open Login Items in System Settings to allow it.",
            )
        }

        // MARK: Where the bundle is, and what is in it

        /// SHA-256 of the helper in this bundle, or nil when there is none.
        /// Content, not version: a locally cut zip can carry the same version
        /// as the one it replaces and still be a different signature.
        private static var helperDigest: String? {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xrashd")
            guard let data = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// The digest of the helper whose registration was last seen to hold —
        /// recorded by a plain `register()`, and by a rebind only once the
        /// helper answered. Absent on installs older than this check, which
        /// reads as "unknown" and rebinds once: the state an update from such a
        /// version leaves behind is exactly the one this exists to repair.
        private static let registeredHelperDigestKey = "MacLaunchAgent.registeredHelperDigest"
        private static var registeredHelperDigest: String? {
            get { UserDefaults.standard.string(forKey: registeredHelperDigestKey) }
            set { UserDefaults.standard.set(newValue, forKey: registeredHelperDigestKey) }
        }

        /// Login Items binds to the path the app registered from. From a
        /// download that path is either inside Gatekeeper's read-only
        /// translocation mount or a folder someone will empty, and either way
        /// the entry dangles by the second launch.
        ///
        // ponytail: iGhostVT offers to move itself to Applications from here.
        // Xrash does not need to — its helper is optional — so Settings says
        // where the app has to live and leaves the move to Finder. Port
        // `moveToApplications()` if that ever stops being enough.
        private static var isInApplications: Bool {
            let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/Applications/") {
                return true
            }
            guard let home = homeDirectory else { return false }
            return path.hasPrefix("\(home)/Applications/")
        }

        /// The real home. Not `homeDirectoryForCurrentUser`, which Catalyst
        /// marks unavailable, and not `NSHomeDirectory()`, which answers a
        /// container when sandboxed — this build is not, but a path check has
        /// no business depending on that staying true.
        private static var homeDirectory: String? {
            guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
            return URL(fileURLWithPath: String(cString: directory)).resolvingSymlinksInPath().path
        }

    #else

        func activate() {}
        func refresh() {}

    #endif
}

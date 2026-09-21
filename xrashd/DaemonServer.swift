import Darwin
import Dispatch
import Foundation
import XPC
import XrashProtocol

/// The Mach service listener. launchd starts the process on the first lookup;
/// the process leaves once the last session has been gone for a moment.
final class DaemonServer {
    private static let idleExitDelay: DispatchTimeInterval = .seconds(3)

    private let queue = DispatchQueue(
        label: "wiki.qaq.xrashd.server",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let authenticator = PeerAuthenticator()
    private var listener: xpc_connection_t?
    private var announcer: ReportAnnouncer?
    private var sessions = [UUID: PeerSession]()
    /// Bumped by every accept and every scheduled exit, so a stale timer
    /// cannot take the process down under a client that arrived after it.
    private var idleGeneration: UInt64 = 0

    /// False when the listener could not be created.
    func start() -> Bool {
        guard let listener = XrashService.machServiceName.withCString({
            xrashCreateMachServiceListener($0, queue, PrivateSystemConstant.machServiceListener)
        }) else { return false }
        self.listener = listener
        xpc_connection_set_event_handler(listener) { [weak self] event in
            autoreleasepool { self?.accept(event) }
        }
        // launchd starts this process for a changed report directory as well
        // as for a lookup, and does not say which it was. Made before the
        // listener is live, so the first session already has it.
        queue.sync {
            guard let installRoot = authenticator.installRoot else { return }
            announcer = ReportAnnouncer(installRoot: installRoot, queue: queue)
            announcer?.start()
        }
        xpc_connection_activate(listener)
        // A launch nobody connects to still has to end.
        queue.async { [weak self] in self?.scheduleIdleExit() }
        return true
    }

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XrashXPC.typeConnection else { return }
        guard let installRoot = authenticator.installRoot, authenticator.authenticate(event) else {
            xpc_connection_cancel(event)
            return scheduleIdleExit()
        }

        idleGeneration &+= 1
        let sessionID = UUID()
        let session = PeerSession(connection: event, installRoot: installRoot, announcer: announcer) { [weak self] in
            self?.sessionInvalidated(sessionID)
        }
        sessions[sessionID] = session
        xpc_connection_set_target_queue(event, queue)
        session.activate()
    }

    private func sessionInvalidated(_ sessionID: UUID) {
        guard sessions.removeValue(forKey: sessionID) != nil else { return }
        if sessions.isEmpty {
            scheduleIdleExit()
        }
    }

    private func scheduleIdleExit() {
        idleGeneration &+= 1
        let scheduledGeneration = idleGeneration
        queue.asyncAfter(deadline: .now() + Self.idleExitDelay) { [weak self] in
            guard let self, sessions.isEmpty, idleGeneration == scheduledGeneration else { return }
            // A notification on its way out is not idleness.
            guard announcer?.isBusy != true else { return scheduleIdleExit() }
            exit(EXIT_SUCCESS)
        }
    }
}

#if canImport(XPC)
    import Combine
    import Darwin
    import Foundation
    import XrashProtocol

    public enum BackendStatus: Equatable, Sendable {
        /// launchd has not produced the daemon yet. Not an error, and not shown as one.
        case connecting
        case privileged(installRoot: String)
        /// No daemon after the grace period: the app reads what its own user can.
        case sandboxed
    }

    /// The one place the app gets report files from. With the daemon it asks
    /// root; without it, it runs the same scanner and the same guards itself.
    /// Which of the two is decided at runtime by the handshake, never at build time.
    public actor ReportBackend {
        private static let retryInterval: UInt64 = 300 * NSEC_PER_MSEC
        /// How often a sandboxed backend looks for the daemon again.
        private static let sandboxedRecheckInterval: TimeInterval = 30

        public nonisolated let status = CurrentValueSubject<BackendStatus, Never>(.connecting)

        private let daemon = DaemonClient()
        private let graceDuration: TimeInterval
        /// Uptime of the first miss since the last success. The grace period is a
        /// duration from here — not a timeout per attempt, not a count of attempts.
        private var firstMiss: TimeInterval?
        private var nextRecheck: TimeInterval = 0

        public init(graceDuration: TimeInterval = ReportBackend.defaultGraceDuration) {
            self.graceDuration = graceDuration
        }

        public static var defaultGraceDuration: TimeInterval {
            #if targetEnvironment(simulator)
                0 // No launchd job exists there and none can.
            #else
                6
            #endif
        }

        // MARK: Operations

        public func listReports() async throws -> [ReportEntry] {
            try await perform { try await $0.listReports() } locally: {
                ReportScanner().scan()
            }
        }

        public func openReport(at path: String) async throws -> FileHandle {
            try await perform { try await $0.openReport(at: path) } locally: {
                guard let resolved = PathGuard.regularFile(path, below: ReportRoots.current()) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try Self.openReadOnly(resolved)
            }
        }

        /// Returns the paths that could not be removed.
        public func deleteReports(at paths: [String]) async throws -> [String] {
            try await perform { try await $0.deleteReports(at: paths) } locally: {
                let roots = ReportRoots.current()
                return paths.filter { candidate in
                    guard let resolved = PathGuard.regularFile(candidate, below: roots) else { return true }
                    return unlink(resolved) != 0
                }
            }
        }

        /// A binary or a dyld shared cache file. Most are world-readable, so the
        /// app's own open comes first and root is asked only when that is refused.
        public func openImage(at path: String) async throws -> FileHandle {
            do {
                return try Self.openReadOnly(path)
            } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
                guard case .privileged = await resolve() else { throw error }
                return try await daemon.openImage(at: path)
            }
        }

        /// Hands the daemon what to announce while the app is not running.
        /// False when nothing took it — no daemon, or one that does not
        /// announce — and the app is then the only one that can.
        public func setNoticePolicy(_ policy: NoticePolicy) async -> Bool {
            await (try? perform { try await $0.setNoticePolicy(policy); return true } locally: { false }) ?? false
        }

        /// The current answer to "am I privileged", waiting out the grace period
        /// when the daemon has not shown up yet.
        public func resolve() async -> BackendStatus {
            if status.value == .sandboxed, ProcessInfo.processInfo.systemUptime < nextRecheck {
                return .sandboxed
            }
            while true {
                if let hello = try? await daemon.connect() {
                    firstMiss = nil
                    return publish(.privileged(installRoot: hello.installRoot))
                }
                let now = ProcessInfo.processInfo.systemUptime
                let missedSince = firstMiss ?? now
                firstMiss = missedSince
                if status.value == .sandboxed || now - missedSince >= graceDuration {
                    nextRecheck = now + Self.sandboxedRecheckInterval
                    return publish(.sandboxed)
                }
                publish(.connecting)
                try? await Task.sleep(nanoseconds: Self.retryInterval)
            }
        }

        // MARK: Plumbing

        private func perform<Value>(
            _ privileged: (DaemonClient) async throws -> Value,
            locally: () throws -> Value,
        ) async throws -> Value {
            // Twice: the daemon exits when idle, so the first failure may only
            // mean the connection it answered on is gone.
            for _ in 0 ..< 2 {
                guard case .privileged = await resolve() else { break }
                do {
                    return try await privileged(daemon)
                } catch XrashClientError.unavailable {
                    continue
                }
            }
            return try locally()
        }

        @discardableResult
        private func publish(_ value: BackendStatus) -> BackendStatus {
            if status.value != value {
                status.send(value)
            }
            return value
        }

        private static func openReadOnly(_ path: String) throws -> FileHandle {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }
#endif

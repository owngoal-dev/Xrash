#if canImport(XPC)
    import Dispatch
    import Foundation
    import XPC
    import XrashProtocol

    @_silgen_name("xpc_connection_create_mach_service")
    private func xrashCreateMachServiceConnection(
        _ name: UnsafePointer<CChar>,
        _ queue: DispatchQueue?,
        _ flags: UInt64
    ) -> xpc_connection_t?

    public enum XrashClientError: Error, Equatable, Sendable {
        /// No daemon answered. Never shown to the user as an error: launchd may
        /// simply not have started it yet.
        case unavailable
        case rejected(XrashReplyCode, errorNumber: Int32)
        case malformedReply
    }

    /// The XPC side of the app. Connects on the first request, says goodbye after
    /// a quiet spell so the on-demand daemon can exit, and reconnects on the next.
    public actor DaemonClient {
        private static let quietSpellBeforeGoodbye: UInt64 = 10 * NSEC_PER_SEC

        private struct Reply {
            var code: XrashReplyCode
            var errorNumber: Int32
            var payload: Data?
            /// Owned by whoever receives the reply; -1 when none was sent.
            var descriptor: Int32
        }

        private let queue = DispatchQueue(
            label: "wiki.qaq.xrash.client.xpc",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        private var connection: xpc_connection_t?
        private var hello: HelloReply?
        private var handshake: Task<HelloReply, Error>?
        /// Bumped on every connect and disconnect, so an error event from an old
        /// connection cannot tear down its successor.
        private var generation: UInt64 = 0
        private var activity: UInt64 = 0

        public init() {}

        /// The handshake, performed once per connection.
        public func connect() async throws -> HelloReply {
            if let hello {
                return hello
            }
            // The actor is re-entrant across the handshake's await: requests that
            // arrive meanwhile share the one attempt instead of opening another.
            if let handshake {
                return try await handshake.value
            }
            let attempt = Task { try await openConnection() }
            handshake = attempt
            defer { handshake = nil }
            return try await attempt.value
        }

        private func openConnection() async throws -> HelloReply {
            guard let connection = XrashService.machServiceName.withCString({
                xrashCreateMachServiceConnection($0, queue, 0)
            }) else { throw XrashClientError.unavailable }

            generation &+= 1
            let connectedGeneration = generation
            self.connection = connection
            xpc_connection_set_event_handler(connection) { [weak self] event in
                guard xpc_get_type(event) == XrashXPC.typeError else { return }
                Task { await self?.disconnect(generation: connectedGeneration) }
            }
            xpc_connection_activate(connection)

            do {
                let reply = try await send(.hello)
                guard let payload = reply.payload,
                      let hello = try? XrashWire.decode(HelloReply.self, from: payload)
                else {
                    throw XrashClientError.malformedReply
                }
                self.hello = hello
                return hello
            } catch {
                disconnect(generation: connectedGeneration)
                throw error
            }
        }

        public func listReports() async throws -> [ReportEntry] {
            try await decodedPayload(of: request(.listReports))
        }

        public func openReport(at path: String) async throws -> FileHandle {
            try await descriptor(of: request(.openReport) {
                xpc_dictionary_set_string($0, XrashWireKey.path, path)
            })
        }

        public func openImage(at path: String) async throws -> FileHandle {
            try await descriptor(of: request(.openImage) {
                xpc_dictionary_set_string($0, XrashWireKey.path, path)
            })
        }

        /// Returns the paths that could not be removed.
        public func deleteReports(at paths: [String]) async throws -> [String] {
            let payload = try XrashWire.encode(paths)
            return try await decodedPayload(of: request(.deleteReports) { message in
                payload.withUnsafeBytes {
                    xpc_dictionary_set_data(message, XrashWireKey.payload, $0.baseAddress!, $0.count)
                }
            })
        }

        public func disconnect() async {
            if hello != nil {
                _ = try? await send(.goodbye)
            }
            disconnect(generation: generation)
        }

        // MARK: Requests

        private func request(
            _ operation: XrashOperation,
            fill: ((xpc_object_t) -> Void)? = nil
        ) async throws -> Reply {
            _ = try await connect()
            let reply = try await send(operation, fill: fill)
            guard reply.code == .success else {
                if reply.descriptor >= 0 {
                    close(reply.descriptor)
                }
                throw XrashClientError.rejected(reply.code, errorNumber: reply.errorNumber)
            }
            scheduleGoodbye()
            return reply
        }

        private func send(
            _ operation: XrashOperation,
            fill: ((xpc_object_t) -> Void)? = nil
        ) async throws -> Reply {
            guard let connection else { throw XrashClientError.unavailable }
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_uint64(message, XrashWireKey.version, XrashWire.version)
            xpc_dictionary_set_uint64(message, XrashWireKey.operation, operation.rawValue)
            fill?(message)
            return try await withCheckedThrowingContinuation { continuation in
                xpc_connection_send_message_with_reply(connection, message, queue) { object in
                    continuation.resume(with: autoreleasepool { Self.parse(object) })
                }
            }
        }

        private static func parse(_ object: xpc_object_t) -> Result<Reply, Error> {
            guard xpc_get_type(object) == XrashXPC.typeDictionary else {
                return .failure(XrashClientError.unavailable)
            }
            guard xpc_dictionary_get_uint64(object, XrashWireKey.version) == XrashWire.version,
                  let code = XrashReplyCode(rawValue: xpc_dictionary_get_int64(object, XrashWireKey.code))
            else {
                return .failure(XrashClientError.malformedReply)
            }
            var count = 0
            let payload = xpc_dictionary_get_data(object, XrashWireKey.payload, &count).flatMap {
                count <= XrashWire.maximumPayloadByteCount ? Data(bytes: $0, count: count) : nil
            }
            return .success(Reply(
                code: code,
                errorNumber: Int32(truncatingIfNeeded: xpc_dictionary_get_int64(object, XrashWireKey.errorNumber)),
                payload: payload,
                descriptor: xpc_dictionary_dup_fd(object, XrashWireKey.descriptor)
            ))
        }

        private func decodedPayload<Value: Decodable>(of reply: Reply) throws -> Value {
            guard let payload = reply.payload,
                  let value = try? XrashWire.decode(Value.self, from: payload)
            else {
                throw XrashClientError.malformedReply
            }
            return value
        }

        private func descriptor(of reply: Reply) throws -> FileHandle {
            guard reply.descriptor >= 0 else { throw XrashClientError.malformedReply }
            return FileHandle(fileDescriptor: reply.descriptor, closeOnDealloc: true)
        }

        // MARK: Lifetime

        private func scheduleGoodbye() {
            activity &+= 1
            let scheduledActivity = activity
            Task {
                try? await Task.sleep(nanoseconds: Self.quietSpellBeforeGoodbye)
                guard activity == scheduledActivity else { return }
                await disconnect()
            }
        }

        private func disconnect(generation expected: UInt64) {
            guard expected == generation else { return }
            if let connection {
                xpc_connection_cancel(connection)
            }
            connection = nil
            hello = nil
            generation &+= 1
        }
    }
#endif

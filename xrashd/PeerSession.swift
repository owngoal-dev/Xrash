import Darwin
import Foundation
import XPC
import XrashProtocol

/// One authenticated connection. Everything runs on the server's queue: every
/// operation is a few syscalls, and nothing here reads a file's contents
/// beyond the four bytes `openImage` needs to tell a Mach-O from a secret.
final class PeerSession {
    private let installRoot: String
    private let announcer: ReportAnnouncer?
    private let onInvalidation: () -> Void
    private var connection: xpc_connection_t?
    private var handshakeComplete = false

    init(
        connection: xpc_connection_t,
        installRoot: String,
        announcer: ReportAnnouncer?,
        onInvalidation: @escaping () -> Void,
    ) {
        self.connection = connection
        self.installRoot = installRoot
        self.announcer = announcer
        self.onInvalidation = onInvalidation
    }

    func activate() {
        guard let connection else { return }
        xpc_connection_set_event_handler(connection) { [weak self] event in
            autoreleasepool { self?.handle(event) }
        }
        xpc_connection_activate(connection)
    }

    private func handle(_ request: xpc_object_t) {
        guard connection != nil,
              xpc_get_type(request) == XrashXPC.typeDictionary,
              let reply = xpc_dictionary_create_reply(request)
        else {
            return invalidate()
        }
        xpc_dictionary_set_uint64(reply, XrashWireKey.version, XrashWire.version)
        guard xpc_dictionary_get_uint64(request, XrashWireKey.version) == XrashWire.version,
              let operation = XrashOperation(
                  rawValue: xpc_dictionary_get_uint64(request, XrashWireKey.operation),
              ),
              handshakeComplete != (operation == .hello)
        else {
            return send(reply, .invalidRequest)
        }

        switch operation {
        case .hello:
            handshakeComplete = true
            sendPayload(HelloReply(installRoot: installRoot), in: reply)
        case .listReports:
            sendPayload(ReportScanner().scan(), in: reply)
        case .openReport:
            openReport(request, reply)
        case .deleteReports:
            deleteReports(request, reply)
        case .openImage:
            openImage(request, reply)
        case .goodbye:
            send(reply, .success)
            invalidate()
        case .setNoticePolicy:
            setNoticePolicy(request, reply)
        }
    }

    // MARK: Operations

    private func openReport(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let requested = string(XrashWireKey.path, in: request) else {
            return send(reply, .invalidRequest)
        }
        let roots = ReportRoots.current()
        guard let path = PathGuard.regularFile(requested, below: roots) else {
            return send(reply, .refused)
        }
        sendDescriptor(Self.openRegularFile(path, below: roots), in: reply)
    }

    private func deleteReports(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let payload = data(XrashWireKey.payload, in: request),
              let requested = try? XrashWire.decode([String].self, from: payload)
        else {
            return send(reply, .invalidRequest)
        }
        let roots = ReportRoots.current()
        sendPayload(requested.filter { !Self.remove($0, below: roots) }, in: reply)
    }

    private func openImage(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let requested = string(XrashWireKey.path, in: request) else {
            return send(reply, .invalidRequest)
        }
        guard let path = PathGuard.canonical(requested) else { return send(reply, .notFound) }
        let roots = ImageRoots.current(installRoot: installRoot)
        guard roots.contains(where: { PathGuard.isInside(path, root: $0) }) else {
            return send(reply, .refused)
        }

        let descriptor = Self.openRegularFile(path, below: roots)
        guard descriptor >= 0 else { return sendDescriptor(descriptor, in: reply) }
        guard ImageRoots.isSharedCache(path) || MachOMagic.matches(descriptor) else {
            close(descriptor)
            return send(reply, .refused)
        }
        sendDescriptor(descriptor, in: reply)
    }

    private func setNoticePolicy(_ request: xpc_object_t, _ reply: xpc_object_t) {
        guard let payload = data(XrashWireKey.payload, in: request),
              let policy = try? XrashWire.decode(NoticePolicy.self, from: payload),
              policy.hiddenProcessNames.count <= NoticePolicy.maximumHiddenProcessNameCount
        else {
            return send(reply, .invalidRequest)
        }
        // Refused is an answer, not a failure: the app then announces itself.
        guard let announcer else { return send(reply, .refused) }
        send(reply, announcer.adopt(policy) ? .success : .operationFailed)
    }

    // MARK: Opening as root

    /// A read-only descriptor for a regular file below one of `roots`, or -1
    /// with `errno` set the way `open(2)` leaves it.
    ///
    /// `realpath(3)` answered about a name a moment ago and the name is not
    /// the file: `mobile` owns the report directories and can swap a component
    /// in between. So the descriptor is asked where it actually landed, and
    /// that answer is what the roots are compared against. `O_NONBLOCK` is
    /// there for the other half of the same trick — a fifo left in a report
    /// directory would otherwise park the daemon's one queue inside `open`.
    static func openRegularFile(_ path: String, below roots: [String]) -> Int32 {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return descriptor }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              // A hard link has nothing for `O_NOFOLLOW` to refuse, and
              // `mobile` can make one inside a directory it owns. Nothing the
              // system wrote here has a second name.
              metadata.st_nlink == 1,
              let landed = descriptorPath(descriptor),
              roots.contains(where: { PathGuard.isInside(landed, root: $0) })
        else {
            close(descriptor)
            errno = EPERM
            return -1
        }
        return descriptor
    }

    /// Where `descriptor` is now, which is not necessarily the name it was
    /// opened by.
    private static func descriptorPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Removes one report through a descriptor for its directory rather than
    /// by name, for the same reason: between the `realpath(3)` and an
    /// `unlink(2)` by path, a directory along the way can become a symlink,
    /// and this process is root.
    private static func remove(_ candidate: String, below roots: [String]) -> Bool {
        guard let path = PathGuard.regularFile(candidate, below: roots) else { return false }
        let directory = open(
            (path as NSString).deletingLastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
        )
        guard directory >= 0 else { return false }
        defer { close(directory) }

        guard let landed = descriptorPath(directory),
              roots.contains(where: { landed == $0 || PathGuard.isInside(landed, root: $0) })
        else { return false }
        return unlinkat(directory, (path as NSString).lastPathComponent, 0) == 0
    }

    // MARK: Replies

    private func send(_ reply: xpc_object_t, _ code: XrashReplyCode) {
        guard let connection else { return }
        xpc_dictionary_set_int64(reply, XrashWireKey.code, code.rawValue)
        xpc_connection_send_message(connection, reply)
    }

    private func sendPayload(_ value: some Encodable, in reply: xpc_object_t) {
        guard let payload = try? XrashWire.encode(value),
              payload.count <= XrashWire.maximumPayloadByteCount
        else {
            return send(reply, .operationFailed)
        }
        payload.withUnsafeBytes {
            xpc_dictionary_set_data(reply, XrashWireKey.payload, $0.baseAddress!, $0.count)
        }
        send(reply, .success)
    }

    /// Sends `descriptor` and closes our copy; a negative one reports `errno`.
    private func sendDescriptor(_ descriptor: Int32, in reply: xpc_object_t) {
        guard descriptor >= 0 else {
            let code = errno
            xpc_dictionary_set_int64(reply, XrashWireKey.errorNumber, Int64(code))
            return send(reply, code == ENOENT ? .notFound : .operationFailed)
        }
        xpc_dictionary_set_fd(reply, XrashWireKey.descriptor, descriptor)
        close(descriptor)
        send(reply, .success)
    }

    private func invalidate() {
        guard let connection else { return }
        xpc_connection_cancel(connection)
        self.connection = nil
        onInvalidation()
    }

    // MARK: Request fields

    private func string(_ key: String, in dictionary: xpc_object_t) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    private func data(_ key: String, in dictionary: xpc_object_t) -> Data? {
        var count = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, key, &count),
              count <= XrashWire.maximumPayloadByteCount else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

/// The only bytes of a file the daemon ever looks at.
private enum MachOMagic {
    private static let known: Set<UInt32> = [
        0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, // thin, either order
        0xCAFE_BABE, 0xBEBA_FECA, 0xCAFE_BABF, 0xBFBA_FECA, // fat, fat64
    ]

    static func matches(_ descriptor: Int32) -> Bool {
        var magic: UInt32 = 0
        guard pread(descriptor, &magic, 4, 0) == 4 else { return false }
        return known.contains(magic)
    }
}

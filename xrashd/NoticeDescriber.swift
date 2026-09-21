import Darwin
import Dispatch
import Foundation
import XrashNotice
import XrashProtocol

/// What a new report says about itself, without root ever parsing it.
///
/// `xrashd` opens files and does not read them, and a notification that says
/// `EXC_CRASH (SIGABRT) · 0.2.0 (43)` has to read one. So the daemon opens the
/// report the way it opens one for the app, and starts itself again as a child
/// that gives its privileges away before it touches a byte: the descriptor is
/// its descriptor 3, its answer is a small property list on its standard
/// output, and everything else it inherited is closed. `mobile` owns the
/// report directory and can leave anything there; the worst such a file does
/// is take down a process that is `mobile` already.
enum NoticeDescriber {
    /// `xrashd describe <file name>`.
    static let argument = "describe"

    private static let reportDescriptor: Int32 = 3
    private static let deadline: DispatchTimeInterval = .seconds(3)
    /// Who the child becomes: the account the reports belong to.
    private static let unprivilegedID: UInt32 = 501

    // MARK: The child

    /// Never returns. Nothing is read before the privileges are gone for
    /// good, and "for good" is tested rather than assumed.
    static func runChild(fileName: String) -> Never {
        var group = gid_t(unprivilegedID)
        guard setgroups(1, &group) == 0,
              setgid(group) == 0,
              setuid(uid_t(unprivilegedID)) == 0,
              getuid() == unprivilegedID, geteuid() == unprivilegedID,
              setuid(0) != 0
        else { exit(EXIT_FAILURE) }

        let report = FileHandle(fileDescriptor: reportDescriptor, closeOnDealloc: false)
        guard let data = try? report.read(upToCount: NoticeDetail.maximumReportByteCount + 1),
              data.count <= NoticeDetail.maximumReportByteCount,
              let detail = NoticeDetail(report: data, fileName: fileName)?.clamped,
              let encoded = try? XrashWire.encode(detail),
              encoded.count <= NoticeDetail.maximumEncodedByteCount
        else { exit(EXIT_FAILURE) }
        FileHandle.standardOutput.write(encoded)
        exit(EXIT_SUCCESS)
    }

    // MARK: The parent

    /// Answers on `queue`, with nil for anything short of a clean answer in
    /// time: the notification then says what the file's name says.
    static func describe(
        _ path: String,
        roots: [String],
        queue: DispatchQueue,
        completion: @escaping (NoticeDetail?) -> Void
    ) {
        guard let child = spawn(path: path, roots: roots) else {
            return queue.async { completion(nil) }
        }
        // `finished` is what keeps the deadline from signalling a pid that has
        // been reaped and handed to something else.
        let lock = NSLock()
        var finished = false
        DispatchQueue.global(qos: .utility).async {
            let output = readAll(child.output)
            close(child.output)
            lock.lock()
            finished = true
            lock.unlock()
            var status: Int32 = 0
            while waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
            let exitedCleanly = status & 0x7F == 0 && (status >> 8) & 0xFF == EXIT_SUCCESS
            let detail = exitedCleanly ? output.flatMap { try? XrashWire.decode(NoticeDetail.self, from: $0) } : nil
            queue.async { completion(detail?.clamped) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
            lock.lock()
            if !finished {
                kill(child.pid, SIGKILL)
            }
            lock.unlock()
        }
    }

    /// Everything the child wrote, or nil once it has written too much.
    private static func readAll(_ descriptor: Int32) -> Data? {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return count == 0 ? output : nil }
            output.append(contentsOf: buffer[..<count])
            guard output.count <= NoticeDetail.maximumEncodedByteCount else { return nil }
        }
    }

    private static func spawn(path: String, roots: [String]) -> (pid: pid_t, output: Int32)? {
        guard let executable = processPath(pid: getpid()) else { return nil }
        let report = PeerSession.openRegularFile(path, below: roots)
        guard report >= 0 else { return nil }
        defer { close(report) }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        defer { close(ends[1]) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, report, reportDescriptor)
        posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO)
        // Nothing else this process holds open reaches the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let fileName = (path as NSString).lastPathComponent
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable, argument, fileName].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &arguments, environ) == 0 else {
            close(ends[0])
            return nil
        }
        return (pid, ends[0])
    }
}

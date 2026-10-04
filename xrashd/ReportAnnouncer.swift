import Darwin
import Dispatch
import Foundation
import XrashNotice
import XrashProtocol

/// A notification for a report that arrives while the app is not running.
///
/// Nothing here stays resident. launchd watches the report directories
/// (`WatchPaths` in the job's plist) and starts this process when one changes;
/// the announcer lists them, asks the ledger what is new, posts, and the
/// process leaves through the same idle exit as ever. While a client keeps the
/// process alive launchd has nothing to start, so the directories are watched
/// from in here as well.
///
/// Reports are read only by the child after it becomes mobile.
/// Runs on the server's queue, like everything else in the daemon.
final class ReportAnnouncer {
    /// One report is several writes, and each of them is an event.
    private static let settleDelay: DispatchTimeInterval = .seconds(1)

    private let queue: DispatchQueue
    private let ledgerDirectory: String
    private let poster: NoticePoster
    private var ledger: NoticeLedger
    private var watches = [DispatchSourceFileSystemObject]()
    private var passGeneration: UInt64 = 0
    private var pendingPosts = 0
    private var passIsRunning = false

    /// True while a pass is owed or a post has not been answered; the idle
    /// exit waits for it.
    var isBusy: Bool {
        pendingPosts > 0 || passIsScheduled || passIsRunning
    }

    private var passIsScheduled = false

    /// Nil where this process cannot post for the app: the Mac's per-user
    /// agent, which carries no entitlement and whose app announces on its own.
    init?(installRoot: String, queue: DispatchQueue) {
        guard geteuid() == 0, let poster = NoticePoster() else { return nil }
        self.queue = queue
        self.poster = poster
        ledgerDirectory = installRoot + XrashService.noticeLedgerDirectorySuffix
        ledger = Self.load(from: ledgerDirectory) ?? NoticeLedger(now: Date())
    }

    /// Whatever started the process, a changed directory is the likeliest
    /// reason, so the first pass is owed from the start.
    func start() {
        for root in ReportRoots.current() {
            let descriptor = open(root, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: .write,
                queue: queue,
            )
            source.setEventHandler { [weak self] in self?.schedulePass() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watches.append(source)
        }
        schedulePass()
    }

    func adopt(_ policy: NoticePolicy) -> Bool {
        ledger.adopt(policy)
        return save()
    }

    // MARK: Passes

    private func schedulePass() {
        passGeneration &+= 1
        passIsScheduled = true
        let scheduledGeneration = passGeneration
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, passGeneration == scheduledGeneration else { return }
            guard !passIsRunning else { return }
            passIsScheduled = false
            pass()
        }
    }

    private func pass() {
        passIsRunning = true
        let roots = ReportRoots.current()
        let entries = ReportScanner(roots: roots).scan()
        let now = Date()
        let candidates = ledger.policy?.isEnabled == true ? ledger.candidates(in: entries) : []
        var details = [String: NoticeDetail]()
        /// One child at a time, including reports whose filename guesses the
        /// wrong category. The latest policy is applied when all answers arrive.
        func describe(_ index: Int) {
            guard index < candidates.count else {
                finish(entries, now: now, details: details)
                return
            }
            let path = candidates[index].path
            NoticeDescriber.describe(path, roots: roots, queue: queue) { detail in
                details[path] = detail
                describe(index + 1)
            }
        }
        describe(0)
    }

    private func finish(_ entries: [ReportEntry], now: Date, details: [String: NoticeDetail]) {
        let before = ledger
        let notices = ledger.take(entries, now: now, details: details)
        if ledger != before {
            _ = save()
        }
        for notice in notices {
            pendingPosts += 1
            poster.post(notice, detail: details[notice.path]) { [weak self] in
                self?.queue.async { self?.pendingPosts -= 1 }
            }
        }
        passIsRunning = false
        if passIsScheduled {
            schedulePass()
        }
    }

    // MARK: The ledger on disk

    /// Where the ledger lives, for the one that reads it and the one that
    /// writes it.
    private static func ledgerPath(in directory: String) -> String {
        "\(directory)/\(XrashService.noticeLedgerFileName)"
    }

    private static func load(from directory: String) -> NoticeLedger? {
        guard let data = FileManager.default.contents(atPath: ledgerPath(in: directory)) else { return nil }
        return try? XrashWire.decode(NoticeLedger.self, from: data)
    }

    private func save() -> Bool {
        guard let data = try? XrashWire.encode(ledger) else { return false }
        do {
            // The ledger names hidden processes and is nobody else's.
            try FileManager.default.createDirectory(atPath: ledgerDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ledgerDirectory)
            let url = URL(fileURLWithPath: Self.ledgerPath(in: ledgerDirectory))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}

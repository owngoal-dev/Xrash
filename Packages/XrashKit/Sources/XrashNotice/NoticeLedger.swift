import Foundation
import XrashProtocol
import XrashReport

/// One report worth a notification, from its name alone — no file is opened.
public struct Notice: Equatable, Sendable {
    /// The report's path: the notification's identifier and what a tap opens.
    public var path: String
    public var processName: String
    public var kind: ReportKind
    /// The number the app icon should show once this one is delivered.
    public var badge: Int
}

/// What the daemon remembers between launches so that a report is announced
/// once. launchd starts `xrashd` whenever a report directory changes, and a
/// directory changes for many reasons that are not a new report: a `.synced`
/// rename, a deletion, the second write of a report already seen. The ledger
/// is what turns "something changed" into "these are new".
public struct NoticeLedger: Codable, Equatable, Sendable {
    /// A crash loop must not become a wall of banners.
    static let maximumNoticesPerPass = 8
    static let maximumRememberedPaths = 256

    /// Nil until the app has sent one: nothing is announced for an app that
    /// has never been opened, or never asked.
    public private(set) var policy: NoticePolicy?
    /// The newest modification time already accounted for.
    private var cursor: Date
    /// Recently announced paths. A report is several writes, and the later
    /// ones move its modification time past the cursor again.
    private var announced = [String]()
    private var announcedSincePolicy = 0

    /// A new ledger accounts for everything already on disk.
    public init(now: Date) {
        cursor = now
    }

    /// The app's count is the truth about the badge; start again from it.
    public mutating func adopt(_ policy: NoticePolicy) {
        self.policy = policy
        announcedSincePolicy = 0
    }

    /// The notices `entries` call for, oldest first. The cursor moves whether
    /// or not anything is announced, so turning notifications on later does
    /// not announce what arrived while they were off.
    public mutating func take(_ entries: [ReportEntry], now: Date) -> [Notice] {
        let fresh = entries
            .filter { $0.modified > cursor && !announced.contains($0.path) }
            .sorted { $0.modified < $1.modified }
        // A modification time in the future must not silence everything
        // between now and then.
        cursor = max(cursor, min(fresh.last?.modified ?? cursor, now))
        guard let policy, policy.isEnabled else { return [] }

        var notices = [Notice]()
        for entry in fresh.suffix(Self.maximumNoticesPerPass) {
            let summary = ReportDecoder.summary(
                path: entry.path,
                byteCount: entry.byteCount,
                modified: entry.modified,
            )
            guard policy.kinds.contains(summary.kind.rawValue),
                  !policy.hiddenProcessNames.contains(summary.processName) else { continue }
            announcedSincePolicy += 1
            announced.append(entry.path)
            notices.append(Notice(
                path: entry.path,
                processName: summary.processName,
                kind: summary.kind,
                badge: policy.unreadCount + announcedSincePolicy,
            ))
        }
        announced.removeFirst(max(announced.count - Self.maximumRememberedPaths, 0))
        return notices
    }
}

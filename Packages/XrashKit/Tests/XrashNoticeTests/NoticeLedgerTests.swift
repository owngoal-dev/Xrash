import Foundation
import XCTest
@testable import XrashNotice
import XrashProtocol

final class NoticeLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let directory = "/private/var/mobile/Library/Logs/CrashReporter"

    private func entry(_ name: String, after seconds: TimeInterval) -> ReportEntry {
        ReportEntry(
            path: "\(directory)/\(name)",
            byteCount: 1,
            modified: start.addingTimeInterval(seconds),
            ownerUserID: 0
        )
    }

    private func policy(
        isEnabled: Bool = true,
        kinds: Set<String> = ["crash", "jetsam", "panic", "hang", "resource"],
        hidden: Set<String> = [],
        unread: Int = 0
    ) -> NoticePolicy {
        NoticePolicy(isEnabled: isEnabled, kinds: kinds, hiddenProcessNames: hidden, unreadCount: unread)
    }

    private func ledger(_ policy: NoticePolicy?) -> NoticeLedger {
        var ledger = NoticeLedger(now: start)
        if let policy {
            ledger.adopt(policy)
        }
        return ledger
    }

    func testNothingIsAnnouncedBeforeTheAppHasAsked() {
        var ledger = ledger(nil)
        let later = start.addingTimeInterval(60)
        XCTAssertEqual(ledger.take([entry("Fila-2026-09-21-195211.ips", after: 10)], now: later), [])
        // And what arrived then stays quiet once it does ask.
        ledger.adopt(policy())
        XCTAssertEqual(ledger.take([entry("Fila-2026-09-21-195211.ips", after: 10)], now: later), [])
    }

    func testWhatWasOnDiskFirstIsNotNew() {
        var ledger = ledger(policy())
        XCTAssertEqual(ledger.take([entry("Fila-2026-09-21-101010.ips", after: -60)], now: start), [])
    }

    func testANewReportIsAnnouncedOnceAcrossItsLaterWrites() {
        var ledger = ledger(policy(unread: 2))
        let first = ledger.take([entry("Fila-2026-09-21-195211.ips", after: 10)], now: start.addingTimeInterval(11))
        XCTAssertEqual(first.map(\.processName), ["Fila"])
        XCTAssertEqual(first.map(\.kind), [.crash])
        XCTAssertEqual(first.map(\.badge), [3])
        // The same report, written to again.
        let again = ledger.take([entry("Fila-2026-09-21-195211.ips", after: 12)], now: start.addingTimeInterval(13))
        XCTAssertEqual(again, [])
    }

    func testASyncedRenameIsNotANewReport() {
        var ledger = ledger(policy())
        _ = ledger.take([entry("Fila-2026-09-21-195211.ips", after: 10)], now: start.addingTimeInterval(11))
        let renamed = ledger.take(
            [entry("Fila-2026-09-21-195211.ips.synced", after: 10)],
            now: start.addingTimeInterval(600)
        )
        XCTAssertEqual(renamed, [])
    }

    func testTheFilterIsTheApps() {
        var ledger = ledger(policy(kinds: ["crash"], hidden: ["SpringBoard"]))
        let notices = ledger.take([
            entry("SpringBoard-2026-09-21-195211.ips", after: 10),
            entry("JetsamEvent-2026-09-21-195212.ips", after: 11),
            entry("Irisin-2026-09-21-195213.ips", after: 12),
        ], now: start.addingTimeInterval(20))
        XCTAssertEqual(notices.map(\.processName), ["Irisin"])
        XCTAssertEqual(notices.map(\.badge), [1])
    }

    func testTurnedOffMovesTheCursorAnyway() {
        var ledger = ledger(policy(isEnabled: false))
        let report = entry("Fila-2026-09-21-195211.ips", after: 10)
        XCTAssertEqual(ledger.take([report], now: start.addingTimeInterval(11)), [])
        ledger.adopt(policy())
        XCTAssertEqual(ledger.take([report], now: start.addingTimeInterval(12)), [])
    }

    func testACrashLoopIsCappedAndTheBadgeRestartsWithThePolicy() {
        var ledger = ledger(policy())
        let storm = (1 ... 20).map { entry("Loop-2026-09-21-1952\(String(format: "%02d", $0)).ips", after: Double($0)) }
        let notices = ledger.take(storm, now: start.addingTimeInterval(30))
        XCTAssertEqual(notices.count, NoticeLedger.maximumNoticesPerPass)
        XCTAssertEqual(notices.last?.path, storm.last?.path)
        XCTAssertEqual(notices.last?.badge, NoticeLedger.maximumNoticesPerPass)

        ledger.adopt(policy(unread: 5))
        let next = ledger.take([entry("Fila-2026-09-21-200000.ips", after: 40)], now: start.addingTimeInterval(41))
        XCTAssertEqual(next.map(\.badge), [6])
    }

    func testAFutureModificationTimeDoesNotSilenceWhatFollows() {
        var ledger = ledger(policy())
        let now = start.addingTimeInterval(20)
        XCTAssertEqual(ledger.take([entry("Odd-2026-09-21-195211.ips", after: 86400)], now: now).count, 1)
        XCTAssertEqual(ledger.take([entry("Fila-2026-09-21-195300.ips", after: 30)], now: now.addingTimeInterval(20)).count, 1)
    }

    func testItSurvivesBeingWrittenDown() throws {
        var ledger = ledger(policy(unread: 1))
        _ = ledger.take([entry("Fila-2026-09-21-195211.ips", after: 10)], now: start.addingTimeInterval(11))
        let restored = try XrashWire.decode(NoticeLedger.self, from: XrashWire.encode(ledger))
        XCTAssertEqual(restored, ledger)
    }
}

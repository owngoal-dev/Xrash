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
            ownerUserID: 0,
        )
    }

    private func policy(
        isEnabled: Bool = true,
        kinds: Set<String> = ["crash", "jetsam", "panic", "hang", "resource"],
        hidden: Set<String> = [],
        unread: Int = 0,
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
            now: start.addingTimeInterval(600),
        )
        XCTAssertEqual(renamed, [])
    }

    func testTheFilterIsTheApps() {
        var ledger = ledger(policy(kinds: ["crash"], hidden: ["SpringBoard"]))
        let notices = ledger.take(
            [
                entry("SpringBoard-2026-09-21-195211.ips", after: 10),
                entry("JetsamEvent-2026-09-21-195212.ips", after: 11),
                entry("Irisin-2026-09-21-195213.ips", after: 12),
            ],
            now: start.addingTimeInterval(20),
        )
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
        XCTAssertEqual(
            ledger.take([entry("Fila-2026-09-21-195300.ips", after: 30)], now: now.addingTimeInterval(20)).count,
            1,
        )
    }

    func testItSurvivesBeingWrittenDown() throws {
        var ledger = ledger(policy(unread: 1))
        _ = ledger.take([entry("Fila-2026-09-21-195211.ips", after: 10)], now: start.addingTimeInterval(11))
        let restored = try XrashWire.decode(NoticeLedger.self, from: XrashWire.encode(ledger))
        XCTAssertEqual(restored, ledger)
    }

    func testActualCategoriesOverrideMisleadingNamesAndRemainIndependent() throws {
        let bugs = ["309", "298", "210", "228", "202", "142", "206", "145", "211", "999"]
        let categories: [NoticeCategory] = [.crash, .jetsam, .panic, .hang, .cpu, .wakeups, .diskWrites, .diskWrites, .analytics, .other]
        let entries = bugs.enumerated().map { entry("Test\($0.offset)-2026-09-21-195211.ips", after: Double($0.offset + 1)) }
        let details = try Dictionary(uniqueKeysWithValues: zip(entries, bugs).map { entry, bug in
            let bytes = Data("{\"bug_type\":\"\(bug)\",\"app_name\":\"ActualName\"}\n{}".utf8)
            return try (entry.path, XCTUnwrap(NoticeDetail(report: bytes, fileName: "misleading.ips")))
        })
        for category in NoticeCategory.allCases {
            var selection = policy(kinds: ["crash", "jetsam", "panic", "hang", "resource", "analytics", "other"])
            selection.categories = [category.rawValue]
            var ledger = ledger(selection)
            let notices = ledger.take(entries, now: start.addingTimeInterval(30), details: details)
            XCTAssertEqual(notices.map(\.path), zip(entries, categories).filter { $0.1 == category }.map(\.0.path))
            XCTAssertTrue(notices.allSatisfy { $0.processName == "ActualName" })
            selection.categories = Set(NoticeCategory.allCases.map(\.rawValue))
            ledger.adopt(selection)
            let rewritten = entries.map { item in
                var item = item
                item.modified = start.addingTimeInterval(40)
                return item
            }
            XCTAssertEqual(ledger.take(rewritten, now: start.addingTimeInterval(50), details: details), [])
        }
        var selection = policy()
        selection.categories = []
        var muted = ledger(selection)
        XCTAssertEqual(muted.take(entries, now: start.addingTimeInterval(30), details: details), [])
    }

    func testMutedNoiseDoesNotUseTheCrashLoopBudget() {
        var ledger = ledger(policy(kinds: ["crash"]))
        let crash = entry("Fila-2026-09-21-195211.ips", after: 1)
        let noise = (2 ... 20).map { entry("Noise.cpu_resource-2026-09-21-1952\($0).ips", after: Double($0)) }
        XCTAssertEqual(ledger.take([crash] + noise, now: start.addingTimeInterval(30)).map(\.path), [crash.path])
    }

    func testPolicyChangedWhileDescribingUsesLatestSwitchAndActualProcess() throws {
        let entry = entry("Misleading-2026-09-21-195211.ips", after: 1)
        let detail = try XCTUnwrap(NoticeDetail(report: Data("{\"bug_type\":\"309\",\"app_name\":\"Hidden\"}\n{}".utf8), fileName: "Misleading.ips"))
        var ledger = ledger(policy())
        XCTAssertEqual(ledger.candidates(in: [entry]), [entry])
        ledger.adopt(policy(hidden: ["Hidden"]))
        XCTAssertEqual(ledger.take([entry], now: start.addingTimeInterval(3), details: [entry.path: detail]), [])
        ledger.adopt(policy(isEnabled: false))
        XCTAssertEqual(ledger.take([self.entry("New.ips", after: 4)], now: start.addingTimeInterval(5)), [])
    }
}

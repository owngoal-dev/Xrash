import XCTest
@testable import XrashBundle
import XrashReport

/// One case per rule, and one for the ordering the user sees.
final class CrashCorrelationTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_757_355_437)

    func testTheSameIncidentOutranksEverything() {
        var primary = summary("Fila", at: moment)
        primary.incidentID = "INCIDENT-1"
        var candidate = summary("backboardd", at: moment.addingTimeInterval(4000))
        candidate.incidentID = "INCIDENT-1"

        let suggestion = CrashCorrelation.suggestions(for: primary, primaryCrash: nil, among: [candidate]).first
        XCTAssertEqual(suggestion?.relation, .sameIncident)
        XCTAssertEqual(suggestion?.score, 100)
    }

    func testTheProcessNamedByTheTerminationIsASuggestion() {
        var crash = CrashReport()
        crash.termination = TerminationDetails()
        crash.termination?.byProcess = "SpringBoard"

        let candidate = summary("SpringBoard", at: moment.addingTimeInterval(4000))
        let suggestion = CrashCorrelation.suggestions(
            for: summary("Fila", at: moment),
            primaryCrash: crash,
            among: [candidate]
        ).first
        XCTAssertEqual(suggestion?.relation, .terminator)
        XCTAssertEqual(suggestion?.score, 80)
    }

    func testTheParentResponsibleAndCoalitionAreRelatedProcesses() {
        var crash = CrashReport()
        crash.process.parentName = "launchd"
        crash.process.responsibleName = "SpringBoard"
        crash.process.coalitionName = "Xrash"

        for name in ["launchd", "SpringBoard", "Xrash"] {
            let candidate = summary(name, at: moment.addingTimeInterval(4000))
            let suggestion = CrashCorrelation.suggestions(
                for: summary("Fila", at: moment),
                primaryCrash: crash,
                among: [candidate]
            ).first
            XCTAssertEqual(suggestion?.relation, .relatedProcess, name)
            XCTAssertEqual(suggestion?.score, 60, name)
        }
    }

    func testNearnessInTimeIsWorthLessTheFurtherApartTheyAre() {
        let primary = summary("Fila", at: moment)
        let gaps: [(TimeInterval, Int?)] = [(3, 50), (30, 30), (200, 10), (4000, nil)]
        for (gap, expected) in gaps {
            let candidate = summary("mediaserverd", at: moment.addingTimeInterval(gap))
            let suggestion = CrashCorrelation.suggestions(for: primary, primaryCrash: nil, among: [candidate]).first
            XCTAssertEqual(suggestion?.score, expected, "\(gap)s apart")
            if expected != nil {
                XCTAssertEqual(suggestion?.relation, .sameTime, "\(gap)s apart")
            }
        }
    }

    func testTheSameAppWithinTheHourIsWorthMentioning() {
        var primary = summary("Fila", at: moment)
        primary.bundleID = "wiki.qaq.fila"
        var candidate = summary("Fila", at: moment.addingTimeInterval(1800))
        candidate.bundleID = "wiki.qaq.fila"

        let suggestion = CrashCorrelation.suggestions(for: primary, primaryCrash: nil, among: [candidate]).first
        XCTAssertEqual(suggestion?.score, 15)
        XCTAssertEqual(suggestion?.relation, .sameTime)
    }

    /// Hundreds of these sit beside every crash; only an incident id makes one
    /// of them evidence.
    func testAnalyticsAndLogsNeedTheIncidentIDToCount() {
        let primary = summary("Fila", at: moment)
        var noise = summary("Analytics", at: moment.addingTimeInterval(2), kind: .analytics)
        XCTAssertEqual(CrashCorrelation.suggestions(for: primary, primaryCrash: nil, among: [noise]), [])

        var linked = primary
        linked.incidentID = "INCIDENT-1"
        noise.incidentID = "INCIDENT-1"
        XCTAssertEqual(
            CrashCorrelation.suggestions(for: linked, primaryCrash: nil, among: [noise]).first?.relation,
            .sameIncident
        )
    }

    func testTheHighestRelationWinsAndThePrimaryIsNeverSuggested() {
        var crash = CrashReport()
        crash.termination = TerminationDetails()
        crash.termination?.byProcess = "SpringBoard"

        let primary = summary("Fila", at: moment)
        // Both the terminator (80) and three seconds away (50) describe it.
        let candidate = summary("SpringBoard", at: moment.addingTimeInterval(3))
        let suggestions = CrashCorrelation.suggestions(
            for: primary,
            primaryCrash: crash,
            among: [primary, candidate]
        )
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.relation, .terminator)
        XCTAssertEqual(suggestions.first?.score, 80)
    }

    func testSuggestionsAreRankedAndCapped() {
        let primary = summary("Fila", at: moment)
        let candidates = (0 ..< 40).map { index in
            summary("other-\(index)", at: moment.addingTimeInterval(Double(index % 4) + 1))
        }
        let suggestions = CrashCorrelation.suggestions(for: primary, primaryCrash: nil, among: candidates)
        XCTAssertEqual(suggestions.count, 20)
        XCTAssertEqual(suggestions.map(\.score).sorted(by: >), suggestions.map(\.score))
        XCTAssertEqual(suggestions.first?.score, 50)
    }

    private func summary(_ process: String, at date: Date, kind: ReportKind = .crash) -> ReportSummary {
        ReportSummary(
            id: "/var/mobile/Library/Logs/CrashReporter/\(process)-\(date.timeIntervalSince1970).ips",
            fileName: "\(process)-\(date.timeIntervalSince1970).ips",
            processName: process,
            kind: kind,
            group: kind == .crash ? .app : .other,
            date: date,
            byteCount: 4096,
            isSynced: false
        )
    }
}

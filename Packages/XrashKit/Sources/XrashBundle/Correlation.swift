import Foundation
import XrashReport

/// Which other reports belong with one: a crash in one process is very often
/// the visible half of a crash in another.
///
/// Every candidate keeps one relation — its best — because a list that offers
/// the same report three times is a list nobody reads.
extension CrashCorrelation {
    /// Beyond this the two reports are neighbours in a directory, not evidence.
    private static let sameBundleWindow: TimeInterval = 60 * 60
    private static let limit = 20

    /// Reports that probably belong with `primary`: a crash in one process is
    /// often a symptom of one in another. `primaryCrash` sharpens the answer
    /// (terminator, parent, coalition) when the primary has been decoded.
    public static func suggestions(
        for primary: ReportSummary,
        primaryCrash: CrashReport?,
        among candidates: [ReportSummary]
    ) -> [LinkSuggestion] {
        var suggestions = [LinkSuggestion]()
        for candidate in candidates where candidate.id != primary.id {
            let sameIncident = primary.incidentID != nil && candidate.incidentID == primary.incidentID
            // Analytics payloads and plain logs sit in the same directory in
            // their hundreds; only the incident id makes one of them evidence.
            guard sameIncident || (candidate.kind != .analytics && candidate.kind != .other) else { continue }

            var best: (relation: BundleManifest.Relation, score: Int)?
            func consider(_ relation: BundleManifest.Relation, _ score: Int) {
                guard score > (best?.score ?? 0) else { return }
                best = (relation, score)
            }

            if sameIncident {
                consider(.sameIncident, 100)
            }
            if let crash = primaryCrash {
                if crash.termination?.byProcess == candidate.processName {
                    consider(.terminator, 80)
                }
                let relatives = [
                    crash.process.parentName, crash.process.responsibleName, crash.process.coalitionName,
                ]
                if relatives.contains(candidate.processName) {
                    consider(.relatedProcess, 60)
                }
            }

            let gap = abs(candidate.date.timeIntervalSince(primary.date))
            if gap <= 5 {
                consider(.sameTime, 50)
            } else if gap <= 60 {
                consider(.sameTime, 30)
            } else if gap <= 300 {
                consider(.sameTime, 10)
            }
            if let bundleID = primary.bundleID, candidate.bundleID == bundleID, gap <= sameBundleWindow {
                consider(.sameTime, 15)
            }

            guard let best else { continue }
            suggestions.append(
                LinkSuggestion(summary: candidate, relation: best.relation, score: best.score)
            )
        }
        let ranked = suggestions.sorted {
            $0.score == $1.score ? $0.summary.id < $1.summary.id : $0.score > $1.score
        }
        return Array(ranked.prefix(limit))
    }
}

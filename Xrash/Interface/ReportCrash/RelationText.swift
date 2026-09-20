import Foundation
import XrashBundle

/// How a link between two crashes is worded, in one place: the Report Crash
/// form, the saved bundle's member list and the PDF all say the same thing.
enum RelationText {
    static func label(for relation: BundleManifest.Relation) -> String {
        switch relation {
        case .sameIncident: String(localized: "Same incident")
        case .sameTime: String(localized: "Around the same time")
        case .terminator: String(localized: "Terminated by")
        case .relatedProcess: String(localized: "Related process")
        case .sharedSuspect: String(localized: "Shared suspect")
        case .manual: String(localized: "Added manually")
        }
    }
}

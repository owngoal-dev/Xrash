import Foundation

/// `bug_type` is the only honest classifier a report carries. Apple never
/// published the list, so this table is what the device actually writes plus
/// the values the community has documented — one row, one comment, and a
/// deliberate `.other` for everything else rather than a guess.
enum BugType {
    static func kind(of bugType: String) -> ReportKind {
        switch bugType.trimmingCharacters(in: .whitespaces) {
        case "309": .crash // the modern process-death report
        case "109": .crash // the same report before the JSON format
        case "385": .crash // ExcUserFault — a fatal fault raised in userspace
        case "327": .crash // ExcUserFault's second flavour, same shape
        case "298": .jetsam // JetsamEvent — killed under memory pressure
        case "210": .panic // panic-full, kernel panic with the stackshot
        case "110": .panic // the older kernel panic log
        case "228": .hang // hang tracer
        case "288": .hang // stacks-* — the spin/stackshot dump
        case "229": .hang // background hang, microstackshot
        case "202": .resource // cpu_resource
        case "206": .resource // diskwrites_resource
        case "142": .resource // wakeups_resource
        case "145": .resource // the second disk-writes flavour
        case "211": .analytics // Analytics-* aggregate dictionaries
        case "313": .analytics // SiriSearchFeedback
        case "225": .analytics // assistant feedback
        default: .other // unknown: shown as text, never guessed at
        }
    }
}

import XrashReport

/// Notification choices are independent of which reports the list shows.
public enum NoticeCategory: String, Codable, CaseIterable, Sendable {
    case crash, jetsam, panic, hang
    case cpu, wakeups, diskWrites, resource
    case analytics, other

    public init(kind: ReportKind, bugType: String?, fileName: String) {
        switch kind {
        case .crash: self = .crash
        case .jetsam: self = .jetsam
        case .panic: self = .panic
        case .hang: self = .hang
        case .analytics: self = .analytics
        case .other: self = .other
        case .resource:
            switch bugType {
            case "202": self = .cpu
            case "142": self = .wakeups
            case "206", "145": self = .diskWrites
            default:
                if fileName.contains(".cpu_resource") {
                    self = .cpu
                } else if fileName.contains(".wakeups_resource") {
                    self = .wakeups
                } else if fileName.contains(".diskwrites_resource") {
                    self = .diskWrites
                } else {
                    self = .resource
                }
            }
        }
    }

    public init(_ summary: ReportSummary) {
        self.init(kind: summary.kind, bugType: summary.bugType, fileName: summary.fileName)
    }
}

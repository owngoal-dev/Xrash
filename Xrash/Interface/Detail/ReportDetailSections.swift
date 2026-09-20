import Foundation
import XrashBlame
import XrashReport

/// What the detail screen shows, in order. Kept apart from the controller so
/// "which sections does a jetsam report have" is one function to read rather
/// than a walk through a table delegate.
enum DetailSection: Hashable {
    case summary
    case applicationInfo
    case suspects
    case crashedThread
    case lastException
    case threads
    case images
    case linked
    case jetsam
    case panic
    case contents

    var title: String? {
        switch self {
        case .summary: nil
        case .applicationInfo: String(localized: "Application Information")
        case .suspects: String(localized: "Suspects")
        case .crashedThread: String(localized: "Crashed Thread")
        case .lastException: String(localized: "Last Exception Backtrace")
        case .threads: String(localized: "Threads")
        case .images: String(localized: "Binary Images")
        case .linked: String(localized: "Similar Reports")
        case .jetsam: String(localized: "Processes")
        case .panic: String(localized: "Panic")
        case .contents: nil
        }
    }
}

/// The two stacks that are shown as frames rather than behind a disclosure.
enum DetailFrameList: Hashable {
    case crashedThread
    case lastException
}

enum DetailItem: Hashable {
    case header
    case explanation
    case exception
    case termination
    case date
    case system
    case incident
    case applicationInfo(Int)
    case suspect(String)
    case frame(DetailFrameList, Int)
    case showAllFrames(DetailFrameList)
    case thread(Int)
    case binaryImages
    case linkedReports
    case jetsamProcess(Int)
    case panicText
    case viewContents
}

struct DetailContent {
    var report: Report
    var suspects = [Suspect]()
    /// Other reports of the same bug, once the background pass has found them.
    var similar = [ReportSummary]()
    var linkedCount: Int {
        similar.count
    }

    /// The stacks the reader asked to see in full.
    var expanded = Set<DetailFrameList>()
}

enum DetailLayout {
    /// A crashed thread is often hundreds of frames deep and the answer is
    /// almost always in the first few. The rest is one tap away.
    static let collapsedFrameLimit = 40

    static func sections(for content: DetailContent) -> [(section: DetailSection, items: [DetailItem])] {
        var sections = [(section: DetailSection, items: [DetailItem])]()
        sections.append((.summary, summaryItems(content)))

        if let crash = content.report.crash {
            if !crash.applicationInfo.isEmpty {
                sections.append((.applicationInfo, crash.applicationInfo.indices.map(DetailItem.applicationInfo)))
            }
            if !content.suspects.isEmpty {
                sections.append((.suspects, content.suspects.map { DetailItem.suspect($0.id) }))
            }
            if let faulting = crash.faultingThread, !faulting.frames.isEmpty {
                sections.append((.crashedThread, frameItems(
                    .crashedThread,
                    count: faulting.frames.count,
                    expanded: content.expanded.contains(.crashedThread)
                )))
            }
            if !crash.lastExceptionBacktrace.isEmpty {
                sections.append((.lastException, frameItems(
                    .lastException,
                    count: crash.lastExceptionBacktrace.count,
                    expanded: content.expanded.contains(.lastException)
                )))
            }
            let others = crash.threads.indices.filter { $0 != crash.faultingThreadIndex }
            if !others.isEmpty {
                sections.append((.threads, others.map(DetailItem.thread)))
            }
            if !crash.images.isEmpty {
                sections.append((.images, [.binaryImages]))
            }
        }

        if content.report.jetsam != nil {
            sections.append((.jetsam, jetsamItems(content)))
        }
        if content.report.panic != nil {
            sections.append((.panic, [.panicText]))
        }
        if content.report.crash == nil, content.report.jetsam == nil, content.report.panic == nil {
            sections.append((.contents, [.viewContents]))
        }
        if content.linkedCount > 0 {
            sections.append((.linked, [.linkedReports]))
        }
        return sections
    }

    private static func summaryItems(_ content: DetailContent) -> [DetailItem] {
        var items: [DetailItem] = [.header]
        if content.report.crash != nil {
            items.append(.explanation)
        }
        if content.report.crash?.exception != nil {
            items.append(.exception)
        }
        if content.report.crash?.termination != nil {
            items.append(.termination)
        }
        items.append(.date)
        items.append(.system)
        if content.report.header.incidentID != nil {
            items.append(.incident)
        }
        return items
    }

    private static func frameItems(_ list: DetailFrameList, count: Int, expanded: Bool) -> [DetailItem] {
        guard !expanded, count > collapsedFrameLimit else {
            return (0 ..< count).map { DetailItem.frame(list, $0) }
        }
        return (0 ..< collapsedFrameLimit).map { DetailItem.frame(list, $0) } + [.showAllFrames(list)]
    }

    private static func jetsamItems(_ content: DetailContent) -> [DetailItem] {
        guard let jetsam = content.report.jetsam else { return [] }
        return jetsamOrder(jetsam).map(DetailItem.jetsamProcess)
    }

    /// The jetsam table reads largest first: that is the whole question.
    private static func jetsamOrder(_ jetsam: JetsamReport) -> [Int] {
        jetsam.processes.indices.sorted { jetsam.processes[$0].residentPages > jetsam.processes[$1].residentPages }
    }
}

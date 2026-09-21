import CoreText
import Then
import UIKit
import XrashBlame
import XrashBundle
import XrashReport

/// The `Report.pdf` inside a bundle: a cover, then one section per member.
///
/// Text is laid out by Core Text and drawn page by page inside the renderer's
/// closure, never by rasterising views — a report with a hundred threads has
/// to come out as text a person can search, on a device that will not give us
/// the memory to hold it all as pixels.
///
/// Colours are literal rather than semantic: a PDF has no appearance to
/// follow, and a dark-mode label on white paper is unreadable.
enum ReportPDFRenderer {
    /// `icon` is resolved by the caller: looking an asset up draws on UIKit's
    /// asset manager, which asserts off the main thread, and everything else
    /// here is deliberately off it.
    static func pdf(for manifest: BundleManifest, packages: DpkgDatabase?, icon: UIImage?) -> Data {
        let pageSize = Self.pageSize
        let body = bodyText(for: manifest, packages: packages, width: pageSize.width - margin * 2)
        let textRect = CGRect(
            x: margin,
            y: margin + chromeHeight,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2 - chromeHeight * 2
        )
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        let pages = paginate(framesetter, length: body.length, in: textRect.size)
        let total = 1 + pages.count

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: manifest.title,
            kCGPDFContextAuthor as String: "Xrash",
            kCGPDFContextCreator as String: manifest.generator,
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)

        return renderer.pdfData { context in
            context.beginPage()
            drawCover(manifest, icon: icon, pageSize: pageSize)
            drawChrome(manifest.title, page: 1, of: total, pageSize: pageSize)

            for (offset, range) in pages.enumerated() {
                context.beginPage()
                draw(framesetter, range: range, in: textRect, context: context.cgContext, pageSize: pageSize)
                drawChrome(manifest.title, page: offset + 2, of: total, pageSize: pageSize)
            }
        }
    }

    // MARK: Page geometry

    private static let margin: CGFloat = 36
    /// Room reserved above and below the flowing text for the running head.
    private static let chromeHeight: CGFloat = 22
    /// How many members the cover lists before the count stands in for them.
    private static let coverRowLimit = 20

    /// Letter where letter paper is used, A4 everywhere else.
    private static var pageSize: CGSize {
        let letterRegions: Set = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "DO", "GT"]
        let region = Locale.current.regionCode ?? ""
        return letterRegions.contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    // MARK: Cover

    private static func drawCover(_ manifest: BundleManifest, icon: UIImage?, pageSize: CGSize) {
        let width = pageSize.width - margin * 2
        var y = margin + chromeHeight

        if let icon {
            let side: CGFloat = 44
            icon.draw(in: CGRect(x: margin, y: y, width: side, height: side))
            y += side + 14
        }

        y = draw(manifest.title, style: .title, at: CGPoint(x: margin, y: y), width: width)
        let subtitle = [
            Self.dateFormatter.string(from: manifest.created),
            manifest.deviceModel,
            manifest.osVersion,
        ].compactMap(\.self).joined(separator: " · ")
        y = draw(subtitle, style: .caption, at: CGPoint(x: margin, y: y + 2), width: width) + 18

        if !manifest.notes.isEmpty {
            y = draw(String(localized: "Notes"), style: .heading, at: CGPoint(x: margin, y: y), width: width) + 2
            y = draw(truncated(manifest.notes, to: 900), style: .body, at: CGPoint(x: margin, y: y), width: width)
            y += 18
        }

        y = draw(
            String(localized: "Reports in this bundle"),
            style: .heading,
            at: CGPoint(x: margin, y: y),
            width: width
        ) + 4
        let columns: [CGFloat] = [0.22, 0.12, 0.3, 0.2, 0.16].map { $0 * width }
        let header = row(
            [
                String(localized: "Process"),
                String(localized: "Kind"),
                String(localized: "Reason"),
                String(localized: "Date"),
                String(localized: "Relation"),
            ],
            columns: columns,
            style: .tableHeader
        )
        let table = NSMutableAttributedString(attributedString: header)
        // ponytail: a cover holds about twenty rows; more than that and the
        // count stands in for them rather than spilling onto a second cover.
        let members = [manifest.primary] + manifest.linked
        for member in members.prefix(Self.coverRowLimit) {
            table.append(row(
                [
                    member.summary.processName,
                    ReportFormat.kindLabel(member.summary.kind),
                    reason(for: member.report),
                    Self.dateFormatter.string(from: member.summary.date),
                    relationText(member.relation),
                ],
                columns: columns,
                style: .table
            ))
        }
        if members.count > Self.coverRowLimit {
            table.append(attributed(
                String(inflecting: "^[\(members.count - Self.coverRowLimit) more report](inflect: true) not listed."),
                style: .caption
            ))
        }
        table.draw(
            with: CGRect(x: margin, y: y, width: width, height: pageSize.height - y - margin),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
    }

    // MARK: Body

    private static func bodyText(
        for manifest: BundleManifest,
        packages: DpkgDatabase?,
        width: CGFloat
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for member in [manifest.primary] + manifest.linked {
            append(member, to: text, packages: packages, width: width)
        }
        return text
    }

    private static func append(
        _ member: BundleManifest.Member,
        to text: NSMutableAttributedString,
        packages: DpkgDatabase?,
        width: CGFloat
    ) {
        let role = member.relation.map { String(localized: "Linked · \(RelationText.label(for: $0))") }
            ?? String(localized: "Primary")
        text.append(attributed("\(member.summary.processName) — \(role)", style: .title))

        guard let crash = member.report.crash else {
            text.append(attributed(String(localized: "This report carries no thread state."), style: .body))
            text.append(attributed(truncated(member.report.rawText, to: 4000), style: .mono))
            text.append(pageBreak)
            return
        }

        text.append(attributed(ReportExplainer.explanation(for: crash), style: .body))
        text.append(attributed(String(localized: "Key facts"), style: .heading))
        let factColumns: [CGFloat] = [0.26 * width, 0.74 * width]
        for fact in facts(of: member, crash: crash) {
            text.append(row([fact.label, fact.value], columns: factColumns, style: .table))
        }

        let suspects = Blame.suspects(in: crash, packages: packages)
        if !suspects.isEmpty {
            text.append(attributed(String(localized: "Suspects"), style: .heading))
            for suspect in suspects.prefix(8) {
                let reasons = suspect.reasons.map(reasonText).joined(separator: ", ")
                text.append(row([suspect.imageName, reasons], columns: factColumns, style: .table))
            }
        }

        if !crash.lastExceptionBacktrace.isEmpty {
            text.append(attributed(String(localized: "Last exception backtrace"), style: .heading))
            text.append(attributed(frames(crash.lastExceptionBacktrace, images: crash.images), style: .mono))
        }

        if let faulting = crash.faultingThread {
            text.append(attributed(String(localized: "Crashed thread \(faulting.index)"), style: .heading))
            text.append(attributed(frames(faulting.frames, images: crash.images), style: .mono))
        }

        // A thread the report gave no frames for is a heading over a blank
        // line; it says nothing the reader did not already know.
        let others = crash.threads.filter { $0.index != crash.faultingThreadIndex && !$0.frames.isEmpty }
        if !others.isEmpty {
            text.append(attributed(String(localized: "Other threads"), style: .heading))
            for thread in others {
                let name = thread.name ?? thread.queue ?? String(localized: "Thread \(thread.index)")
                text.append(attributed("\(thread.index)  \(name)", style: .caption))
                text.append(attributed(frames(Array(thread.frames.prefix(8)), images: crash.images), style: .mono))
            }
        }

        appendImages(crash.images, to: text, width: width)
        text.append(pageBreak)
    }

    private static func appendImages(_ images: [BinaryImage], to text: NSMutableAttributedString, width: CGFloat) {
        guard !images.isEmpty else { return }
        let shown = images.filter(ReportBundleBuilder.isThirdParty)
        let systemCount = images.count - shown.count

        text.append(attributed(String(localized: "Binary images"), style: .heading))
        // A UUID is 36 characters whatever else is on the row, so its column
        // is sized for one and the path takes what is left.
        let columns: [CGFloat] = [0.18, 0.31, 0.51].map { $0 * width }
        text.append(row(
            [String(localized: "Name"), String(localized: "UUID"), String(localized: "Path")],
            columns: columns,
            style: .tableHeader
        ))
        for image in shown.prefix(60) {
            text.append(row([image.name, image.uuid, image.path], columns: columns, style: .table))
        }
        if systemCount > 0 {
            text.append(attributed(
                String(inflecting: "^[\(systemCount) Apple system image](inflect: true) left out."),
                style: .caption
            ))
        }
    }

    private static func facts(of member: BundleManifest.Member, crash: CrashReport) -> [(label: String, value: String)] {
        var rows = [(label: String, value: String)]()
        rows.append((String(localized: "Process"), "\(crash.process.name) [\(crash.process.pid.map(String.init) ?? "–")]"))
        if let bundleID = crash.process.bundleID {
            rows.append((String(localized: "Bundle ID"), bundleID))
        }
        if let version = crash.process.version {
            let build = crash.process.build.map { " (\($0))" } ?? ""
            rows.append((String(localized: "Version"), version + build))
        }
        if !crash.process.path.isEmpty {
            rows.append((String(localized: "Path"), crash.process.path))
        }
        if let exception = crash.exception {
            let detail = [exception.signal, exception.subtype].compactMap(\.self).joined(separator: " · ")
            rows.append((String(localized: "Exception"), detail.isEmpty ? exception.type : "\(exception.type) · \(detail)"))
        }
        if let termination = crash.termination {
            let byProcess = termination.byProcess.map { String(localized: "by \($0)") }
            let detail = [termination.namespace, termination.indicator, byProcess]
                .compactMap(\.self).joined(separator: " · ")
            rows.append((String(localized: "Termination"), detail))
            for reason in termination.reasons.prefix(4) {
                rows.append((String(localized: "Reason"), reason))
            }
        }
        rows.append((String(localized: "Date"), Self.dateFormatter.string(from: member.summary.date)))
        let device = [crash.device.model, crash.device.osTrain, crash.device.osBuild]
            .compactMap(\.self).joined(separator: " · ")
        if !device.isEmpty {
            rows.append((String(localized: "Device"), device))
        }
        for line in crash.applicationInfo.prefix(4) {
            rows.append((String(localized: "Application"), line))
        }
        return rows
    }

    // MARK: Text flow

    private static func paginate(_ framesetter: CTFramesetter, length: Int, in size: CGSize) -> [CFRange] {
        guard length > 0 else { return [] }
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var ranges = [CFRange]()
        var start = 0
        while start < length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            ranges.append(visible)
            start += visible.length
        }
        return ranges
    }

    private static func draw(
        _ framesetter: CTFramesetter,
        range: CFRange,
        in rect: CGRect,
        context: CGContext,
        pageSize: CGSize
    ) {
        context.saveGState()
        // Core Text draws bottom-up; the PDF context is flipped for UIKit.
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let flipped = CGRect(
            x: rect.minX,
            y: pageSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let frame = CTFramesetterCreateFrame(framesetter, range, CGPath(rect: flipped, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawChrome(_ title: String, page: Int, of total: Int, pageSize: CGSize) {
        let width = pageSize.width - margin * 2
        let y = pageSize.height - margin - 12
        attributed(truncated(title, to: 90), style: .caption, terminated: false)
            .draw(in: CGRect(x: margin, y: y, width: width * 0.7, height: 14))
        let number = attributed(String(localized: "Page \(page) of \(total)"), style: .caption, terminated: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let aligned = NSMutableAttributedString(attributedString: number)
        aligned.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: aligned.length)
        )
        aligned.draw(in: CGRect(x: margin + width * 0.7, y: y, width: width * 0.3, height: 14))
    }

    private static func draw(_ string: String, style: Style, at origin: CGPoint, width: CGFloat) -> CGFloat {
        let text = attributed(string, style: style, terminated: false)
        let bounds = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        text.draw(
            with: CGRect(origin: origin, size: CGSize(width: width, height: ceil(bounds.height))),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return origin.y + ceil(bounds.height)
    }

    // MARK: Styling

    private enum Style {
        case title, heading, body, caption, table, tableHeader, mono
    }

    private static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        switch style {
        case .title:
            paragraph.paragraphSpacingBefore = 14
            paragraph.paragraphSpacing = 4
            return [
                .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
        case .heading:
            paragraph.paragraphSpacingBefore = 10
            paragraph.paragraphSpacing = 2
            return [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: accent,
                .paragraphStyle: paragraph,
            ]
        case .body:
            paragraph.paragraphSpacing = 4
            paragraph.lineSpacing = 1
            return [
                .font: UIFont.systemFont(ofSize: 9.5),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
        case .caption:
            paragraph.paragraphSpacingBefore = 3
            return [
                .font: UIFont.systemFont(ofSize: 8),
                .foregroundColor: captionColor,
                .paragraphStyle: paragraph,
            ]
        case .table, .tableHeader:
            return [
                .font: UIFont.systemFont(ofSize: 8, weight: style == .tableHeader ? .semibold : .regular),
                .foregroundColor: style == .tableHeader ? captionColor : UIColor.black,
                .paragraphStyle: paragraph,
            ]
        case .mono:
            paragraph.paragraphSpacingBefore = 2
            return [
                .font: UIFont.monospacedSystemFont(ofSize: 7.5, weight: .regular),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
        }
    }

    private static func attributed(_ string: String, style: Style, terminated: Bool = true) -> NSAttributedString {
        NSAttributedString(string: terminated ? string + "\n" : string, attributes: attributes(for: style))
    }

    /// One table row, laid out on tab stops: the only way Core Text makes
    /// columns, and the only thing that survives pagination intact.
    private static func row(_ cells: [String], columns: [CGFloat], style: Style) -> NSAttributedString {
        var attributes = attributes(for: style)
        let paragraph = NSMutableParagraphStyle()
        var offset: CGFloat = 0
        var stops = [NSTextTab]()
        for width in columns.dropLast() {
            offset += width
            stops.append(NSTextTab(textAlignment: .left, location: offset))
        }
        paragraph.tabStops = stops
        paragraph.defaultTabInterval = columns.last ?? 100
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.paragraphSpacingBefore = style == .tableHeader ? 4 : 0
        attributes[.paragraphStyle] = paragraph

        // Measured, not counted: a cell wider than its column overruns the tab
        // stop and knocks every column after it onto the next one.
        let font = attributes[.font] as? UIFont ?? .systemFont(ofSize: 8)
        let text = zip(cells, columns)
            .map { fitted($0.0, to: $0.1 - 6, font: font) }
            .joined(separator: "\t")
        return NSAttributedString(string: text + "\n", attributes: attributes)
    }

    private static var pageBreak: NSAttributedString {
        // A blank paragraph is cheaper than a real break and reads the same
        // once every member starts with its own bold title.
        NSAttributedString(string: "\n", attributes: attributes(for: .body))
    }

    private static let accent = UIColor(red: 0.78, green: 0.16, blue: 0.16, alpha: 1)
    /// Paper is not a screen: body text is black, and the only grey on the
    /// page — the running head and the column labels — stays dark enough to
    /// read at 8 pt.
    private static let captionColor = UIColor(white: 0.32, alpha: 1)

    /// The cover's icon: the mark, an ordinary image set. Never `AppIcon` or a
    /// name out of `CFBundleIconFiles`: the icon is an Icon Composer `.icon`,
    /// which the catalogue holds as an image stack with no bitmap of its own,
    /// and iOS 26 answers `UIImage(named:)` for one with an assertion, not nil.
    @MainActor
    static var appIcon: UIImage? {
        UIImage(named: "AppIconMark")
    }

    // MARK: Text helpers

    private static func frames(_ frames: [Frame], images: [BinaryImage]) -> String {
        frames.enumerated().map { index, frame in
            let image = frame.imageIndex
                .flatMap { images.indices.contains($0) ? images[$0].name : nil } ?? "???"
            var symbol = frame.symbol ?? ""
            if !symbol.isEmpty, let location = frame.symbolLocation {
                symbol += " + \(location)"
            }
            if symbol.isEmpty {
                symbol = "\(image) + \(frame.imageOffset)"
            }
            return padded("\(index)", to: 3)
                + " " + padded(fitted(image, to: 24), to: 24)
                + String(format: " 0x%016llx ", frame.address)
                + middleTruncated(symbol, to: 62)
        }.joined(separator: "\n")
    }

    private static func padded(_ string: String, to count: Int) -> String {
        string.count >= count ? string : string + String(repeating: " ", count: count - string.count)
    }

    /// End-truncation by character count, for the monospaced stack columns
    /// where one character is one width.
    private static func fitted(_ string: String, to count: Int) -> String {
        let flat = string.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > count, count > 1 else { return flat }
        return flat.prefix(count - 1) + "…"
    }

    /// End-truncation to an actual width, for a table cell in a proportional
    /// font. The start carries the meaning, so the tail is what goes.
    private static func fitted(_ string: String, to width: CGFloat, font: UIFont) -> String {
        let flat = string.replacingOccurrences(of: "\n", with: " ")
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (flat as NSString).size(withAttributes: attributes).width
        guard measured > width, width > 0 else { return flat }
        // Start from the proportional guess and shrink; one measurement per
        // character only for the handful the guess is out by.
        var result = String(flat.prefix(max(1, Int(CGFloat(flat.count) * width / measured))))
        while !result.isEmpty,
              ((result + "…") as NSString).size(withAttributes: attributes).width > width
        {
            result.removeLast()
        }
        return result + "…"
    }

    /// Middle-truncation for a symbol, where both ends carry the meaning.
    private static func middleTruncated(_ string: String, to count: Int) -> String {
        guard string.count > count, count > 4 else { return string }
        let head = (count - 1) / 2
        return string.prefix(head) + "…" + string.suffix(count - 1 - head)
    }

    private static func truncated(_ string: String, to count: Int) -> String {
        string.count > count ? String(string.prefix(count)) + "…" : string
    }

    private static func reason(for report: Report) -> String {
        ReportFormat.reason(for: report) ?? ReportFormat.kindLabel(report.kind)
    }

    private static func relationText(_ relation: BundleManifest.Relation?) -> String {
        guard let relation else { return String(localized: "Primary") }
        return RelationText.label(for: relation)
    }

    private static func reasonText(_ reason: Suspect.Reason) -> String {
        switch reason {
        case .onFaultingStack: String(localized: "On the crashed thread’s stack")
        case .inExceptionBacktrace: String(localized: "In the exception backtrace")
        case .injectedTweak: String(localized: "Injected tweak")
        case .thirdPartyImage: String(localized: "Third-party code")
        case .recentlyInstalled: String(localized: "Installed recently")
        }
    }

    /// A PDF is read off the page long after it was made, so every date on it
    /// is spelled out rather than "3 hours ago".
    private static let dateFormatter = DateFormatter().then {
        $0.dateStyle = .medium
        $0.timeStyle = .medium
    }
}

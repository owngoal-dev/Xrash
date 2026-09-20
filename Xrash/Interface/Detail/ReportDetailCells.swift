import SnapKit
import Then
import UIKit
import XrashReport

/// The top of a report: whose it is, which version, and what kind of ending.
final class ReportHeaderCell: UITableViewCell {
    static let reuseIdentifier = "reportHeader"

    private let iconView = ReportIconView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        nameLabel.do {
            $0.font = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)
            $0.numberOfLines = 2
        }
        detailLabel.do {
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 2
        }
        for label in [nameLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let names = UIStackView(arrangedSubviews: [nameLabel, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = 3
        }
        let content = UIStackView(arrangedSubviews: [iconView, names]).then {
            $0.alignment = .center
            $0.spacing = 14
        }
        contentView.addSubview(content)
        iconView.snp.makeConstraints { $0.size.equalTo(56) }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(12)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with report: Report, summary: ReportSummary) {
        iconView.configure(with: summary, executablePath: report.crash?.process.path)
        let name = report.crash?.process.name.isEmpty == false
            ? report.crash?.process.name
            : summary.processName
        nameLabel.text = name
        let version = [report.crash?.process.version, report.crash?.process.build.map { "(\($0))" }]
            .compactMap(\.self)
            .joined(separator: " ")
        // A daemon's process name often *is* its bundle id, and printing it
        // twice only pushed the version off the end of the line.
        let bundleID = report.crash?.process.bundleID ?? summary.bundleID
        detailLabel.text = [
            ReportFormat.kindLabel(report.kind),
            version.isEmpty ? summary.appVersion : version,
            bundleID == name ? nil : bundleID,
        ].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// One stack frame, in the shape a crash report has always had: index, what
/// it is, and which image it came from.
final class FrameCell: UITableViewCell {
    static let reuseIdentifier = "frame"

    private let indexLabel = UILabel()
    private let symbolLabel = UILabel()
    private let originLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        indexLabel.do {
            $0.font = .monospacedDigitSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
            $0.textColor = .secondaryLabel
            $0.textAlignment = .right
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        symbolLabel.do {
            $0.font = UIFontMetrics(forTextStyle: .footnote)
                .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            $0.numberOfLines = 2
            $0.lineBreakMode = .byTruncatingMiddle
        }
        originLabel.do {
            // Addresses line up down the column only in a fixed pitch.
            $0.font = UIFontMetrics(forTextStyle: .caption1)
                .scaledFont(for: .monospacedSystemFont(ofSize: 11, weight: .regular))
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingMiddle
        }
        for label in [symbolLabel, originLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let lines = UIStackView(arrangedSubviews: [symbolLabel, originLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        let content = UIStackView(arrangedSubviews: [indexLabel, lines]).then {
            $0.alignment = .firstBaseline
            $0.spacing = 8
        }
        contentView.addSubview(content)
        indexLabel.snp.makeConstraints { $0.width.equalTo(22) }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(8)
        }

        // The row's one interaction is its menu, so a tap opens it where the
        // finger is — a table cell has no menu of its own, a button over it has.
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            },
        ])
        contentView.addSubview(menuButton)
        menuButton.snp.makeConstraints { $0.edges.equalToSuperview() }
        selectionStyle = .none
    }

    /// Asked each time the menu opens.
    var menuProvider: (() -> [UIMenuElement])?
    private let menuButton = UIButton(type: .custom)

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// A stack is read, not skimmed, so every frame is drawn at full contrast
    /// and the interesting ones are *added to* rather than the rest taken
    /// away: a suspect's frames are tinted, the crashed binary's are bold.
    /// Nothing here is greyed out.
    enum Emphasis {
        /// A frame from an image `Blame` named.
        case suspect
        /// The crashed binary's own code.
        case own
        case ordinary
    }

    /// Apple's own, which is context rather than the answer — and still shown
    /// in full.
    static func isSystem(_ image: BinaryImage) -> Bool {
        image.source == "S" || image.path.hasPrefix("/System/") || image.path.hasPrefix("/usr/lib/")
    }

    func configure(with frame: Frame, index: Int, in crash: CrashReport, emphasis: Emphasis) {
        let image = frame.imageIndex.flatMap { crash.images.indices.contains($0) ? crash.images[$0] : nil }
        indexLabel.text = String(index)
        symbolLabel.text = frame.symbol.map { symbol in
            frame.symbolLocation.map { "\(symbol) + \($0)" } ?? symbol
        } ?? ReportFormat.address(frame.address)
        symbolLabel.textColor = emphasis == .suspect ? .tintColor : .label
        symbolLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 12, weight: emphasis == .ordinary ? .regular : .semibold)
        )

        var origin = [image?.name ?? String(localized: "Unknown image")]
        if let file = frame.sourceFile {
            origin.append(frame.sourceLine.map { "\(file):\($0)" } ?? file)
        } else {
            origin.append(ReportFormat.address(frame.address))
        }
        if frame.isInlined {
            origin.append(String(localized: "inlined"))
        }
        originLabel.text = origin.joined(separator: " · ")
    }
}

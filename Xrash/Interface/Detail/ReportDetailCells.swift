import SnapKit
import Then
import UIKit
import XrashReport

/// The report's icon, above the first section and outside every card: inside
/// the top row it pushed that row's text off the margin the rows under it
/// keep. Centred, with the kind's badge on its corner.
final class ReportIconHeaderView: UIView {
    static let iconSide: CGFloat = 200
    private static let badgeSide: CGFloat = 56
    private static let topPadding: CGFloat = 24
    private static let bottomPadding: CGFloat = 12

    /// What a table has to be told, since a table header sizes nothing itself.
    static let height = topPadding + iconSide + bottomPadding

    private let iconView = ReportIconView()
    private let badgeView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.magnification = Self.iconSide / ReportIconView.size
        // An app's own icon says nothing about how it ended, so the corner
        // does: the kind's colour, cut out of the page the way a badge is.
        badgeView.do {
            $0.image = UIImage(
                systemName: "exclamationmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: Self.badgeSide, weight: .bold)
            )
            $0.contentMode = .scaleAspectFit
            $0.backgroundColor = .systemGroupedBackground
            $0.layer.cornerRadius = Self.badgeSide / 2
            $0.layer.masksToBounds = true
            $0.isAccessibilityElement = false
        }
        addSubview(iconView)
        addSubview(badgeView)
        iconView.snp.makeConstraints { make in
            make.size.equalTo(Self.iconSide)
            make.centerX.equalToSuperview()
            make.top.equalToSuperview().inset(Self.topPadding)
        }
        badgeView.snp.makeConstraints { make in
            make.size.equalTo(Self.badgeSide)
            make.trailing.bottom.equalTo(iconView).offset(10)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with report: Report, summary: ReportSummary) {
        iconView.configure(with: summary, executablePath: report.crash?.process.path)
        badgeView.tintColor = ReportFormat.tint(for: summary)
    }
}

/// The top of a report: whose it is, which version, and what kind of ending.
final class ReportHeaderCell: UITableViewCell {
    static let reuseIdentifier = "reportHeader"

    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        nameLabel.do {
            // The card's own field name: the same bold body as the rows
            // under it, because the icon above the card is the prominence.
            $0.font = DetailTypography.name
            $0.numberOfLines = 2
        }
        detailLabel.do {
            // A kind, a version and a bundle id: the same second line, and
            // the same small monospace, as every row under it.
            $0.font = DetailTypography.mono()
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
        // No icon in here: it sits above the section, so this row's text
        // starts on the same margin as every row under it.
        contentView.addSubview(names)
        names.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(12)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with report: Report, summary: ReportSummary) {
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

/// A value row that can open a menu on the tap, the way `FrameCell` does: a
/// row offering several things to do lists them where the finger is.
final class ValueCell: UITableViewCell {
    /// Asked each time the menu opens; nil leaves an ordinary row.
    var menuProvider: (() -> [UIMenuElement])? {
        didSet {
            menuButton.isHidden = menuProvider == nil
            // A content configuration set later puts its view on top.
            contentView.bringSubviewToFront(menuButton)
        }
    }

    private let menuButton = UIButton(type: .custom)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        menuButton.isHidden = true
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            },
        ])
        contentView.addSubview(menuButton)
        menuButton.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
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
        // One monospaced footnote for all three, so the index sits on the
        // symbol's own baseline and the addresses line up down the column.
        // What the eye sorts them by is colour.
        indexLabel.do {
            $0.font = DetailTypography.mono()
            $0.textColor = .secondaryLabel
            $0.textAlignment = .right
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        symbolLabel.do {
            $0.font = DetailTypography.mono()
            $0.numberOfLines = 2
            $0.lineBreakMode = .byTruncatingMiddle
        }
        originLabel.do {
            $0.font = DetailTypography.mono()
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingMiddle
        }
        for label in [indexLabel, symbolLabel, originLabel] {
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
        symbolLabel.font = DetailTypography.mono(emphasis == .ordinary ? .regular : .semibold)

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

import SnapKit
import Then
import UIKit
import XrashReport

/// The report's icon, above the first section and outside every card: inside
/// the top row it pushed that row's text off the margin the rows under it
/// keep. Centred, with the kind's badge on its corner.
final class ReportIconHeaderView: UIView {
    static let iconSide: CGFloat = 80
    private static let badgeSide: CGFloat = 26
    private static let topPadding: CGFloat = 32
    private static let bottomPadding: CGFloat = 32

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
            make.trailing.bottom.equalTo(iconView).offset(5)
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
            // The card's own field name: the same body as the rows under it,
            // because the icon above the card is the prominence.
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
        menuButton.accessibilityLabel = String(localized: "More")
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
        menuButton.accessibilityLabel = String(localized: "More")
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?().menuElements ?? [])
            },
        ])
        contentView.addSubview(menuButton)
        menuButton.snp.makeConstraints { $0.edges.equalToSuperview() }
        selectionStyle = .none
        // An index, a symbol and an origin are one line of a stack, so they
        // are one stop and the label `configure` assembles is what is read —
        // a cell is not an accessibility element until it is told to be. That
        // hides the button covering the row, so the menu it opens is offered
        // through the rotor instead; see `menuProvider`.
        isAccessibilityElement = true
    }

    /// Asked each time the menu opens, and once here for the rotor: the row
    /// reads as one element, which puts the button that opens the menu out of
    /// VoiceOver's reach, so the same things become custom actions.
    var menuProvider: (() -> [RowMenuAction])? {
        didSet { accessibilityCustomActions = menuProvider?().accessibilityActions }
    }

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

    /// Only the frames worth looking at first are marked. Everything else
    /// stays at full contrast — a stack nobody can read is not a stack.
    ///
    /// The suspects are the summary's: a thread on its own page has none, and
    /// passes nothing.
    static func emphasis(of frame: Frame, in crash: CrashReport, suspectPaths: Set<String> = []) -> Emphasis {
        guard let index = frame.imageIndex, crash.images.indices.contains(index) else { return .ordinary }
        let image = crash.images[index]
        if suspectPaths.contains(image.path) {
            return .suspect
        }
        if image.path == crash.process.path {
            return .own
        }
        return isSystem(image) ? .ordinary : .own
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
        accessibilityLabel = [indexLabel.text, symbolLabel.text, originLabel.text]
            .compactMap(\.self)
            .joined(separator: ", ")
    }
}

import SnapKit
import Then
import UIKit
import XrashReport

/// A process row in the inbox: the newest report's icon and words, and how
/// many reports are filed under the name. `ReportRowCell`'s metrics, with the
/// count capsule where that row keeps its date — a date and a capsule side by
/// side left the reason nothing to be read in.
final class ProcessInboxCell: UITableViewCell {
    static let reuseIdentifier = "process"
    private static let unreadDotSize: CGFloat = 8

    private let iconView = ReportIconView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let countLabel = UILabel()
    private let countCapsule = UIView()
    private let unreadDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        // These rows sit in the same column as a report's, drawn the same way.
        configurationUpdateHandler = ReportRowCell.groupedBackgroundHandler

        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.lineBreakMode = .byTruncatingTail
        }
        subtitleLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.textColor = .secondaryLabel
            $0.lineBreakMode = .byTruncatingTail
        }
        countLabel.do {
            // Monospaced, so a column of capsules does not jitter by a digit.
            $0.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            )
            $0.textAlignment = .center
        }
        for label in [titleLabel, subtitleLabel, countLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        countCapsule.do {
            // The count keeps its width; a long process name gives way.
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        unreadDot.do {
            $0.backgroundColor = .tintColor
            $0.layer.cornerRadius = Self.unreadDotSize / 2
            $0.isAccessibilityElement = false
        }

        countCapsule.addSubview(countLabel)
        let names = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        let content = UIStackView(arrangedSubviews: [iconView, names, countCapsule]).then {
            $0.alignment = .center
            $0.spacing = 10
        }
        contentView.addSubview(content)
        contentView.addSubview(unreadDot)
        iconView.snp.makeConstraints { $0.size.equalTo(ReportIconView.size) }
        countLabel.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(2)
            make.leading.trailing.equalToSuperview().inset(8)
            make.width.greaterThanOrEqualTo(12)
        }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(9)
        }
        unreadDot.snp.makeConstraints { make in
            make.size.equalTo(Self.unreadDotSize)
            make.centerY.equalToSuperview()
            make.centerX.equalTo(contentView.snp.leading).offset(10)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule, at whatever height the text size asks for.
        countCapsule.layer.cornerRadius = countCapsule.bounds.height / 2
    }

    func configure(with row: ProcessInboxRow) {
        iconView.configure(with: row.latest)
        titleLabel.text = row.name
        // A reason the list has not decoded yet is remembered as an empty
        // string, which would leave the subtitle ending in a separator.
        let reason = row.latestReason?.isEmpty == false ? row.latestReason : nil
        subtitleLabel.text = [ReportFormat.date(row.latest.date), reason]
            .compactMap(\.self)
            .joined(separator: " · ")
        countLabel.text = row.count.formatted()
        // The number is how many reports there are, not how many are unread;
        // the tint is what says some of them have not been read.
        countCapsule.backgroundColor = row.hasUnread ? .tintColor : .tertiarySystemFill
        countLabel.textColor = row.hasUnread ? .white : .secondaryLabel
        unreadDot.isHidden = !row.hasUnread
        accessibilityLabel = [
            row.name,
            subtitleLabel.text,
            String(inflecting: "^[\(row.count) report](inflect: true)"),
            row.hasUnread ? String(localized: "Unread") : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }
}

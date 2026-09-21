import SnapKit
import Then
import UIKit
import XrashReport

/// A report row: the app's icon, what died, why, and when. Shaped after
/// Inspector's process row, which is the same question about a process
/// that is still alive.
final class ReportRowCell: UITableViewCell {
    static let reuseIdentifier = "report"
    private static let unreadDotSize: CGFloat = 8

    private let iconView = ReportIconView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let dateLabel = UILabel()
    private let unreadDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        // In a split view's primary column the system fills a selected row
        // with the accent colour, and this app's accent is red: a selected
        // report looked like an error. The ordinary grey, everywhere.
        configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            // Named outright in both states: the column's own material would
            // otherwise show through the row, accent tint and all.
            background.backgroundColor = state.isSelected || state.isHighlighted
                ? .systemGray4
                : .secondarySystemGroupedBackground
            cell.backgroundConfiguration = background
        }

        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.lineBreakMode = .byTruncatingTail
        }
        subtitleLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.textColor = .secondaryLabel
            $0.lineBreakMode = .byTruncatingTail
        }
        dateLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.textColor = .secondaryLabel
            $0.textAlignment = .right
            // The date keeps its width; a long process name gives way instead.
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        for label in [titleLabel, subtitleLabel, dateLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        unreadDot.do {
            $0.backgroundColor = .tintColor
            $0.layer.cornerRadius = Self.unreadDotSize / 2
            $0.isAccessibilityElement = false
        }

        let names = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        let content = UIStackView(arrangedSubviews: [iconView, names, dateLabel]).then {
            $0.alignment = .center
            $0.spacing = 10
        }
        contentView.addSubview(content)
        contentView.addSubview(unreadDot)
        iconView.snp.makeConstraints { $0.size.equalTo(ReportIconView.size) }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(9)
        }
        // Mail's place for it: in the leading margin, so a read row and an
        // unread one keep their icons and titles on the same line.
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

    func configure(with state: ReportRowState) {
        let summary = state.summary
        iconView.configure(with: summary)
        titleLabel.text = summary.processName
        subtitleLabel.text = ReportFormat.subtitle(for: summary, reason: state.reason)
        dateLabel.text = ReportFormat.date(summary.date)
        unreadDot.isHidden = !state.isUnread
        accessibilityLabel = [
            summary.processName,
            subtitleLabel.text,
            dateLabel.text,
            state.isUnread ? String(localized: "Unread") : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }
}

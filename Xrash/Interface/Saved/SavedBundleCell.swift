import SnapKit
import Then
import UIKit

/// One subject, an optional note preview, and a quiet metadata line.
final class SavedBundleCell: UITableViewCell {
    static let reuseIdentifier = "SavedBundleCell"

    private let titleLabel = UILabel()
    private let previewLabel = UILabel()
    private let dateLabel = UILabel()
    private let attachmentLabel = UILabel()
    private let enclosure = UIStackView()
    private let metadata = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 17, weight: .medium),
        )
        titleLabel.numberOfLines = 2
        previewLabel.font = .preferredFont(forTextStyle: .subheadline)
        previewLabel.numberOfLines = 2
        dateLabel.font = .preferredFont(forTextStyle: .body)
        attachmentLabel.font = .preferredFont(forTextStyle: .body)
        for label in [previewLabel, dateLabel, attachmentLabel] {
            label.textColor = .secondaryLabel
        }
        for label in [titleLabel, previewLabel, dateLabel, attachmentLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let paperclip = UIImageView(image: UIImage(systemName: "paperclip")).then {
            $0.preferredSymbolConfiguration = .init(textStyle: .subheadline)
            $0.tintColor = .secondaryLabel
            $0.adjustsImageSizeForAccessibilityContentSizeCategory = true
        }
        enclosure.addArrangedSubview(paperclip)
        enclosure.addArrangedSubview(attachmentLabel)
        enclosure.alignment = .center
        enclosure.spacing = 4
        metadata.addArrangedSubview(dateLabel)
        metadata.addArrangedSubview(enclosure)
        metadata.setContentHuggingPriority(.required, for: .horizontal)
        metadata.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = UIStackView(arrangedSubviews: [metadata, UIView()])

        let content = UIStackView(arrangedSubviews: [titleLabel, previewLabel, footer]).then {
            $0.axis = .vertical
            $0.spacing = 6
        }
        contentView.addSubview(content)
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(16)
        }
        updateMetadataLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateMetadataLayout()
        }
    }

    private func updateMetadataLayout() {
        let expanded = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        metadata.axis = expanded ? .vertical : .horizontal
        metadata.alignment = expanded ? .leading : .center
        metadata.spacing = expanded ? 4 : 16
    }

    func configure(title: String, preview: String, date: String, attachmentCount: Int) {
        let paragraph = NSMutableParagraphStyle().then { $0.lineSpacing = 2 }
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [.paragraphStyle: paragraph])
        previewLabel.text = preview
        previewLabel.isHidden = preview.isEmpty
        dateLabel.text = date
        attachmentLabel.text = attachmentCount.formatted()
        enclosure.isHidden = attachmentCount == 0
        accessoryType = .none
        let attachments = attachmentCount == 0 ? "" : String(localized: "Files") + ": " + attachmentCount.formatted()
        accessibilityLabel = [title, preview, date, attachments].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The saved title and notes form one reading block above the device fields.
final class SavedBundleSummaryCell: UITableViewCell {
    static let reuseIdentifier = "SavedBundleSummaryCell"

    private let titleLabel = UILabel()
    private let notesLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isAccessibilityElement = true
        selectionStyle = .none
        titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(
            for: .systemFont(ofSize: 20, weight: .medium),
        )
        notesLabel.font = .preferredFont(forTextStyle: .body)
        for label in [titleLabel, notesLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
        }
        let content = UIStackView(arrangedSubviews: [titleLabel, notesLabel]).then {
            $0.axis = .vertical
            $0.spacing = 12
        }
        contentView.addSubview(content)
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(16)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(title: String, notes: String) {
        let heading = NSMutableParagraphStyle().then { $0.lineSpacing = 2 }
        titleLabel.attributedText = NSAttributedString(string: title, attributes: [.paragraphStyle: heading])
        let paragraph = NSMutableParagraphStyle().then { $0.lineSpacing = 3 }
        notesLabel.attributedText = NSAttributedString(string: notes, attributes: [.paragraphStyle: paragraph])
        notesLabel.isHidden = notes.isEmpty
        accessibilityLabel = [title, notes].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

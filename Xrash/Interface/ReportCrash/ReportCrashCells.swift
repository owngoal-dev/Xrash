import SnapKit
import Then
import UIKit
import XrashReport

/// A report inside a bundle: the same tile and wording as a list row, with
/// the relation in place of the reason, because on these screens what matters
/// about a linked crash is why it is linked.
final class BundleReportCell: UITableViewCell {
    static let reuseIdentifier = "BundleReportCell"

    private let iconView = ReportIconView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let dateLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // The row is one sentence, not four stops with the separators between
        // them: a cell is not an accessibility element until it is told to be,
        // and the label `configure` assembles is read only once it is one.
        // Nothing in here answers a touch, so nothing is hidden by saying so.
        isAccessibilityElement = true
        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            $0.lineBreakMode = .byTruncatingTail
        }
        for label in [subtitleLabel, dateLabel] {
            label.do {
                $0.font = .preferredFont(forTextStyle: .footnote)
                $0.textColor = .secondaryLabel
                $0.lineBreakMode = .byTruncatingTail
            }
        }
        dateLabel.do {
            $0.textAlignment = .right
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        for label in [titleLabel, subtitleLabel, dateLabel] {
            label.adjustsFontForContentSizeCategory = true
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
        iconView.snp.makeConstraints { $0.size.equalTo(ReportIconView.size) }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(9)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with summary: ReportSummary, detail: String? = nil) {
        // A recycled row keeps whatever accessory its last use gave it.
        accessoryView = nil
        accessoryType = .none
        iconView.configure(with: summary)
        titleLabel.text = summary.processName
        subtitleLabel.text = detail ?? ReportFormat.subtitle(for: summary, reason: nil)
        dateLabel.text = ReportFormat.date(summary.date)
        accessibilityLabel = [titleLabel.text, subtitleLabel.text, dateLabel.text]
            .compactMap(\.self).joined(separator: ", ")
    }
}

/// One line of editable text in a form: the bundle's title.
final class FormTextFieldCell: UITableViewCell {
    static let reuseIdentifier = "FormTextFieldCell"

    let textField = UITextField().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.clearButtonMode = .whileEditing
        $0.returnKeyType = .done
        $0.autocorrectionType = .no
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(textField)
        textField.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
            make.height.greaterThanOrEqualTo(28)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

/// The notes field: several lines, growing with what is typed, with the
/// placeholder UITextView still does not have of its own.
final class FormTextViewCell: UITableViewCell, UITextViewDelegate {
    static let reuseIdentifier = "FormTextViewCell"

    /// Called as the text changes so the table can grow the row.
    var onChange: ((String) -> Void)?

    let textView = UITextView().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.isScrollEnabled = false
        $0.backgroundColor = .clear
        $0.textContainerInset = .zero
        $0.textContainer.lineFragmentPadding = 0
    }

    private let placeholderLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .placeholderText
        $0.numberOfLines = 0
        // It sits over the text view and names it; read on its own it would be
        // a second stop saying the same thing.
        $0.isAccessibilityElement = false
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        textView.delegate = self
        contentView.addSubview(textView)
        contentView.addSubview(placeholderLabel)
        textView.snp.makeConstraints { make in
            make.edges.equalTo(contentView.layoutMarginsGuide)
            make.height.greaterThanOrEqualTo(66)
        }
        placeholderLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(textView)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(text: String, placeholder: String) {
        textView.text = text
        textView.accessibilityLabel = placeholder
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        onChange?(textView.text)
    }
}

/// A label, an optional explanation beside it, and a switch.
final class FormSwitchCell: UITableViewCell {
    static let reuseIdentifier = "FormSwitchCell"

    var onChange: ((Bool) -> Void)?

    private let control = UISwitch()

    override init(style _: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .value1, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessoryView = control
        control.addTarget(self, action: #selector(switched), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(title: String, detail: String?, isOn: Bool) {
        var content = defaultContentConfiguration()
        content.text = title
        content.secondaryText = detail
        content.prefersSideBySideTextAndSecondaryText = true
        content.secondaryTextProperties.color = .secondaryLabel
        contentConfiguration = content
        control.isOn = isOn
    }

    @objc private func switched() {
        onChange?(control.isOn)
    }
}

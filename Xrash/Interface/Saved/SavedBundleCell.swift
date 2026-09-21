import SnapKit
import Then
import UIKit
import XrashReport

/// A row on the Saved page: one archive, wearing the icon of the crash it was
/// made from. A bundle is a report with company, and the tile says which
/// report — the symbol that stood here said only that the row was a bundle,
/// which the page already says.
final class SavedBundleCell: UITableViewCell {
    static let reuseIdentifier = "SavedBundleCell"

    private let iconView = ReportIconView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        titleLabel.do {
            $0.font = .preferredFont(forTextStyle: .body)
            // The title carries the date a bundle was made; truncating it
            // would take exactly the part that tells two of them apart.
            $0.numberOfLines = 2
        }
        subtitleLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 2
        }
        for label in [titleLabel, subtitleLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let names = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        let content = UIStackView(arrangedSubviews: [iconView, names]).then {
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

    /// `summary` is the bundle's primary report — the icon — and the words are
    /// the bundle's own.
    func configure(icon summary: ReportSummary, executablePath: String?, title: String, subtitle: String) {
        iconView.configure(with: summary, executablePath: executablePath)
        titleLabel.text = title
        subtitleLabel.text = subtitle
        accessoryType = .disclosureIndicator
        accessibilityLabel = [title, subtitle].joined(separator: ", ")
    }
}

import SnapKit
import UIKit

/// A grouped section header that folds its section: the system's own header
/// text, a chevron at the trailing edge, and the whole strip as the target.
final class CollapsibleSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "collapsible-header"

    var onToggle: (() -> Void)?

    private let chevron = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        chevron.tintColor = .secondaryLabel
        contentView.addSubview(chevron)
        chevron.snp.makeConstraints { make in
            make.trailing.equalTo(contentView.layoutMarginsGuide)
            make.centerY.equalToSuperview()
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        isAccessibilityElement = true
        accessibilityTraits = [.header, .button]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(title: String, isCollapsed: Bool) {
        var content = UIListContentConfiguration.groupedHeader()
        content.text = title
        contentConfiguration = content
        chevron.image = UIImage(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
        contentView.bringSubviewToFront(chevron)
        accessibilityLabel = title
        accessibilityValue = isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
    }

    @objc private func toggle() {
        onToggle?()
    }
}

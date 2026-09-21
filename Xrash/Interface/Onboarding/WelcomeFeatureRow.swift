import SnapKit
import Then
import UIKit

/// One of the first page's rows: a symbol, what it does, and a line about it.
/// Ported from Irisin's `WelcomeFeatureRow`, itself FlowDown's, with its
/// metrics unchanged.
final class WelcomeFeatureRow: UIView {
    init(feature: WelcomeController.Feature) {
        super.init(frame: .zero)

        let iconView = UIImageView().then {
            $0.image = UIImage(systemName: feature.symbol)?
                .applyingSymbolConfiguration(WelcomeStyle.featureSymbol)
            $0.tintColor = WelcomeStyle.accent
            $0.contentMode = .scaleAspectFit
        }
        let titleLabel = UILabel().then {
            $0.text = String(localized: feature.title)
            $0.font = WelcomeStyle.featureTitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 1
        }
        let detailLabel = UILabel().then {
            $0.text = String(localized: feature.detail)
            $0.font = WelcomeStyle.detailFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        let contentStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = 2
            $0.alignment = .leading
        }
        let stack = UIStackView(arrangedSubviews: [iconView, contentStack]).then {
            $0.axis = .horizontal
            $0.spacing = 14
            $0.alignment = .center
        }
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        iconView.snp.makeConstraints { x in
            x.width.height.equalTo(28)
        }
        accessibilityElements = [titleLabel, detailLabel]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

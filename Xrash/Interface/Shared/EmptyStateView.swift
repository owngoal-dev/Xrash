import SnapKit
import Then
import UIKit

/// `UIContentUnavailableConfiguration` is iOS 17. This is the same thing for
/// the floor this app claims, and it is the only one: loading, empty, no
/// results and "can't read that" all look alike because they are one view.
/// Meant to be a table's `backgroundView`.
final class EmptyStateView: UIView {
    enum Content: Equatable {
        case loading(String)
        case message(symbolName: String, title: String, description: String?, actionTitle: String?)
    }

    let content: Content
    private let action: () -> Void

    init(_ content: Content, action: @escaping () -> Void = {}) {
        self.content = content
        self.action = action
        super.init(frame: .zero)

        let stack = UIStackView(arrangedSubviews: arrangedViews()).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 12
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.center.equalTo(safeAreaLayoutGuide)
            make.leading.greaterThanOrEqualTo(safeAreaLayoutGuide).offset(24)
            make.trailing.lessThanOrEqualTo(safeAreaLayoutGuide).offset(-24)
            make.width.lessThanOrEqualTo(420)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func arrangedViews() -> [UIView] {
        switch content {
        case let .loading(text):
            let spinner = UIActivityIndicatorView(style: .medium).then { $0.startAnimating() }
            return [spinner, label(text, style: .subheadline, color: .secondaryLabel)]
        case let .message(symbolName, title, description, actionTitle):
            let titleFont = UIFont.preferredFont(forTextStyle: .title3).withWeight(.semibold)
            let symbol = UIImageView(
                image: UIImage(
                    systemName: symbolName,
                    withConfiguration: UIImage.SymbolConfiguration(font: titleFont),
                ),
            ).then {
                $0.tintColor = .secondaryLabel
                // The title below says what the symbol stands for.
                $0.isAccessibilityElement = false
            }
            let titleLabel = label(title, style: .title3, color: .label).then { $0.font = titleFont }
            var views: [UIView] = [symbol, titleLabel]
            if let description {
                views.append(label(description, style: .subheadline, color: .secondaryLabel))
            }
            if let actionTitle {
                let button = UIButton(type: .system).then {
                    $0.setTitle(actionTitle, for: .normal)
                    $0.titleLabel?.font = .preferredFont(forTextStyle: .body)
                    $0.titleLabel?.adjustsFontForContentSizeCategory = true
                    $0.addTarget(self, action: #selector(performAction), for: .touchUpInside)
                }
                views.append(button)
            }
            return views
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        UILabel().then {
            $0.text = text
            $0.font = .preferredFont(forTextStyle: style)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = color
            $0.textAlignment = .center
            $0.numberOfLines = 0
        }
    }

    @objc private func performAction() {
        action()
    }
}

extension UITableView {
    /// Swaps the background only when what it says changes, so a refresh does
    /// not restart the spinner or rebuild the view under the user's finger.
    func setEmptyState(_ content: EmptyStateView.Content?, action: @escaping () -> Void = {}) {
        guard (backgroundView as? EmptyStateView)?.content != content else { return }
        backgroundView = content.map { EmptyStateView($0, action: action) }
    }
}

extension UIFont {
    /// The same size and Dynamic Type scaling, at another weight.
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

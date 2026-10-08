import SnapKit
import Then
import UIKit

/// Explorer's search layout: a plain field above the document, navigation above
/// the keyboard. The read-only viewer does not need its second, replacement row.
final class FindBar: UIView {
    var onChange: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?

    let toolbar = UIToolbar()
    private let field = UITextField()
    private let result = UILabel()
    private let backward = UIBarButtonItem()
    private let forward = UIBarButtonItem()
    private let cancel = UIButton(type: .system)
    private let dismissKeyboard = UIBarButtonItem()
    private var navigationItems: [UIBarButtonItem] = []

    var query: String {
        field.text ?? ""
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        tintColor = .label

        field.do {
            $0.placeholder = String(localized: "Find")
            $0.accessibilityLabel = String(localized: "Find")
            $0.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
            $0.adjustsFontForContentSizeCategory = true
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.spellCheckingType = .no
            $0.smartQuotesType = .no
            $0.smartDashesType = .no
            $0.smartInsertDeleteType = .no
            $0.clearButtonMode = .always
            $0.returnKeyType = .next
            $0.enablesReturnKeyAutomatically = true
            $0.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
            $0.addTarget(self, action: #selector(findNext), for: .editingDidEndOnExit)
        }
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.contentMode = .scaleAspectFit
        cancel.do {
            $0.setTitle(String(localized: "Cancel"), for: .normal)
            $0.titleLabel?.font = field.font
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.addTarget(self, action: #selector(close), for: .touchUpInside)
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let divider = UIView().then { $0.backgroundColor = .separator }
        let bottom = UIView().then { $0.backgroundColor = .separator }
        for child in [icon, field, divider, cancel, bottom] {
            addSubview(child)
        }
        icon.snp.makeConstraints {
            $0.leading.equalTo(safeAreaLayoutGuide).offset(16)
            $0.centerY.equalToSuperview()
            $0.size.equalTo(16)
        }
        field.snp.makeConstraints {
            $0.leading.equalTo(icon.snp.trailing).offset(8)
            $0.top.bottom.equalToSuperview().inset(8)
            $0.height.greaterThanOrEqualTo(28).priority(.high)
        }
        divider.snp.makeConstraints {
            $0.leading.equalTo(field.snp.trailing).offset(8)
            $0.top.bottom.equalToSuperview()
            $0.width.equalTo(0.5)
        }
        cancel.snp.makeConstraints {
            $0.leading.equalTo(divider.snp.trailing).offset(16)
            $0.trailing.equalTo(safeAreaLayoutGuide).offset(-16)
            $0.top.bottom.equalToSuperview()
            $0.width.greaterThanOrEqualTo(28)
        }
        bottom.snp.makeConstraints {
            $0.leading.trailing.bottom.equalToSuperview()
            $0.height.equalTo(0.5)
        }

        backward.image = UIImage(systemName: "chevron.left")
        backward.accessibilityLabel = String(localized: "Find Previous")
        backward.target = self
        backward.action = #selector(findPrevious)
        forward.image = UIImage(systemName: "chevron.right")
        forward.accessibilityLabel = String(localized: "Find Next")
        forward.target = self
        forward.action = #selector(findNext)
        result.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: UIFont(name: "Courier", size: 16)!)
        result.adjustsFontForContentSizeCategory = true
        result.textColor = .label
        result.isAccessibilityElement = true
        dismissKeyboard.image = UIImage(systemName: "keyboard.chevron.compact.down")
        dismissKeyboard.target = self
        dismissKeyboard.action = #selector(hideKeyboard)
        dismissKeyboard.accessibilityLabel = String(localized: "Hide Keyboard")
        toolbar.tintColor = .label
        navigationItems = [
            backward, .fixedSpace(16), forward, .flexibleSpace(),
            UIBarButtonItem(customView: result),
        ]
        toolbar.items = navigationItems
        toolbar.snp.makeConstraints { $0.height.equalTo(44).priority(.high) }
        showResult(current: nil, count: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func focusField() {
        field.becomeFirstResponder()
    }

    func setKeyboardVisible(_ visible: Bool) {
        guard (toolbar.items?.last === dismissKeyboard) != visible else { return }
        toolbar.items = navigationItems + (visible ? [.fixedSpace(16), dismissKeyboard] : [])
    }

    func applyTheme(background: UIColor, foreground: UIColor) {
        backgroundColor = background
        tintColor = foreground
        field.textColor = foreground
        result.textColor = foreground
        cancel.setTitleColor(foreground, for: .normal)
        toolbar.tintColor = foreground
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = background
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
    }

    func showResult(current: Int?, count: Int, searching: Bool = false) {
        result.text = searching ? "…" : String(localized: "\(current.map { $0 + 1 } ?? 0)/\(count)")
        result.accessibilityLabel = searching ? nil : count == 0
            ? String(localized: "No results")
            : String(localized: "\((current ?? 0) + 1) of \(count)")
        result.sizeToFit()
        backward.isEnabled = count > 0 && !searching
        forward.isEnabled = count > 0 && !searching
    }

    @objc private func queryChanged() {
        guard field.markedTextRange == nil else { return }
        onChange?(query)
    }

    @objc private func findNext() {
        onNavigate?(true)
    }

    @objc private func findPrevious() {
        onNavigate?(false)
    }

    @objc private func close() {
        onDismiss?()
    }

    @objc private func hideKeyboard() {
        field.resignFirstResponder()
    }
}

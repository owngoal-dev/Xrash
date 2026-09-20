import SnapKit
import Then
import UIKit

/// A find bar. iOS 16 has `UIFindInteraction` and this becomes four lines the
/// day the deployment target moves; until then it is a text field and two
/// chevrons. Ported from Fila.
final class FindBar: UIView {
    var onFind: ((String, Bool) -> Void)?
    var onDismiss: (() -> Void)?

    private let field = UITextField()
    private let result = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        field.do {
            $0.placeholder = String(localized: "Find")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.borderStyle = .roundedRect
            $0.autocorrectionType = .no
            $0.autocapitalizationType = .none
            $0.returnKeyType = .search
            $0.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
            $0.addTarget(self, action: #selector(findNext), for: .editingDidEndOnExit)
        }
        let backward = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "chevron.up"), for: .normal)
            $0.accessibilityLabel = String(localized: "Find Previous")
            $0.addTarget(self, action: #selector(findPrevious), for: .touchUpInside)
        }
        let forward = UIButton(type: .system).then {
            $0.setImage(UIImage(systemName: "chevron.down"), for: .normal)
            $0.accessibilityLabel = String(localized: "Find Next")
            $0.addTarget(self, action: #selector(findNext), for: .touchUpInside)
        }
        let done = UIButton(type: .system).then {
            $0.setTitle(String(localized: "Done"), for: .normal)
            $0.addTarget(self, action: #selector(close), for: .touchUpInside)
        }
        result.do {
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.textAlignment = .center
            $0.isHidden = true
        }

        let controls = UIStackView(arrangedSubviews: [field, backward, forward, done]).then {
            $0.spacing = 8
            $0.alignment = .center
        }
        let stack = UIStackView(arrangedSubviews: [controls, result]).then {
            $0.axis = .vertical
            $0.spacing = 8
        }
        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.trailing.equalTo(layoutMarginsGuide)
            make.top.equalToSuperview().offset(8)
            make.bottom.equalTo(safeAreaLayoutGuide).offset(-8).priority(.high)
        }
        for button in [backward, forward] {
            button.snp.makeConstraints { make in
                make.width.equalTo(44)
                make.height.greaterThanOrEqualTo(44)
            }
        }
        done.snp.makeConstraints { $0.size.greaterThanOrEqualTo(44) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func focusField() {
        field.becomeFirstResponder()
    }

    func showResult(_ text: String?) {
        result.text = text
        result.isHidden = text == nil
    }

    @objc private func findNext() {
        onFind?(field.text ?? "", true)
    }

    @objc private func findPrevious() {
        onFind?(field.text ?? "", false)
    }

    @objc private func close() {
        onDismiss?()
    }
}

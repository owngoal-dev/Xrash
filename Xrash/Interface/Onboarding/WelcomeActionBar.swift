import SnapKit
import Then
import UIKit

/// The bar under every welcome page: a rule over a blur, and the page's one
/// button. Ported from Irisin's `WelcomeActionBar`, whose metrics it keeps
/// exactly — the bar is the same size on every page and in every state.
final class WelcomeActionBar: UIView {
    /// Retitled as a page's state changes — "Continue in Background" while the
    /// first pass runs, "Get Started" once it is finished. The title never
    /// changes the bar: one line, shrunk to fit, whatever the translation.
    var title: String {
        didSet {
            guard title != oldValue else { return }
            button.configuration?.title = title
        }
    }

    private let button = UIButton(type: .system)
    private let action: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        super.init(frame: .zero)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        let rule = UIView().then { $0.backgroundColor = .separator }
        addSubview(blur)
        addSubview(rule)
        addSubview(button)

        blur.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        rule.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.height.equalTo(0.5)
        }
        button.snp.makeConstraints { x in
            x.top.equalTo(rule.snp.bottom).offset(12)
            x.leading.trailing.equalToSuperview().inset(WelcomeStyle.horizontalMargin)
            x.bottom.equalTo(safeAreaLayoutGuide).inset(28)
            x.height.equalTo(48)
        }

        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.titleLabel?.font = WelcomeStyle.buttonFont
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = WelcomeStyle.accent
        configuration.baseForegroundColor = .white
        configuration.title = title
        // Not in the original, which titles each page once: a long translation
        // of "Continue in Background" — German and Russian both run long — has
        // to shrink inside the 48 points rather than wrap and take the bar
        // with it.
        configuration.titleLineBreakMode = .byTruncatingTail
        button.configuration = configuration
        button.titleLabel?.do {
            $0.numberOfLines = 1
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.7
        }
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// What Return on a keyboard does. The page owns the key command; the
    /// button is the only thing that knows what it means.
    func activate() {
        action()
    }
}

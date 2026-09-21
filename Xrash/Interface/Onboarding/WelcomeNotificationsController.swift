import AlertController
import Combine
import SnapKit
import Then
import UIKit

/// The last welcome page, and only for someone the system has not asked yet:
/// what a crash notification looks like, and the button that asks.
///
/// The system's prompt is one sentence over two buttons and can be shown once.
/// Asked cold, behind a sheet that has just gone away, it is a question about
/// nothing; asked from here it is the answer to a page that has just shown
/// what is on offer. The second page's skeleton — the same stack at the same
/// margin over the same action bar — with a notification drawn where the
/// stages were.
final class WelcomeNotificationsController: UIViewController {
    private let onFinish: () -> Void

    private lazy var actionBar = WelcomeActionBar(title: String(localized: "Turn On Notifications")) { [weak self] in
        self?.turnOn()
    }

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        // The pass behind this page is over; there is nothing to go back to.
        navigationItem.hidesBackButton = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WelcomeStyle.background
        view.tintColor = WelcomeStyle.accent
        setupLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.tintColor = WelcomeStyle.accent
        // A swipe would leave the switch in Settings on and the system never
        // asked. Both buttons are an answer; the sheet's edge is not.
        navigationController?.isModalInPresentation = true
    }

    /// Return on a keyboard is the button, as on the pages before.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(activatePrimaryButton))]
    }

    @objc private func activatePrimaryButton() {
        actionBar.activate()
    }

    // MARK: Answers

    /// The switch in Settings is what the answer becomes, either way: a
    /// refusal leaves it off rather than on and silent.
    private func turnOn() {
        Task { [weak self] in
            let granted = await CrashNotice.shared.requestAuthorization()
            AppSettings.shared.changePreferences { $0.notifiesOnNewReports = granted }
            self?.onFinish()
        }
    }

    /// Nothing is asked, so the system can still be asked later — from the
    /// switch in Settings, which is where this leaves it, off.
    private func decline() {
        AppSettings.shared.changePreferences { $0.notifiesOnNewReports = false }
        onFinish()
    }

    // MARK: Layout

    private func setupLayout() {
        let heading = UILabel().then {
            $0.text = String(localized: "Crash Notifications")
            $0.font = WelcomeStyle.titleFont
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 1
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.7
        }
        let intro = UILabel().then {
            // The same sentence Settings words its footer with.
            $0.text = ReportFormat.announcementSummary
            $0.font = WelcomeStyle.subtitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        // The drawn notification says what one is; nothing under it repeats it.
        let stack = UIStackView(arrangedSubviews: [heading, intro, WelcomeNoticePreview()]).then {
            $0.axis = .vertical
            $0.spacing = 18
            $0.alignment = .fill
            $0.setCustomSpacing(8, after: heading)
        }

        // The way out that asks nothing, where the page before kept its
        // gauge: over the button, and quieter than it.
        let later = UIButton(type: .system).then {
            var configuration = UIButton.Configuration.plain()
            configuration.title = String(localized: "Not Now")
            configuration.baseForegroundColor = WelcomeStyle.detailColor
            $0.configuration = configuration
            $0.titleLabel?.font = WelcomeStyle.detailFont
            $0.addAction(UIAction { [weak self] _ in self?.decline() }, for: .touchUpInside)
        }

        let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
        scrollView.hideTopEdgeEffect()
        let contentView = UIView()
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        view.addSubview(later)
        view.addSubview(actionBar)

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(later.snp.top).offset(-8)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        stack.snp.makeConstraints { x in
            x.top.equalToSuperview().inset(WelcomeStyle.headingTopMargin)
            x.bottom.equalToSuperview().inset(28)
            x.leading.trailing.equalToSuperview().inset(WelcomeStyle.horizontalMargin)
        }
        later.snp.makeConstraints { x in
            x.centerX.equalToSuperview()
            x.bottom.equalTo(actionBar.snp.top).offset(-8)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }
}

/// A notification as it will arrive, drawn rather than described: this app's
/// icon, `Dopamine Crashed`, and the list row's line under it.
private final class WelcomeNoticePreview: UIView {
    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        isAccessibilityElement = false

        let icon = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 9
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
        }
        let title = UILabel().then {
            // The words the notification itself uses, from the same key.
            $0.text = String(localized: "\("Dopamine") Crashed")
            $0.font = WelcomeStyle.featureTitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.titleColor
        }
        let time = UILabel().then {
            $0.text = ReportFormat.date(Date())
            $0.font = WelcomeStyle.detailFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let body = UILabel().then {
            // A report's own words are in no language.
            $0.text = "EXC_CRASH (SIGABRT) · 0.2.0 (43)"
            $0.font = WelcomeStyle.detailFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.titleColor
            $0.lineBreakMode = .byTruncatingTail
        }
        let headline = UIStackView(arrangedSubviews: [title, time]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .firstBaseline
        }
        let words = UIStackView(arrangedSubviews: [headline, body]).then {
            $0.axis = .vertical
            $0.spacing = 2
            $0.alignment = .fill
        }
        let content = UIStackView(arrangedSubviews: [icon, words]).then {
            $0.axis = .horizontal
            $0.spacing = 12
            $0.alignment = .center
        }
        addSubview(content)
        icon.snp.makeConstraints { x in
            x.width.height.equalTo(38)
        }
        content.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(14)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

extension UIScrollView {
    /// iOS 26 blurs whatever scrolls under the top edge. On a welcome page
    /// that edge is the heading's own margin, and the blur sat on the heading.
    func hideTopEdgeEffect() {
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
        }
    }
}

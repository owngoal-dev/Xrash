import AlertController
import SnapKit
import Then
import UIKit
import UserNotifications

/// The first page of the welcome: the app's mark, a two-line title, what Xrash
/// does, and one button. The welcome is a navigation stack in a sheet: the
/// first pass over the reports comes next, and a page that asks for
/// notifications after it when the system has not asked yet.
///
/// Ported from Irisin's `WelcomeController` (MIT, the same owner): its view
/// hierarchy, metrics, transition and presentation, with Xrash's words, icons
/// and accent.
final class WelcomeController: UIViewController {
    struct Feature {
        let symbol: String
        let title: String.LocalizationValue
        let detail: String.LocalizationValue
    }

    /// The original's sheet, at the size it was drawn for.
    static let sheetSize = CGSize(width: 520, height: 620)

    /// Raise it when the welcome changes enough to be worth showing again.
    /// Kept in preferences, which a cold launch does not clear — only the
    /// saved scene state is thrown away there.
    private static let version = 1
    private static let seenVersionKey = "Welcome.seenVersion"

    static var shouldPresent: Bool {
        UserDefaults.standard.integer(forKey: seenVersionKey) < version
    }

    /// The welcome, on screen — over whatever asked for it. Shown from Settings
    /// on an iPad, that is a sheet presenting a sheet, which is legal because
    /// what presents is the navigation controller Settings sits in and it is
    /// presenting nothing: the welcome lands on top and leaves Settings behind
    /// it, where the reader came from. Nested like that it takes the system's
    /// form sheet size rather than `sheetSize`; see `presentAsFormSheet`.
    static func present(from presenter: UIViewController) {
        let controller = WelcomeController()
        let navigator = SheetNavigationController(rootViewController: controller).then {
            // The first page has no title; the page after it titles itself.
            $0.navigationBar.prefersLargeTitles = true
            $0.view.backgroundColor = WelcomeStyle.background
            $0.view.tintColor = WelcomeStyle.accent
            $0.navigationBar.tintColor = WelcomeStyle.accent
            $0.modalTransitionStyle = .coverVertical
            $0.isModalInPresentation = true
        }
        presenter.presentAsFormSheet(navigator, size: sheetSize, usesDetents: false)
        // Set after the presentation, which is what makes the controller: a
        // sheet swiped away once the work is done still counts as seen.
        navigator.presentationController?.delegate = controller
    }

    /// Ordered by how much a reader cares, most first. Spelled out as
    /// `String.LocalizationValue` because this file imports AlertController,
    /// where a bare literal at a `title:` is the mistake `make check` greps for.
    private static let features: [Feature] = [
        .init(
            symbol: "doc.text.magnifyingglass",
            title: String.LocalizationValue("Read Reports"),
            detail: String.LocalizationValue(
                "Crashes, hangs, kernel panics and out-of-memory reports, as the system wrote them."
            )
        ),
        .init(
            symbol: "function",
            title: String.LocalizationValue("Name the Frames"),
            detail: String.LocalizationValue(
                "System symbols and imported dSYMs turn a stack of addresses into function names."
            )
        ),
        .init(
            symbol: "shippingbox",
            title: String.LocalizationValue("Spot the Suspect"),
            detail: String.LocalizationValue(
                "The packages whose code sits in a crashing stack are named beside it."
            )
        ),
        .init(
            symbol: "hand.raised",
            title: String.LocalizationValue("Nothing Injected"),
            detail: String.LocalizationValue(
                "Xrash opens files and reads them. Nothing is hooked, patched or installed."
            )
        ),
    ]

    private let contentInsets = UIEdgeInsets(
        top: 28,
        left: WelcomeStyle.horizontalMargin,
        bottom: 28,
        right: WelcomeStyle.horizontalMargin
    )
    private let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
    private let contentView = UIView()
    private let stackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 18
        $0.alignment = .fill
        $0.distribution = .fillProportionally
    }

    private lazy var actionBar = WelcomeActionBar(title: String(localized: "Next")) { [weak self] in
        self?.showNextPage()
    }

    private var featureRows: [UIView] = []

    init() {
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
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
        setupContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.tintColor = WelcomeStyle.accent
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !UIAccessibility.isReduceMotionEnabled else {
            return featureRows.forEach { $0.alpha = 1 }
        }
        for (index, row) in featureRows.enumerated() {
            UIView.animate(
                withDuration: 0.5,
                delay: 0.1 * Double(index),
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0.4,
                options: [.curveEaseInOut]
            ) {
                row.alpha = 1
            }
        }
    }

    /// Return on a keyboard is the button, which is what a Mac expects of a
    /// sheet with one of them.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(activatePrimaryButton))]
    }

    @objc private func activatePrimaryButton() {
        actionBar.activate()
    }

    private func setupLayout() {
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stackView)
        view.addSubview(actionBar)

        // The navigation bar stays for the page after this one and is empty
        // here: this page starts at the top of the sheet and scrolls under it.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.hideTopEdgeEffect()
        scrollView.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(actionBar.snp.top)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        stackView.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(contentInsets)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }

    private func setupContent() {
        let icon = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 14
            $0.layer.cornerCurve = .continuous
            $0.layer.shadowColor = WelcomeStyle.iconShadow.cgColor
            $0.layer.shadowRadius = 4
            $0.layer.shadowOffset = .zero
            $0.layer.shadowOpacity = 0.1
            $0.clipsToBounds = true
            $0.isAccessibilityElement = false
        }
        let iconContainer = UIView()
        iconContainer.addSubview(icon)
        icon.snp.makeConstraints { x in
            x.width.height.equalTo(64)
            x.top.bottom.equalToSuperview().inset(64)
            x.centerX.equalToSuperview()
            x.leading.greaterThanOrEqualToSuperview().inset(64)
        }
        stackView.addArrangedSubview(iconContainer)
        stackView.setCustomSpacing(0, after: iconContainer)

        // The translation places the line break and the name; the name is
        // tinted wherever it lands.
        let title = String(localized: "Welcome to\nXrash")
        let titleText = NSMutableAttributedString(string: title, attributes: [
            .font: WelcomeStyle.titleFont,
            .foregroundColor: WelcomeStyle.titleColor,
        ])
        titleText.addAttribute(
            .foregroundColor,
            value: WelcomeStyle.accent,
            range: (title as NSString).range(of: "Xrash")
        )
        stackView.addArrangedSubview(UILabel().then {
            $0.numberOfLines = 0
            $0.textAlignment = .left
            $0.attributedText = titleText
        })

        stackView.addArrangedSubview(UILabel().then {
            $0.text = String(localized: "Crash reports, read and symbolicated.")
            $0.font = WelcomeStyle.subtitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        })

        let rule = UIView().then { $0.backgroundColor = .separator }
        rule.snp.makeConstraints { x in
            x.height.equalTo(0.75)
        }
        stackView.addArrangedSubview(rule)

        for (index, feature) in Self.features.enumerated() {
            let row = WelcomeFeatureRow(feature: feature)
            row.alpha = 0
            featureRows.append(row)
            stackView.addArrangedSubview(row)
            if index < Self.features.count - 1 {
                stackView.setCustomSpacing(10, after: row)
            }
        }

        // Room under the last row before the button bar.
        let spacer = UIView()
        spacer.snp.makeConstraints { x in
            x.height.greaterThanOrEqualTo(12)
        }
        stackView.addArrangedSubview(spacer)
    }

    /// The system asks once and answers from memory after that. So the page
    /// that asks is for someone who has not been asked: on a replay from
    /// Settings, or with an answer given already, the second page is the last
    /// and its button says so.
    private func showNextPage() {
        Task { [weak self] in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard let self else { return }
            let asks = status == .notDetermined
            let page = WelcomePreparingController(
                finishTitle: asks ? String(localized: "Continue") : String(localized: "Get Started")
            ) { [weak self] in
                asks ? self?.showNotificationsPage() : self?.finish()
            }
            navigationController?.pushViewController(page, animated: true)
        }
    }

    private func showNotificationsPage() {
        let page = WelcomeNotificationsController { [weak self] in self?.finish() }
        navigationController?.pushViewController(page, animated: true)
    }

    /// Ends the welcome. The last page's button calls this.
    private func finish() {
        Self.markSeen()
        navigationController?.dismiss(animated: true)
    }

    private static func markSeen() {
        UserDefaults.standard.set(version, forKey: seenVersionKey)
    }
}

extension WelcomeController: UIAdaptivePresentationControllerDelegate {
    /// The last page drops `isModalInPresentation` once its work is done, so
    /// the sheet can also be swiped away. That is not a reason to show the
    /// welcome again.
    func presentationControllerDidDismiss(_: UIPresentationController) {
        Self.markSeen()
    }
}

import AlertController
import Combine
import SnapKit
import Then
import UIKit

/// The one progress card, hosted by `AlertViewController`: a title, the line
/// that says what is happening now, a bar and Cancel. It stays until the work
/// ends and is gone before whoever ran the work says how it went.
///
/// Ported from Fila's `OperationCoverViewController`
/// (`Fila/Interface/Transfers/OperationCoverViewController.swift`) with its
/// job model taken out — Xrash has one kind of long work and one way to stop
/// it. Callers do not build this; they go through `ProgressCard.run`.
final class ProgressCoverViewController: UIViewController {
    /// What the card shows and how it stops the work, so that every long
    /// operation in the app looks and behaves the same.
    struct Source {
        struct Snapshot {
            var title: String
            /// What is being worked on now. Never shown empty.
            var detail: String
            /// Nil while the work cannot say how far along it is.
            var fraction: Double?
            var isCancellable: Bool
        }

        /// Nil once the work is over; the card then closes itself.
        let snapshot: @MainActor () -> Snapshot?
        let changes: AnyPublisher<Void, Never>
        let cancel: @MainActor () -> Void
    }

    /// Work that ends inside this delay never puts a card on the screen at all.
    private static let revealDelay: TimeInterval = 0.35

    private let source: Source
    private var observation: AnyCancellable?
    private var isClosing = false
    /// Fires once this card has finished leaving the screen.
    private var onDismiss: (() -> Void)?

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let cancelButton = UIButton(type: .system)

    /// Presents after the reveal delay, and calls `dismissed` exactly once —
    /// including when the work ended first and no card was ever shown. A
    /// caller with a toast or an alert of its own needs that: one presented
    /// into this card's dismissal never appears.
    static func present(
        _ source: Source,
        from presenter: UIViewController,
        dismissed: @escaping () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak presenter] in
            try? await Task.sleep(nanoseconds: UInt64(revealDelay * 1_000_000_000))
            guard !Task.isCancelled, let presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil, !presenter.isBeingDismissed,
                  source.snapshot() != nil
            else { return dismissed() }
            let content = ProgressCoverViewController(source: source)
            content.onDismiss = dismissed
            let alert = AlertViewController(contentViewController: content)
            presenter.present(alert, animated: true) { content.update() }
            if alert.presentingViewController == nil {
                content.onDismiss = nil
                dismissed()
            }
        }
    }

    private init(source: Source) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        update()
        observation = source.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        update()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation = nil
        // Here rather than in `close`: the screen underneath can take this
        // card down without asking, and whoever waits for it to be gone is
        // told once, whichever way it went.
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }

    private func build() {
        // Fila's card: a half-strength fill over a material, so the rows
        // underneath are hinted at rather than read through.
        view.backgroundColor = AlertControllerConfiguration.backgroundColor.withAlphaComponent(0.5)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.addSubview(material)
        material.snp.makeConstraints { $0.edges.equalToSuperview() }

        titleLabel.do {
            $0.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.textColor = .label
            $0.numberOfLines = 0
        }
        detailLabel.do {
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textAlignment = .center
            $0.textColor = .label
            $0.numberOfLines = 2
            $0.lineBreakMode = .byTruncatingMiddle
        }
        spinner.hidesWhenStopped = true
        bar.progressTintColor = AlertControllerConfiguration.accentColor
        let gauge = UIView()
        gauge.addSubview(bar)
        gauge.addSubview(spinner)
        gauge.snp.makeConstraints { $0.height.equalTo(24) }
        bar.snp.makeConstraints { $0.leading.trailing.centerY.equalToSuperview() }
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }

        configureCancelButton()

        // The avatar every other alert card carries, at the library's size.
        let artwork = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 12
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
        }
        let artworkRow = UIView()
        artworkRow.addSubview(artwork)
        artwork.snp.makeConstraints {
            $0.size.equalTo(64)
            $0.top.bottom.centerX.equalToSuperview()
        }

        let stack = UIStackView(arrangedSubviews: [
            artworkRow, titleLabel, detailLabel, gauge, cancelButton,
        ]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 16
        }
        // The card keeps its compact shape at ordinary text sizes and scrolls
        // when accessibility text outgrows it.
        let scroll = UIScrollView()
        view.addSubview(scroll)
        scroll.snp.makeConstraints { $0.edges.equalToSuperview() }
        scroll.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalTo(scroll.contentLayoutGuide).inset(16)
            $0.width.equalTo(scroll.frameLayoutGuide).offset(-32)
        }
        view.snp.makeConstraints { $0.height.equalTo(stack).offset(32).priority(.high) }
        for child in stack.arrangedSubviews {
            child.snp.makeConstraints { $0.width.equalTo(stack) }
        }
    }

    /// The alert library fills a card's only action, so the card's only button
    /// is filled. The library owns the card's width, radius and presentation.
    private func configureCancelButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Cancel")
        configuration.baseForegroundColor = AlertControllerConfiguration.accentForegroundColor
        configuration.background.backgroundColor = AlertControllerConfiguration.accentColor
        configuration.background.cornerRadius = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            return outgoing
        }
        cancelButton.do {
            $0.configuration = configuration
            // A fill does not dim with its title; work that cannot stop
            // part-way must not look pressable.
            $0.configurationUpdateHandler = { $0.alpha = $0.isEnabled ? 1 : 0.4 }
            $0.titleLabel?.numberOfLines = 0
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.addAction(UIAction { [weak self] _ in self?.cancel() }, for: .touchUpInside)
        }
        cancelButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    }

    private func cancel() {
        guard source.snapshot()?.isCancellable == true else { return }
        // Before the card leaves, not after: work that ends during the
        // dismissal was still cancelled, and the caller waits for the card to
        // be gone before it presents anything.
        source.cancel()
        close()
    }

    private func update() {
        guard !isClosing else { return }
        guard let snapshot = source.snapshot() else {
            // The first change can arrive while the card is still presenting.
            if parent?.presentingViewController != nil, parent?.isBeingPresented == false {
                close()
            }
            return
        }
        titleLabel.text = snapshot.title
        detailLabel.text = snapshot.detail.isEmpty ? String(localized: "Preparing…") : snapshot.detail
        if let fraction = snapshot.fraction {
            bar.isHidden = false
            bar.setProgress(Float(min(max(fraction, 0), 1)), animated: !UIAccessibility.isReduceMotionEnabled)
            spinner.stopAnimating()
        } else {
            bar.isHidden = true
            spinner.startAnimating()
        }
        cancelButton.isEnabled = snapshot.isCancellable
    }

    private func close() {
        guard !isClosing, let alert = parent else { return }
        isClosing = true
        observation = nil
        cancelButton.isEnabled = false
        alert.dismiss(animated: true)
    }
}

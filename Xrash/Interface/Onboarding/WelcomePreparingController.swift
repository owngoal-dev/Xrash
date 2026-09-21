import Combine
import SnapKit
import Then
import UIKit
import XrashClient
import XrashSymbols

/// The second welcome page: the first pass over the reports, while it happens.
/// The first page's skeleton — scroll view, one content stack at the same
/// margin, the same action bar pinned to the bottom — with the icon block
/// replaced by a heading and the rows replaced by stages.
///
/// Nothing here is a stage invented for a progress bar. A first launch spends
/// its time on three things and these are they — the handshake with the helper,
/// the listing, which opens every report for its header, and the extraction of
/// the shared cache's symbols, which is the only long one. The extraction stays
/// the choice it is on the Symbols page: offered here, off until it is asked
/// for, and running the same code the Symbols page runs.
///
/// Every row, the bar and the line under it are laid out at their final size
/// before any of them has anything to say, and a state change swaps text,
/// alpha and nothing else: a page that reports progress may not move while it
/// does it. `Continue in Background` leaves whatever is still running to finish
/// on its own; once nothing is, the button is `Get Started` and the list behind
/// this sheet is already filled.
final class WelcomePreparingController: UIViewController {
    private let onFinish: () -> Void
    private let environment: AppEnvironment
    private var observers = Set<AnyCancellable>()

    private var helperStatus = BackendStatus.connecting
    /// A miss is not a failure: the helper is on demand, and past its grace
    /// period the app reads what it can on its own.
    private var helperState: WelcomeStageRow.State {
        switch helperStatus {
        case .connecting: .running
        case .privileged: .done
        case .sandboxed: .skipped
        }
    }

    private var reportsState = WelcomeStageRow.State.running
    private var reportsProgress: (read: Int, total: Int)?
    private var reportsCount = 0
    private var symbolsState = WelcomeStageRow.State.waiting
    private var symbolsFraction = 0.0
    /// The image the extraction is on now, as it names it.
    private var symbolsItem = ""
    private var symbolsSet: SystemSymbolSet?
    private var symbolsTask: Task<Void, Never>?

    private lazy var symbolsSwitch = UISwitch().then {
        $0.addAction(UIAction { [weak self] _ in self?.symbolsSwitchChanged() }, for: .valueChanged)
    }

    private lazy var helperRow = WelcomeStageRow(
        symbol: "gearshape.2",
        title: String(localized: "Helper")
    )
    private lazy var reportsRow = WelcomeStageRow(
        symbol: "list.bullet.rectangle",
        title: String(localized: "Reading Reports")
    )
    private lazy var symbolsRow = WelcomeStageRow(
        symbol: "cpu",
        title: String(localized: "System Symbols"),
        // The running detail is an image name, whose tail is the telling half.
        truncation: .byTruncatingMiddle,
        control: symbolsSwitch
    )

    private let bar = UIProgressView(progressViewStyle: .default)
    /// Its own slot, wide enough for "100%", so the line beside it does not
    /// move as the number grows.
    private let percentLabel = UILabel()
    private let itemLabel = UILabel()
    private var percentWidth: Constraint?
    /// What the button says once nothing is running: `Get Started` when this
    /// is the last page, `Continue` when one follows.
    private let finishTitle: String
    private lazy var actionBar = WelcomeActionBar(title: finishTitle) { [weak self] in
        self?.onFinish()
    }

    init(environment: AppEnvironment = .shared, finishTitle: String, onFinish: @escaping () -> Void) {
        self.environment = environment
        self.finishTitle = finishTitle
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        // As on the first page, and for the same reason: the bar is empty on
        // both, so nothing above the content moves when this page arrives.
        navigationItem.largeTitleDisplayMode = .never
        // Back from a pass that is already running leads nowhere: this page
        // owns the rest of the welcome.
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
        observe()
        start()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.tintColor = WelcomeStyle.accent
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else {
            return
        }
        percentWidth?.update(offset: Self.percentSlotWidth)
    }

    /// Return on a keyboard is the button, which is what a Mac expects of a
    /// sheet with one of them.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(activatePrimaryButton))]
    }

    @objc private func activatePrimaryButton() {
        actionBar.activate()
    }

    // MARK: Layout

    private func setupLayout() {
        let heading = UILabel().then {
            $0.text = String(localized: "Getting Ready")
            $0.font = WelcomeStyle.titleFont
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 1
        }
        let intro = UILabel().then {
            $0.text = String(localized: "Xrash is reading the reports already on this device.")
            $0.font = WelcomeStyle.subtitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        let rows = UIStackView(arrangedSubviews: [helperRow, reportsRow, symbolsRow]).then {
            $0.axis = .vertical
            // The first page's row spacing.
            $0.spacing = 10
            $0.alignment = .fill
        }
        let footnote = UILabel().then {
            $0.text = String(localized: "System symbols can also be extracted later on the Symbols page.")
            $0.font = WelcomeStyle.detailFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        // The first page's stack, at its spacing and its margins.
        let stack = UIStackView(arrangedSubviews: [heading, intro, rows, footnote]).then {
            $0.axis = .vertical
            $0.spacing = 18
            $0.alignment = .fill
            $0.setCustomSpacing(8, after: heading)
        }

        bar.do {
            $0.progressTintColor = WelcomeStyle.accent
            $0.isAccessibilityElement = true
            $0.accessibilityLabel = String(localized: "Overall progress")
        }
        percentLabel.do {
            $0.font = WelcomeStyle.counterFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 1
            // At the end of the line, in a slot of its own width: what is
            // being worked on keeps the page's margin, and the number that
            // grows from 9% to 100% moves nothing.
            $0.textAlignment = .right
        }
        itemLabel.do {
            $0.font = WelcomeStyle.counterFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 1
            $0.lineBreakMode = .byTruncatingMiddle
        }
        let caption = UIStackView(arrangedSubviews: [itemLabel, percentLabel]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .firstBaseline
        }
        // The bar speaks for the whole page, so it does not scroll away with
        // the rows: it sits over the button, where the eye already is, and it
        // is there from the first frame.
        let gauge = UIStackView(arrangedSubviews: [bar, caption]).then {
            $0.axis = .vertical
            $0.spacing = 8
            $0.alignment = .fill
        }

        let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
        scrollView.hideTopEdgeEffect()
        let contentView = UIView()
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        view.addSubview(gauge)
        view.addSubview(actionBar)

        // The first page's scroll view, to the point of the inset behaviour:
        // both pages start at the top of the sheet under an empty bar.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(gauge.snp.top).offset(-16)
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
        percentLabel.snp.makeConstraints { x in
            percentWidth = x.width.equalTo(Self.percentSlotWidth).constraint
        }
        gauge.snp.makeConstraints { x in
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(WelcomeStyle.horizontalMargin)
            x.bottom.equalTo(actionBar.snp.top).offset(-16)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }

    /// Wide enough for the longest percentage the bar can show.
    private static var percentSlotWidth: CGFloat {
        let text = 1.0.formatted(.percent.precision(.fractionLength(0))) as NSString
        return ceil(text.size(withAttributes: [.font: WelcomeStyle.counterFont]).width)
    }

    // MARK: The work

    private func observe() {
        environment.backend.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                helperStatus = status
                render()
            }
            .store(in: &observers)

        environment.library.listingProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.reportsProgress = progress
                self?.render()
            }
            .store(in: &observers)
    }

    private func start() {
        let backend = environment.backend
        let library = environment.library
        // Extracted on an earlier run — the welcome can be shown again from
        // Settings: say what is stored rather than offer the gigabyte twice.
        if let set = environment.systemSymbols.sets.max(by: { $0.extracted < $1.extracted }) {
            symbolsSet = set
            symbolsState = .done
            symbolsFraction = 1
        }
        // The listing asks the same question, but the row says "Connecting…"
        // from the first frame rather than once the first open needs an answer.
        Task { _ = await backend.resolve() }

        // A welcome shown again from Settings must not read every header a
        // second time: a library that has already listed says so at once. A
        // pass that is running is joined rather than started — `refresh()`
        // hands back the one in flight.
        guard library.isLoading.value || library.summaries.value.isEmpty else {
            reportsState = .done
            reportsCount = library.summaries.value.count
            return
        }
        Task { [weak self] in
            await library.refresh()
            guard let self else { return }
            reportsState = .done
            reportsCount = library.summaries.value.count
            render()
        }
    }

    private func symbolsSwitchChanged() {
        guard symbolsSwitch.isOn else { return }
        // Nothing turns it back off: the extraction cannot be stopped part-way
        // once the cache is being walked, and a switch that promised otherwise
        // would be a lie. `Continue in Background` is the way out of waiting.
        symbolsSwitch.isEnabled = false
        extractSystemSymbols()
    }

    /// The Symbols page's own extraction, driven by this page's rows instead of
    /// the progress card.
    private func extractSystemSymbols() {
        guard symbolsTask == nil else { return }
        symbolsState = .running
        symbolsFraction = 0
        render()
        // The reader is watching a bar, not touching the screen: nothing else
        // keeps the device from locking mid-run.
        UIApplication.shared.isIdleTimerDisabled = true

        let backend = environment.backend
        let store = environment.systemSymbols
        let onProgress: @MainActor (Double, String) -> Void = { [weak self] fraction, image in
            guard let self else { return }
            symbolsFraction = fraction
            symbolsItem = image
            render()
        }
        symbolsTask = Task { [weak self] in
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                // Never cancelled, and the page is held weakly: `Continue in
                // Background` takes this page away and the extraction runs on.
                let set = try await store.extractCurrentSystem(
                    openImage: { try await backend.openImage(at: $0) },
                    progress: { fraction, image in
                        Task { @MainActor in onProgress(fraction, image) }
                    }
                )
                self?.symbolsSet = set
                self?.symbolsState = .done
            } catch {
                self?.symbolsState = .skipped
            }
            self?.symbolsFraction = 1
            self?.symbolsItem = ""
            self?.render()
        }
    }

    // MARK: What it looks like

    private func render() {
        helperRow.update(helperState, detail: helperDetail)
        reportsRow.update(reportsState, detail: reportsDetail)
        symbolsRow.update(symbolsState, detail: symbolsDetail)
        bar.setProgress(Float(overallFraction), animated: !UIAccessibility.isReduceMotionEnabled)
        percentLabel.text = overallFraction.formatted(.percent.precision(.fractionLength(0)))
        // Alpha, never `isHidden`: the line keeps its place whether or not
        // there is a number to put in it.
        percentLabel.alpha = isWorking ? 1 : 0
        itemLabel.text = workingDetail ?? String(localized: "Ready")
        actionBar.title = isWorking
            ? String(localized: "Continue in Background")
            : finishTitle
        // Only while something is running: once it is not, the sheet can go
        // the way any other sheet goes, and either way the welcome is seen.
        navigationController?.isModalInPresentation = isWorking
    }

    private var isWorking: Bool {
        [helperState, reportsState, symbolsState].contains(.running)
    }

    /// The mean of the stages that are going to run. The extraction counts only
    /// once it has been asked for; a bar that sat at two thirds because of an
    /// offer nobody took would be saying the wrong thing.
    private var overallFraction: Double {
        var fractions = [helperState == .running ? 0 : 1, reportsFraction]
        if symbolsState != .waiting {
            fractions.append(symbolsFraction)
        }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    private var reportsFraction: Double {
        guard reportsState != .done else { return 1 }
        guard let progress = reportsProgress, progress.total > 0 else { return 0 }
        return Double(progress.read) / Double(progress.total)
    }

    private var helperDetail: String {
        switch helperStatus {
        case .connecting: String(localized: "Connecting…")
        case .privileged: String(localized: "Every report can be opened.")
        case .sandboxed: String(localized: "Reading only the reports the app can open without the helper.")
        }
    }

    private var reportsDetail: String {
        if reportsState == .done {
            return String(inflecting: "^[\(reportsCount) report](inflect: true)")
        }
        guard let progress = reportsProgress else {
            return String(localized: "Looking for reports…")
        }
        return String(localized: "\(progress.read) of \(progress.total)")
    }

    private var symbolsDetail: String {
        switch symbolsState {
        case .waiting:
            String(localized: "Names the system frames. About a gigabyte and several minutes.")
        case .running:
            symbolsItem.isEmpty ? String(localized: "Reading the shared cache…") : symbolsItem
        case .done:
            [
                String(inflecting: "^[\(symbolsSet?.imageCount ?? 0) image](inflect: true)"),
                ReportFormat.byteCount(symbolsSet?.byteCount ?? 0),
            ].joined(separator: " · ")
        case .skipped:
            String(localized: "Not extracted. You can try again on the Symbols page.")
        }
    }

    /// What the line under the bar names: whatever is being worked on now.
    private var workingDetail: String? {
        if symbolsState == .running {
            return symbolsDetail
        }
        if reportsState == .running {
            return reportsDetail
        }
        if helperState == .running {
            return helperDetail
        }
        return nil
    }
}

/// One line of the preparing page: what is being done, how far it has got, and
/// a control for as long as it is still a choice.
///
/// Laid out once and never resized. The title and two lines of detail are
/// reserved whether or not there is anything to put on the second line, and the
/// state — a spinner, a mark, or the switch — lives in a slot of the switch's
/// own size, so the labels beside it never move.
private final class WelcomeStageRow: UIView {
    enum State {
        case waiting, running, done, skipped
    }

    /// A switch is 51 by 31; the spinner and the mark sit in the middle of that
    /// same box.
    private static let slotSize = CGSize(width: 51, height: 31)

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let markView = UIImageView()
    private let control: UIView?
    private var reservedHeight: Constraint?

    init(symbol: String, title: String, truncation: NSLineBreakMode = .byTruncatingTail, control: UIView? = nil) {
        self.control = control
        super.init(frame: .zero)

        iconView.do {
            $0.image = UIImage(systemName: symbol)?.applyingSymbolConfiguration(WelcomeStyle.featureSymbol)
            $0.contentMode = .scaleAspectFit
        }
        titleLabel.do {
            $0.text = title
            $0.font = WelcomeStyle.featureTitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 1
        }
        detailLabel.do {
            $0.font = WelcomeStyle.counterFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 2
            $0.lineBreakMode = truncation
        }
        markView.do {
            $0.contentMode = .scaleAspectFit
            $0.preferredSymbolConfiguration = WelcomeStyle.featureSymbol
        }
        spinner.hidesWhenStopped = false

        // Not a stack: the labels are pinned to the top of a box of fixed
        // height, so a detail that is one line instead of two leaves the second
        // line empty rather than moving either of them.
        let contentBox = UIView()
        contentBox.addSubview(titleLabel)
        contentBox.addSubview(detailLabel)
        let slot = UIView()
        slot.addSubview(spinner)
        slot.addSubview(markView)
        control.map { slot.addSubview($0) }

        let stack = UIStackView(arrangedSubviews: [iconView, contentBox, slot]).then {
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
        titleLabel.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
        }
        detailLabel.snp.makeConstraints { x in
            x.top.equalTo(titleLabel.snp.bottom).offset(2)
            x.leading.trailing.equalToSuperview()
        }
        contentBox.snp.makeConstraints { x in
            reservedHeight = x.height.equalTo(Self.reservedHeight).constraint
        }
        slot.snp.makeConstraints { x in
            x.width.equalTo(Self.slotSize.width)
            x.height.equalTo(Self.slotSize.height)
        }
        spinner.snp.makeConstraints { x in
            x.center.equalToSuperview()
        }
        markView.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.width.height.equalTo(22)
        }
        control?.snp.makeConstraints { x in
            x.center.equalToSuperview()
        }
        // A switch has to stay reachable, so a row carrying one is not itself
        // one element; a row without one reads as its title and its state in
        // one breath.
        if let control {
            isAccessibilityElement = false
            accessibilityElements = [titleLabel, detailLabel, control]
            control.accessibilityLabel = title
        } else {
            isAccessibilityElement = true
            accessibilityLabel = title
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else {
            return
        }
        reservedHeight?.update(offset: Self.reservedHeight)
    }

    /// One title line, two detail lines, and the gap between them.
    private static var reservedHeight: CGFloat {
        ceil(WelcomeStyle.featureTitleFont.lineHeight) + 2 + 2 * ceil(WelcomeStyle.counterFont.lineHeight)
    }

    /// Text and alpha, never a size: what a state change is allowed to touch.
    func update(_ state: State, detail: String) {
        detailLabel.text = detail
        accessibilityValue = "\(Self.word(for: state)), \(detail)"
        iconView.tintColor = state == .waiting || state == .skipped ? .secondaryLabel : WelcomeStyle.accent
        control?.alpha = state == .waiting ? 1 : 0
        // Alpha keeps the switch's place but would leave it in the
        // accessibility tree, and a switch nobody can see is not a switch.
        if let control {
            accessibilityElements = state == .waiting
                ? [titleLabel, detailLabel, control]
                : [titleLabel, detailLabel]
        }
        spinner.alpha = state == .running ? 1 : 0
        if state == .running {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        switch state {
        case .done:
            markView.image = UIImage(systemName: "checkmark.circle.fill")
            markView.tintColor = WelcomeStyle.accent
            markView.alpha = 1
        case .skipped:
            markView.image = UIImage(systemName: "minus.circle")
            markView.tintColor = .secondaryLabel
            markView.alpha = 1
        case .waiting, .running:
            markView.alpha = 0
        }
    }

    private static func word(for state: State) -> String {
        switch state {
        case .waiting: String(localized: "Waiting")
        case .running: String(localized: "Working")
        case .done: String(localized: "Done")
        case .skipped: String(localized: "Skipped")
        }
    }
}

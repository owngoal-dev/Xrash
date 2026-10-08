import Combine
import Runestone
import RunestoneLanguageSupport
import SnapKit
import Then
import UIKit

/// A report as text: the classic `.crash` layout, or the `.ips` JSON. Read
/// only — there is nothing here anybody should be editing, so the keyboard
/// never appears and the text is selectable and nothing more.
final class ReportTextViewController: UIViewController {
    enum Language {
        case json
        case plain
    }

    /// Past this, tree-sitter's parse of the whole document before the first
    /// line is drawn is the only thing the grammar contributes.
    private static let highlightByteLimit = 2 * 1024 * 1024

    /// False when this is a segment of `ReportDetailViewController`: the
    /// container owns the navigation item there and offers this screen's menu
    /// inside its own.
    var installsBarItems = true

    /// The same file indented, when there is such a thing: an `.ips` is two
    /// JSON objects on two lines, which is what is on disk and unreadable.
    /// Set by the owner; the menu offers "Format JSON" only when it is.
    var formattedText: (() -> String)?
    private var isFormatted = false
    /// The file's own lines, taken once before the first indenting, so the
    /// menu has something to go back to.
    private var unformattedText: String?

    let textView = SearchableTextView()
    private let findBar = FindBar()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var text: String
    private let language: Language
    private let settings: AppSettings
    private var lineNumbersObserver: AnyCancellable?
    private var pinchStartScale = 1.0
    private var searchTask: Task<Void, Never>?
    private var textIsReady = false
    private var searchAnchor = 0
    private var isFinding = false
    private var isFindTransitioning = false

    init(title: String, text: String, language: Language) {
        self.text = text
        self.language = language
        // Not a default argument: those are evaluated off the main actor.
        settings = .shared
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        if installsBarItems {
            renderBarItems()
        }

        findBar.do {
            $0.isHidden = true
            $0.onChange = { [weak self] _ in self?.updateSearch() }
            $0.onNavigate = { [weak self] forwards in self?.navigateSearch(forwards: forwards) }
            $0.toolbar.isHidden = true
            $0.onDismiss = { [weak self] in self?.toggleFind() }
        }
        textView.do {
            $0.contentInsetAdjustmentBehavior = .always
            $0.kern = 0.3
            $0.lineHeightMultiplier = 1.2
            $0.gutterMinimumCharacterCount = 3
            $0.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
            // A viewer shows the file, not the whitespace inside it.
            $0.showTabs = false
            $0.showSpaces = false
            $0.showNonBreakingSpaces = false
            $0.showLineBreaks = false
            $0.showSoftLineBreaks = false
            $0.spellCheckingType = .no
            $0.lineSelectionDisplayType = .line
            $0.isEditable = false
            $0.verticalOverscrollFactor = 0
            $0.isLineWrappingEnabled = settings.preferences.value.wrapsLines
            // A long line scrolls sideways, but its indicator draws a grey
            // rule above the bottom bar that reads as a divider.
            $0.showsHorizontalScrollIndicator = false
        }
        let numberedInsets = textView.textContainerInset
        lineNumbersObserver = settings.preferences
            .map(\.showsLineNumbers)
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self else { return }
                textView.showLineNumbers = value ?? (traitCollection.userInterfaceIdiom != .phone)
                var insets = numberedInsets
                if !textView.showLineNumbers {
                    insets.left = 16
                    insets.right = 16
                }
                textView.textContainerInset = insets
            }

        let stack = UIStackView(arrangedSubviews: [textView, findBar.toolbar]).then { $0.axis = .vertical }
        view.addSubview(stack)
        view.addSubview(findBar)
        findBar.snp.makeConstraints { make in
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.equalToSuperview()
        }
        view.addSubview(spinner)
        if #available(iOS 17.0, *) {
            view.keyboardLayoutGuide.usesBottomSafeArea = false
        }
        // Up to the screen edge, not the safe area: the text view insets its
        // own content under the bar, and stopping short leaves the gutter
        // ending in a white band.
        stack.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
        // The safe area's centre: from iOS 26 the view runs under the sidebar.
        spinner.snp.makeConstraints { $0.center.equalTo(view.safeAreaLayoutGuide) }
        textView.addGestureRecognizer(
            UIPinchGestureRecognizer(target: self, action: #selector(pinchToScale)),
        )
        if #unavailable(iOS 26.0) {
            navigationItem.scrollEdgeAppearance = UINavigationBarAppearance().then {
                $0.configureWithDefaultBackground()
            }
        }
        // Always indented to start with; the menu goes back to the file's own lines.
        if let formattedText {
            unformattedText = text
            text = formattedText()
            isFormatted = true
        }
        applyText()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        findBar.setKeyboardVisible(
            view.keyboardLayoutGuide.layoutFrame.minY < view.safeAreaLayoutGuide.layoutFrame.maxY,
        )
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        applyTheme()
    }

    // MARK: Text

    /// The same document rendered again — what symbolication produces. The
    /// scroll position is not preserved, because the frames it just filled in
    /// are the reason the reader asked for it.
    func replaceText(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        guard isViewLoaded else { return }
        applyText()
    }

    /// Building the state parses the document, so it happens off the main
    /// thread: a megabyte of panic log otherwise freezes the push animation.
    private func applyText() {
        searchTask?.cancel()
        textIsReady = false
        textView.searchMatches = []
        textView.currentMatch = nil
        spinner.startAnimating()
        let theme = currentTheme()
        let grammar = text.utf8.count <= Self.highlightByteLimit && language == .json
            ? TreeSitterLanguage.json
            : nil
        let text = text
        Task.detached(priority: .userInitiated) {
            let state = grammar.map { TextViewState(text: text, theme: theme, language: $0) }
                ?? TextViewState(text: text, theme: theme)
            await MainActor.run { [weak self] in
                guard let self, self.text == text else { return }
                textView.setState(state)
                view.backgroundColor = theme.backgroundColor
                textView.backgroundColor = theme.backgroundColor
                findBar.applyTheme(background: theme.backgroundColor, foreground: theme.textColor)
                spinner.stopAnimating()
                textIsReady = true
                if isFinding {
                    updateSearch()
                }
            }
        }
    }

    /// The theme alone, never the state: rebuilding the state here would
    /// re-parse the document and lose the selection every time the system
    /// dimmed the screen.
    private func applyTheme() {
        let theme = currentTheme()
        view.backgroundColor = theme.backgroundColor
        textView.theme = theme
        textView.backgroundColor = theme.backgroundColor
        findBar.applyTheme(background: theme.backgroundColor, foreground: theme.textColor)
        textView.refreshSearchHighlights()
    }

    private func currentTheme() -> ScaledEditorTheme {
        ScaledEditorTheme.theme(
            for: traitCollection,
            scale: CGFloat(settings.preferences.value.textScale),
        )
    }

    // MARK: Bar

    private func renderBarItems() {
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuElements() ?? [])
                },
            ]),
        )
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = more
    }

    /// Offered by whoever owns the bar — this screen when it is pushed, the
    /// detail container when it is a segment.
    func menuElements() -> [UIMenuElement] {
        let preferences = settings.preferences.value
        let find = UIAction(title: String(localized: "Find"), image: UIImage(systemName: "magnifyingglass")) {
            [weak self] _ in
            self?.toggleFind()
        }
        let wrap = UIAction(
            title: String(localized: "Wrap Lines"),
            // `text.word.spacing` is an iOS 16 symbol and draws nothing on 15.
            image: UIImage(systemName: "arrow.turn.down.left"),
            state: preferences.wrapsLines ? .on : .off,
        ) { [weak self] _ in
            self?.settings.changePreferences { $0.wrapsLines.toggle() }
            self?.textView.isLineWrappingEnabled = self?.settings.preferences.value.wrapsLines ?? false
        }
        let lineNumbers = UIAction(
            title: String(localized: "Line Numbers"),
            image: UIImage(systemName: "list.number"),
            state: textView.showLineNumbers ? .on : .off,
        ) { [weak self] _ in
            guard let self else { return }
            let showsLineNumbers = !textView.showLineNumbers
            settings.changePreferences { $0.showsLineNumbers = showsLineNumbers }
        }
        let size = UIMenu(title: String(localized: "Text Size"), image: UIImage(systemName: "textformat.size"), children: [
            UIAction(title: String(localized: "Larger"), image: UIImage(systemName: "plus.magnifyingglass")) {
                [weak self] _ in
                self?.changeTextScale(by: 0.1)
            },
            UIAction(title: String(localized: "Smaller"), image: UIImage(systemName: "minus.magnifyingglass")) {
                [weak self] _ in
                self?.changeTextScale(by: -0.1)
            },
            UIAction(title: String(localized: "Default Size"), image: UIImage(systemName: "1.magnifyingglass")) {
                [weak self] _ in
                self?.settings.changePreferences { $0.textScale = 1 }
                self?.applyTheme()
            },
        ])
        let copy = UIAction(title: String(localized: "Copy All"), image: UIImage(systemName: "doc.on.doc")) {
            [weak self] _ in
            UIPasteboard.general.string = self?.text
            Toast.show(String(localized: "Copied"))
        }
        let share = UIAction(title: String(localized: "Share…"), image: UIImage(systemName: "square.and.arrow.up")) {
            [weak self] _ in
            self?.share()
        }
        let tail = UIMenu(options: .displayInline, children: [copy, share])
        guard formattedText != nil else { return [find, wrap, lineNumbers, size, tail] }
        let format = UIAction(
            title: String(localized: "Format JSON"),
            image: UIImage(systemName: "curlybraces"),
            state: isFormatted ? .on : .off,
        ) { [weak self] _ in
            self?.toggleFormatted()
        }
        return [find, wrap, lineNumbers, format, size, tail]
    }

    private func toggleFormatted() {
        guard let formattedText else { return }
        isFormatted.toggle()
        if isFormatted {
            replaceText(formattedText())
        } else if let unformattedText {
            replaceText(unformattedText)
        }
    }

    private func changeTextScale(by delta: Double) {
        setTextScale(settings.preferences.value.textScale + delta)
    }

    private func setTextScale(_ scale: Double) {
        settings.changePreferences { $0.textScale = min(2.5, max(0.6, scale)) }
        applyTheme()
    }

    /// Pinching a page of text is what everyone tries first. The gesture's own
    /// scale is relative to where the fingers started, so the stored value is
    /// taken once at `.began` and multiplied from there.
    @objc private func pinchToScale(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinchStartScale = settings.preferences.value.textScale
        }
        guard gesture.state == .changed || gesture.state == .ended else { return }
        setTextScale(pinchStartScale * Double(gesture.scale))
    }

    private func share() {
        let name = (title ?? "Report").replacingOccurrences(of: "/", with: "-")
        guard let url = try? ReportShare.file(
            named: "\(name).\(language == .json ? "json" : "txt")",
            text: text,
        ) else {
            return presentMessage("Unable to Share", message: "The file could not be created. Try again.")
        }
        ReportShare.present([url], from: self, source: view)
    }

    // MARK: Find

    private func toggleFind() {
        guard !isFindTransitioning else { return }
        isFindTransitioning = true
        view.layoutIfNeeded()
        isFinding.toggle()
        if isFinding {
            findBar.isHidden = false
            findBar.toolbar.isHidden = false
            searchAnchor = textView.selectedRange.location
            findBar.focusField()
            view.layoutIfNeeded()
        } else {
            searchTask?.cancel()
            findBar.endEditing(true)
            textView.searchMatches = []
            textView.currentMatch = nil
        }
        findBar.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            if isFinding {
                make.top.equalTo(view.safeAreaLayoutGuide)
            } else {
                make.bottom.equalTo(view.safeAreaLayoutGuide.snp.top)
            }
        }
        // Keep the document's existing edge-to-edge layout outside search.
        if let stack = textView.superview as? UIStackView {
            stack.snp.remakeConstraints { make in
                make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
                if !isFinding {
                    make.top.equalToSuperview()
                } else {
                    make.top.equalTo(findBar.snp.bottom)
                    make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide)
                }
                make.bottom.equalTo(view.keyboardLayoutGuide.snp.top).priority(.high)
            }
        }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.findBar.toolbar.isHidden = !self.isFinding
            self.view.layoutIfNeeded()
        } completion: { _ in
            self.findBar.isHidden = !self.isFinding
            self.isFindTransitioning = false
        }
        if isFinding { updateSearch() }
    }

    private func updateSearch() {
        searchTask?.cancel()
        let query = findBar.query
        // Keep the current hit while a query is refined through several
        // keystrokes, including while the previous debounce is pending.
        if let index = textView.currentMatch {
            searchAnchor = textView.searchMatches[index].location
        }
        let anchor = searchAnchor
        textView.currentMatch = nil
        textView.searchMatches = []
        findBar.showResult(current: nil, count: 0, searching: !query.isEmpty)
        guard textIsReady, !query.isEmpty, isFinding else { return }
        let text = text
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 330_000_000) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                ReportTextSearch.matches(in: text, query: query)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            textView.searchMatches = matches
            if !matches.isEmpty {
                let index = ReportTextSearch.firstMatch(in: matches, after: anchor)
                textView.currentMatch = index < matches.count ? index : 0
                textView.revealCurrentMatch()
            }
            findBar.showResult(current: textView.currentMatch, count: matches.count)
        }
    }

    private func navigateSearch(forwards: Bool) {
        let count = textView.searchMatches.count
        guard count > 0 else { return }
        let index = textView.currentMatch ?? (forwards ? -1 : 0)
        textView.currentMatch = (index + (forwards ? 1 : -1) + count) % count
        textView.revealCurrentMatch()
        findBar.showResult(current: textView.currentMatch, count: count)
    }

    deinit { searchTask?.cancel() }
}

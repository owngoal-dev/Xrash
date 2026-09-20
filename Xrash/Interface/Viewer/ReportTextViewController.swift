import Combine
import RunestoneEditor
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
    private var unformattedText: String?

    let textView = RunestoneEditorView.new()
    private let findBar = FindBar()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var text: String
    private let language: Language
    private let settings: AppSettings
    private var pinchStartScale = 1.0

    init(title: String, text: String, language: Language, settings: AppSettings = .shared) {
        self.text = text
        self.language = language
        self.settings = settings
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
            $0.onFind = { [weak self] term, forwards in self?.find(term, forwards: forwards) }
            $0.onDismiss = { [weak self] in self?.toggleFind() }
        }
        textView.do {
            // A viewer shows the file, not the whitespace inside it.
            $0.showTabs = false
            $0.showSpaces = false
            $0.showNonBreakingSpaces = false
            $0.showLineBreaks = false
            $0.showSoftLineBreaks = false
            $0.spellCheckingType = .no
            $0.lineSelectionDisplayType = .line
            $0.isEditable = false
            $0.isLineWrappingEnabled = settings.preferences.value.wrapsLines
            // A long line scrolls sideways, but its indicator draws a grey
            // rule above the bottom bar that reads as a divider.
            $0.showsHorizontalScrollIndicator = false
        }

        let stack = UIStackView(arrangedSubviews: [textView, findBar]).then { $0.axis = .vertical }
        view.addSubview(stack)
        view.addSubview(spinner)
        if #available(iOS 17.0, *) {
            view.keyboardLayoutGuide.usesBottomSafeArea = false
        }
        // Up to the screen edge, not the safe area: the text view insets its
        // own content under the bar, and stopping short leaves the gutter
        // ending in a white band.
        stack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
        spinner.snp.makeConstraints { $0.center.equalToSuperview() }
        textView.addGestureRecognizer(
            UIPinchGestureRecognizer(target: self, action: #selector(pinchToScale))
        )
        if #unavailable(iOS 26.0) {
            navigationItem.scrollEdgeAppearance = UINavigationBarAppearance().then {
                $0.configureWithDefaultBackground()
            }
        }
        if settings.preferences.value.formatsJSON, let formattedText {
            unformattedText = text
            text = formattedText()
            isFormatted = true
        }
        applyText()
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
                guard let self else { return }
                textView.setState(state)
                textView.backgroundColor = theme.backgroundColor
                spinner.stopAnimating()
            }
        }
    }

    /// The theme alone, never the state: rebuilding the state here would
    /// re-parse the document and lose the selection every time the system
    /// dimmed the screen.
    private func applyTheme() {
        let theme = currentTheme()
        textView.theme = theme
        textView.backgroundColor = theme.backgroundColor
    }

    private func currentTheme() -> ScaledEditorTheme {
        ScaledEditorTheme.theme(
            for: traitCollection,
            scale: CGFloat(settings.preferences.value.textScale)
        )
    }

    // MARK: Bar

    private func renderBarItems() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuElements() ?? [])
                },
            ])
        )
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
            state: preferences.wrapsLines ? .on : .off
        ) { [weak self] _ in
            self?.settings.changePreferences { $0.wrapsLines.toggle() }
            self?.textView.isLineWrappingEnabled = self?.settings.preferences.value.wrapsLines ?? false
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
        guard formattedText != nil else { return [find, wrap, size, tail] }
        let format = UIAction(
            title: String(localized: "Format JSON"),
            image: UIImage(systemName: "curlybraces"),
            state: isFormatted ? .on : .off
        ) { [weak self] _ in
            self?.toggleFormatted()
        }
        return [find, wrap, format, size, tail]
    }

    private func toggleFormatted() {
        guard let formattedText else { return }
        isFormatted.toggle()
        if isFormatted {
            unformattedText = text
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
            text: text
        ) else {
            return presentMessage("Unable to Share", message: "The file could not be created. Try again.")
        }
        ReportShare.present([url], from: self, source: view)
    }

    // MARK: Find

    private func toggleFind() {
        findBar.isHidden.toggle()
        if findBar.isHidden {
            findBar.endEditing(true)
        } else {
            findBar.focusField()
        }
    }

    private func find(_ term: String, forwards: Bool) {
        guard !term.isEmpty else { return findBar.showResult(nil) }
        let text = textView.text as NSString
        let selection = textView.selectedRange
        var first: NSRange?
        var last: NSRange?
        var target: NSRange?
        var count = 0
        var current = 0
        var position = 0
        while position < text.length {
            let match = text.range(
                of: term,
                options: [.caseInsensitive],
                range: NSRange(location: position, length: text.length - position)
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            count += 1
            if first == nil {
                first = match
            }
            last = match
            let isNext = target == nil && match.location >= NSMaxRange(selection)
            if forwards ? isNext : NSMaxRange(match) <= selection.location {
                target = match
                current = count
            }
            position = NSMaxRange(match)
        }
        guard let first, let last else { return findBar.showResult(String(localized: "No results")) }
        if target == nil {
            target = forwards ? first : last
            current = forwards ? 1 : count
        }
        guard let target else { return }
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
        findBar.showResult(String(localized: "\(current) of \(count)"))
    }
}

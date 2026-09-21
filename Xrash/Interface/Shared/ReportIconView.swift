import UIKit
import XrashReport

/// The leading tile of a report row: the app's own icon when the system still
/// has one, otherwise artwork standing in for it — a terminal for a process, a
/// log for everything else. Every row gets a tile of the same size so the
/// titles line up whichever it is.
final class ReportIconView: UIView {
    static let size: CGFloat = 38

    private let imageView = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var shownKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.size, height: Self.size)
    }

    /// `executablePath` is known only once the report has been decoded; until
    /// then the bundle id from the header is what finds the icon.
    func configure(with summary: ReportSummary, executablePath: String? = nil) {
        let key = "\(summary.id)|\(summary.bundleID ?? "")|\(executablePath ?? "")"
        guard key != shownKey else { return }
        shownKey = key
        loadTask?.cancel()
        // A process is a picture, as in Inspector: the terminal artwork until
        // (and unless) the app's own icon turns up. A report about no single
        // process is a picture too — the system's own log artwork. A symbol
        // in a grey tile among app icons read as a control, not a report.
        switch summary.group {
        case .app, .service: showPicture(UIImage(named: "TerminalIcon"))
        default: showPicture(UIImage(named: "LogIcon"))
        }

        // A panic belongs to no app, so it wears this one's icon: a picture
        // among pictures, where a grey symbol tile read as a control.
        let bundleID = summary.kind == .panic ? Bundle.main.bundleIdentifier : summary.bundleID
        guard summary.group == .app || summary.kind == .panic, bundleID != nil || executablePath != nil
        else { return }
        let scale = traitCollection.displayScale
        loadTask = Task { [weak self] in
            let icon = await ApplicationIconProvider.shared.icon(
                bundleID: bundleID,
                executablePath: executablePath,
                scale: scale
            )
            guard !Task.isCancelled, let self, let icon, shownKey == key else { return }
            showPicture(icon)
        }
    }

    private func showPicture(_ image: UIImage?) {
        backgroundColor = .clear
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.tintColor = nil
    }
}

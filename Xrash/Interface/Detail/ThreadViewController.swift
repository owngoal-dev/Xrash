import SnapKit
import Then
import UIKit
import XrashReport

/// One thread that was not the one that crashed: its stack, and the registers
/// it was holding when the sample was taken.
final class ThreadViewController: UITableViewController, UISearchResultsUpdating {
    private enum Section: Hashable {
        case frames
        case registers
    }

    private enum Item: Hashable {
        case frame(Int)
        case register(Int)
    }

    private let thread: ReportThread
    private let crash: CrashReport
    private var dataSource: SectionedTableDataSource<Section, Item>!
    private var searchText = ""

    init(thread: ReportThread, crash: CrashReport) {
        self.thread = thread
        self.crash = crash
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = thread.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Thread \(thread.index)")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Frames")
        navigationItem.searchController = search
        definesPresentationContext = true

        tableView.register(FrameCell.self, forCellReuseIdentifier: FrameCell.reuseIdentifier)
        tableView.register(RegisterCell.self, forCellReuseIdentifier: RegisterCell.reuseIdentifier)
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            guard let self else { return UITableViewCell() }
            switch item {
            case let .frame(index):
                let frame = thread.frames[index]
                let cell = tableView.dequeueReusableCell(withIdentifier: FrameCell.reuseIdentifier, for: indexPath)
                (cell as? FrameCell)?.configure(with: frame, index: index, in: crash, emphasis: emphasis(of: frame))
                (cell as? FrameCell)?.menuProvider = { [weak self] in
                    guard let self else { return [] }
                    return frameMenu(frame, in: crash)
                }
                return cell
            case let .register(index):
                let register = thread.registers[index]
                let cell = tableView.dequeueReusableCell(withIdentifier: RegisterCell.reuseIdentifier, for: indexPath)
                (cell as? RegisterCell)?.configure(
                    with: register,
                    note: RegisterNotes.note(for: register, thread: thread, in: crash)
                )
                return cell
            }
        }
        dataSource.header = { section in
            switch section {
            case .frames: String(localized: "Stack")
            case .registers: String(localized: "Registers")
            }
        }
        render()
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchText = searchController.searchBar.text ?? ""
        render()
    }

    private func render() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shownFrames = thread.frames.indices.filter { matches(thread.frames[$0], needle: needle) }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !shownFrames.isEmpty {
            snapshot.appendSections([.frames])
            snapshot.appendItems(shownFrames.map(Item.frame), toSection: .frames)
        }
        // Registers are a property of the thread, not of the search.
        if !thread.registers.isEmpty, needle.isEmpty {
            snapshot.appendSections([.registers])
            snapshot.appendItems(thread.registers.indices.map(Item.register), toSection: .registers)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        tableView.setEmptyState(snapshot.numberOfItems == 0 ? .message(
            symbolName: "magnifyingglass",
            title: String(localized: "No Results"),
            description: String(localized: "No frame in this thread matches “\(needle)”."),
            actionTitle: nil
        ) : nil)
    }

    private func matches(_ frame: Frame, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let image = frame.imageIndex.flatMap { crash.images.indices.contains($0) ? crash.images[$0] : nil }
        return [frame.symbol, image?.name, ReportFormat.address(frame.address)]
            .compactMap(\.self)
            .contains { $0.matches(needle) }
    }

    private func emphasis(of frame: Frame) -> FrameCell.Emphasis {
        guard let index = frame.imageIndex, crash.images.indices.contains(index) else { return .ordinary }
        let image = crash.images[index]
        if image.path == crash.process.path {
            return .own
        }
        return FrameCell.isSystem(image) ? .ordinary : .own
    }
}

/// One register: its name, its value, and what the value is when that can be
/// said — the image an address falls in, the flags in `cpsr`, the exception
/// class in `esr`. Zeros are dimmed so the registers that hold something are
/// the ones the eye lands on. A tap opens the copy menu.
private final class RegisterCell: UITableViewCell {
    static let reuseIdentifier = "register"

    private let nameLabel = UILabel()
    private let valueLabel = UILabel()
    private let noteLabel = UILabel()
    private let menuButton = UIButton(type: .custom)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        let mono = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
        nameLabel.do {
            $0.font = mono
            $0.textColor = .secondaryLabel
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        valueLabel.do {
            $0.font = mono
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        noteLabel.do {
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.textColor = .secondaryLabel
            $0.textAlignment = .right
            $0.lineBreakMode = .byTruncatingMiddle
        }
        for label in [nameLabel, valueLabel, noteLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        let row = UIStackView(arrangedSubviews: [nameLabel, valueLabel, noteLabel]).then {
            $0.alignment = .firstBaseline
            $0.spacing = 10
        }
        contentView.addSubview(row)
        // Wide enough for `cpsr`, so every value starts in the same column.
        nameLabel.snp.makeConstraints { $0.width.equalTo(34) }
        row.snp.makeConstraints { make in
            make.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalToSuperview().inset(8)
        }

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.copyActions() ?? []) },
        ])
        contentView.addSubview(menuButton)
        menuButton.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(with register: Register, note: String?) {
        let value = ReportFormat.address(register.value)
        nameLabel.text = register.name
        valueLabel.text = value
        valueLabel.textColor = register.value == 0 ? .secondaryLabel : .label
        noteLabel.text = note
        accessibilityLabel = [register.name, value, note].compactMap(\.self).joined(separator: ", ")
    }

    private func copyActions() -> [UIMenuElement] {
        let value = valueLabel.text ?? ""
        var actions = [UIAction(title: String(localized: "Copy Value"), image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = value
            Toast.show(String(localized: "Copied"))
        }]
        if let note = noteLabel.text {
            actions.append(UIAction(title: String(localized: "Copy Note"), image: UIImage(systemName: "text.quote")) { _ in
                UIPasteboard.general.string = note
                Toast.show(String(localized: "Copied"))
            })
        }
        return actions
    }
}

import UIKit
import XrashSystemState

/// The collected system-state files: what each one is called, how large it is,
/// and the whole of it in the text viewer. The point of the screen is that
/// nobody has to take the word "system state" on trust — the same list is
/// reached from the Report Crash form before a bundle is built and from a
/// saved bundle afterwards.
///
/// It takes files rather than collecting them, so the form can show exactly
/// what it is about to ship and a saved bundle can show exactly what it did.
final class SystemStateViewController: UITableViewController {
    private let files: [SystemStateFile]
    /// Unpacked for this screen alone, and removed with it.
    private let owned: URL?

    init(files: [SystemStateFile], removing directory: URL? = nil) {
        self.files = files
        owned = directory
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        guard let owned else { return }
        try? FileManager.default.removeItem(at: owned)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "System State")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let selected = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selected, animated: animated)
        }
    }

    // MARK: Rows

    override func numberOfSections(in _: UITableView) -> Int {
        1
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        files.count
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(localized: "Every file is included in the bundle exactly as shown here.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        let file = files[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = file.name
        content.secondaryText = ReportFormat.byteCount(file.byteCount)
        content.prefersSideBySideTextAndSecondaryText = true
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: "doc.text")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        Self.open(files[indexPath.row], from: self)
    }

    /// One collected file in the app's own text viewer. Shared with the saved
    /// bundle's page, which lists the same files out of the extracted archive.
    static func open(_ file: SystemStateFile, from controller: UIViewController) {
        guard let text = try? String(contentsOf: file.url, encoding: .utf8) else {
            return controller.presentMessage(
                "Could Not Open the File",
                message: "\(file.name) could not be read."
            )
        }
        controller.navigationController?.pushViewController(
            ReportTextViewController(title: file.name, text: text, language: .json),
            animated: true
        )
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        let file = files[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            var actions = [UIAction]()
            if let fila = SiblingApps.viewInFila(path: file.url.path) {
                actions.append(UIAction(
                    title: String(localized: "Open in Fila"),
                    image: UIImage(systemName: "folder")
                ) { _ in
                    SiblingApps.open(fila)
                })
            }
            actions.append(UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { return }
                UIPasteboard.general.string = text
                Toast.show(String(localized: "Copied"))
            })
            return UIMenu(children: actions)
        }
    }
}

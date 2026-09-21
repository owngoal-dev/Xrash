import Combine
import UIKit

/// The names the list leaves out: one text field per process, a `+` for a new
/// one, and a swipe to take one off again. Case-sensitive, because it is
/// matched against what the report calls the process.
///
/// A view filter and only that. Nothing here reaches the daemon, nothing stops
/// being written, and Delete All still removes every report on disk.
final class HiddenProcessesViewController: UITableViewController, UITextFieldDelegate {
    private let settings: AppSettings
    /// The working copy. Ordered, so a row keeps its place while it is being
    /// typed into; the filter itself holds a set.
    private var names: [String]

    init() {
        // Not a default argument: those are evaluated off the main actor.
        let settings = AppSettings.shared
        self.settings = settings
        names = settings.filter.value.hiddenProcessNames
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Hidden Processes")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.addName() }
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Add Process")
        tableView.register(FormTextFieldCell.self, forCellReuseIdentifier: FormTextFieldCell.reuseIdentifier)
        tableView.keyboardDismissMode = .interactive
    }

    // MARK: Table

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        names.count
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(localized: """
        Hidden processes stay off the list and do not send notifications. \
        Reports on disk are not deleted.
        """)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FormTextFieldCell.reuseIdentifier, for: indexPath
        ) as! FormTextFieldCell
        cell.textField.text = names[indexPath.row]
        cell.textField.placeholder = String(localized: "Process name (case-sensitive)")
        // A process name is neither a sentence nor a word in a dictionary.
        cell.textField.autocapitalizationType = .none
        cell.textField.spellCheckingType = .no
        cell.textField.delegate = self
        return cell
    }

    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        true
    }

    override func tableView(
        _: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        remove(at: indexPath)
    }

    // MARK: Editing

    private func addName() {
        // Whatever is half-typed lands first — which may drop an empty row,
        // so the new row's index is read after that has happened.
        view.endEditing(true)
        names.append("")
        let indexPath = IndexPath(row: names.count - 1, section: 0)
        tableView.insertRows(at: [indexPath], with: .automatic)
        (tableView.cellForRow(at: indexPath) as? FormTextFieldCell)?.textField.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
    }

    /// An empty row is not a hidden process, and neither is a second copy of a
    /// name already on the list: either way the row goes with the keyboard.
    func textFieldDidEndEditing(_ textField: UITextField) {
        guard let indexPath = indexPath(of: textField) else { return }
        let name = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isDuplicate = names.enumerated().contains { $0.offset != indexPath.row && $0.element == name }
        guard !name.isEmpty, !isDuplicate else { return remove(at: indexPath) }
        names[indexPath.row] = name
        textField.text = name
        save()
    }

    private func remove(at indexPath: IndexPath) {
        names.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        save()
    }

    private func save() {
        settings.changeFilter { $0.hiddenProcessNames = Set(names.filter { !$0.isEmpty }) }
    }

    /// Which row a field belongs to, asked of the table rather than kept in a
    /// tag: a deletion renumbers every row below it.
    private func indexPath(of textField: UITextField) -> IndexPath? {
        var candidate: UIView? = textField
        while let view = candidate, !(view is UITableViewCell) {
            candidate = view.superview
        }
        guard let cell = candidate as? UITableViewCell else { return nil }
        return tableView.indexPath(for: cell)
    }
}

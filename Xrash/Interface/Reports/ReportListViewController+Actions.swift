import AlertController
import Combine
import UIKit
import UniformTypeIdentifiers
import XrashReport

/// The menu, the swipes, the context menu and the edit-mode toolbar. Every one
/// of them ends in the same four verbs, so they live together.
extension ReportListViewController {
    // MARK: The filter menu

    /// One kind per menu row, except the analytics payloads and plain logs,
    /// which nobody asks for by their `bug_type`.
    private static let kindChoices: [(title: String, kinds: Set<ReportKind>)] = [
        (String(localized: "Crashes"), [.crash]),
        (String(localized: "Hangs"), [.hang]),
        (String(localized: "Resource Limits"), [.resource]),
        (String(localized: "Out of Memory"), [.jetsam]),
        (String(localized: "Kernel Panics"), [.panic]),
        (String(localized: "Analytics & Logs"), ReportFilter.analyticsKinds),
    ]

    func filterElements() -> [UIMenuElement] {
        let filter = settings.filter.value
        let show = UIMenu(
            title: String(localized: "Show"),
            image: UIImage(systemName: "eye"),
            options: .singleSelection,
            children: [
                action(String(localized: "All"), on: !filter.unreadOnly) { $0.unreadOnly = false },
                action(String(localized: "Unread"), on: filter.unreadOnly) { $0.unreadOnly = true },
            ]
        )
        let kinds = UIMenu(
            title: String(localized: "Kinds"),
            image: UIImage(systemName: "square.grid.2x2"),
            children: Self.kindChoices.map { choice in
                let isOn = !filter.kinds.isDisjoint(with: choice.kinds)
                return action(choice.title, on: isOn) {
                    isOn ? $0.kinds.subtract(choice.kinds) : $0.kinds.formUnion(choice.kinds)
                }
            }
        )
        let grouping = UIMenu(
            title: String(localized: "Group By"),
            image: UIImage(systemName: "rectangle.3.group"),
            options: .singleSelection,
            children: [
                action(String(localized: "Category"), on: filter.grouping == .category) { $0.grouping = .category },
                action(String(localized: "Process"), on: filter.grouping == .process) { $0.grouping = .process },
                action(String(localized: "Day"), on: filter.grouping == .day) { $0.grouping = .day },
            ]
        )
        let order = UIMenu(
            title: String(localized: "Sort"),
            image: UIImage(systemName: "arrow.up.arrow.down"),
            options: .singleSelection,
            children: [
                action(String(localized: "Newest First"), on: filter.order == .newest) { $0.order = .newest },
                action(String(localized: "Oldest First"), on: filter.order == .oldest) { $0.order = .oldest },
                action(String(localized: "Name"), on: filter.order == .name) { $0.order = .name },
            ]
        )
        return [show, kinds, grouping, order]
    }

    private func action(
        _ title: String,
        on isOn: Bool,
        change: @escaping (inout ReportFilter) -> Void
    ) -> UIAction {
        UIAction(title: title, state: isOn ? .on : .off) { [weak self] _ in
            self?.settings.changeFilter(change)
        }
    }

    // MARK: Swipes

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        if let row = process(for: id) {
            let deleteAll = UIContextualAction(
                style: .destructive,
                title: String(localized: "Delete")
            ) { [weak self] _, _, completion in
                self?.confirmDeleteProcess(row.name)
                completion(false)
            }
            return UISwipeActionsConfiguration(actions: [deleteAll])
        }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete")
        ) { [weak self] _, _, completion in
            self?.confirmDelete([id])
            // The row goes when the file does, not when the finger lifts.
            completion(false)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(
        _: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        if let row = process(for: id) {
            let hide = UIContextualAction(
                style: .normal,
                title: String(localized: "Hide")
            ) { [weak self] _, _, completion in
                self?.hideProcess(row.name)
                completion(true)
            }
            hide.image = UIImage(systemName: "eye.slash")
            hide.backgroundColor = .systemBlue
            return UISwipeActionsConfiguration(actions: [hide])
        }
        // ponytail: read-only, because `ReportLibrary` has no way back to
        // unread. Add Mark Unread here the day it grows one.
        guard library.unreadIDs.value.contains(id) else { return nil }
        let markRead = UIContextualAction(
            style: .normal,
            title: String(localized: "Mark Read")
        ) { [weak self] _, _, completion in
            self?.library.markRead(id)
            completion(true)
        }
        markRead.image = UIImage(systemName: "envelope.open")
        markRead.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [markRead])
    }

    // MARK: Context menu

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isEditing, let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        if let row = process(for: id) {
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
                self?.processMenu(row)
            }
        }
        guard let summary = summary(for: id) else { return nil }
        let cell = tableView.cellForRow(at: indexPath)
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: String(localized: "Open"), image: UIImage(systemName: "doc.text")) { _ in
                    self.openReport(summary)
                },
                UIAction(title: String(localized: "Share…"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    self.share([id], from: cell)
                },
                UIAction(title: String(localized: "Copy Path"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = summary.id
                    Toast.show(String(localized: "Path Copied"))
                },
                UIAction(
                    title: String(localized: "Report Crash…"),
                    image: UIImage(systemName: "paperplane")
                ) { _ in
                    self.presentReportCrash(for: id)
                },
                // Not on a process page: hiding its one process empties it.
                UIAction(
                    title: String(localized: "Hide Process"),
                    image: UIImage(systemName: "eye.slash"),
                    attributes: lockedProcessName == nil ? [] : .hidden
                ) { _ in
                    self.hideProcess(summary.processName)
                },
                UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: String(localized: "Delete"),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { _ in
                        self.confirmDelete([id])
                    },
                ]),
            ])
        }
    }

    /// An inbox row's menu. Fila's folder is offered only when Fila is there
    /// to open it, and only for a report that names an app.
    private func processMenu(_ row: ProcessInboxRow) -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: String(localized: "Open"), image: UIImage(systemName: "doc.text")) { [weak self] _ in
                self?.openProcess(row.name)
            },
            UIAction(
                title: String(localized: "Hide Process"),
                image: UIImage(systemName: "eye.slash")
            ) { [weak self] _ in
                self?.hideProcess(row.name)
            },
        ]
        if let bundleID = row.latest.bundleID, let url = SiblingApps.appInFila(bundleID: bundleID) {
            children.append(
                UIAction(
                    title: String(localized: "Show App in Fila"),
                    image: UIImage(systemName: "folder")
                ) { _ in
                    SiblingApps.open(url)
                }
            )
        }
        children.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Delete All Reports"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.confirmDeleteProcess(row.name)
            },
        ]))
        return UIMenu(children: children)
    }

    /// A view filter and nothing more: the reports stay on disk, and Settings
    /// is where a name comes back off the list.
    func hideProcess(_ name: String) {
        settings.changeFilter { $0.hiddenProcessNames.insert(name) }
        Toast.show(String(localized: "Process Hidden"))
    }

    // MARK: Edit mode

    func renderSelectionItems() {
        guard isEditing else {
            toolbarItems = nil
            return
        }
        let ids = (tableView.indexPathsForSelectedRows ?? []).compactMap(dataSource.itemIdentifier(for:))
        // Nothing chosen yet: the two useful things are choosing everything
        // and being rid of everything. The verbs take their place as soon as
        // there is something to act on.
        guard !ids.isEmpty else {
            let deleteAll = UIBarButtonItem(
                title: String(localized: "Delete All"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    confirmDelete(shownReportIDs)
                }
            )
            deleteAll.tintColor = .systemRed
            deleteAll.isEnabled = dataSource.snapshot().numberOfItems > 0
            let selectAll = UIBarButtonItem(
                title: String(localized: "Select All"),
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    for section in 0 ..< tableView.numberOfSections {
                        for row in 0 ..< tableView.numberOfRows(inSection: section) {
                            tableView.selectRow(
                                at: IndexPath(row: row, section: section),
                                animated: false,
                                scrollPosition: .none
                            )
                        }
                    }
                    renderSelectionItems()
                }
            )
            selectAll.isEnabled = dataSource.snapshot().numberOfItems > 0
            toolbarItems = [deleteAll, .flexibleSpace(), selectAll]
            return
        }
        let delete = UIBarButtonItem(
            title: String(localized: "Delete"),
            primaryAction: UIAction { [weak self] _ in self?.confirmDelete(ids) }
        )
        delete.tintColor = .systemRed
        let share = UIBarButtonItem(
            title: String(localized: "Share"),
            primaryAction: UIAction { [weak self] _ in self?.share(ids, from: nil) }
        )
        let markRead = UIBarButtonItem(
            title: String(localized: "Mark Read"),
            primaryAction: UIAction { [weak self] _ in
                ids.forEach { self?.library.markRead($0) }
                self?.setEditing(false, animated: true)
            }
        )
        toolbarItems = [delete, .flexibleSpace(), share, .flexibleSpace(), markRead]
    }

    // MARK: Doing it

    func presentReportCrash(for id: String) {
        let form = SheetNavigationController(rootViewController: ReportCrashViewController(primaryID: id))
        presentAsFormSheet(form)
    }

    private func share(_ ids: [String], from source: UIView?) {
        Task { [weak self] in
            guard let self else { return }
            var urls = [URL]()
            for id in ids {
                guard let summary = summary(for: id), let data = try? await library.data(for: id) else { continue }
                let name = ReportFormat.fileStem(for: summary.processName, date: summary.date) + ".ips"
                if let url = try? ReportShare.file(named: name, contents: data) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else {
                return presentMessage(
                    String.LocalizationValue("Nothing to Share"),
                    message: String.LocalizationValue("No report could be read. Try again.")
                )
            }
            ReportShare.present(urls, from: self, source: source)
        }
    }

    /// Every report filed under one process name — the inbox's swipe and menu,
    /// and the process page's trash. The search field is not part of it: the
    /// row counted the whole process, so this removes the whole process.
    func confirmDeleteProcess(_ name: String) {
        let ids = ReportListArrangement.admitted(for: input)
            .filter { $0.summary.processName == name }
            .map(\.summary.id)
        guard !ids.isEmpty else {
            return presentMessage(
                String.LocalizationValue("Nothing to Delete"),
                message: String.LocalizationValue("There are no reports to delete.")
            )
        }
        let alert = AlertViewController(
            title: String.LocalizationValue("Delete All Reports from \(name)?"),
            message: String.LocalizationValue(
                "The report files are removed. This cannot be undone."
            )
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Delete All"), attribute: .accent) {
                context.dispose { await self?.delete(ids) }
            }
        }
        present(alert, animated: true)
    }

    private func confirmDelete(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let title: String.LocalizationValue = ids.count == 1
            ? "Delete This Report?"
            : "Delete \(ids.count) Reports?"
        let alert = AlertViewController(
            title: title,
            message: String.LocalizationValue(
                "The report files are removed. This cannot be undone."
            )
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Delete"), attribute: .accent) {
                context.dispose { await self?.delete(ids) }
            }
        }
        present(alert, animated: true)
    }

    private func delete(_ ids: [String]) async {
        guard let failed = await ReportDeletion.delete(ids, from: self, library: library) else { return }
        if isEditing {
            setEditing(false, animated: true)
        }
        guard !failed.isEmpty else { return }
        presentMessage(
            String.LocalizationValue("Unable to Delete Some Reports"),
            message: String.LocalizationValue("\(failed.count) of the reports could not be deleted.")
        )
    }
}

// MARK: Dragging a report out

/// A row dragged into Finder, Mail or another app is the report as a file,
/// under the name the share sheet would give it rather than its own
/// `Name-date.ips.synced`. The bytes are fetched only if the drag is dropped.
extension ReportListViewController: UITableViewDragDelegate {
    func tableView(
        _: UITableView,
        itemsForBeginning _: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard !isEditing,
              let id = dataSource.itemIdentifier(for: indexPath),
              let summary = summary(for: id) else { return [] }
        let name = ReportFormat.fileStem(for: summary.processName, date: summary.date) + ".ips"
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.diagnosticReport.identifier,
            fileOptions: [],
            visibility: .all
        ) { [library] completion in
            Task { @MainActor in
                do {
                    let data = try await library.data(for: id)
                    try completion(ReportShare.file(named: name, contents: data), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return [UIDragItem(itemProvider: provider)]
    }
}

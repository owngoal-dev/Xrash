import AlertController
import UIKit
import XrashReport

/// What the two bar menus offer. A report that came out of a saved bundle is
/// not in the library, so the verbs that change the library are absent from it
/// rather than present and failing.
extension ReportDetailViewController {
    func moreElements() -> [UIMenuElement] {
        guard decodedReport != nil else { return [] }
        // Whatever the text child offers — find, wrap, text size — and only
        // while one of the two text segments is the thing on screen.
        var elements: [UIMenuElement] = [UIMenu(options: .displayInline, children: [viewAsMenu])]
        if !textViewerElements.isEmpty {
            elements.append(UIMenu(options: .displayInline, children: textViewerElements))
        }
        guard let reportID = libraryReportID else { return elements + [reportFileMenu(revealing: nil)] }
        if let symbolicateAction {
            elements.append(UIMenu(options: .displayInline, children: [symbolicateAction]))
        }
        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Report Crash…"), image: UIImage(systemName: "paperplane")) {
                [weak self] _ in
                guard let self else { return }
                presentAsFormSheet(
                    UINavigationController(rootViewController: ReportCrashViewController(primaryID: reportID))
                )
            },
            reportFileMenu(revealing: reportID),
        ]))
        // Its own group: a rule between the thing that cannot be undone and
        // the things beside it.
        elements.append(
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Delete"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.confirmDelete(reportID)
                },
            ])
        )
        return elements
    }

    /// Summary, Details and Raw are one report seen three ways, so they are
    /// one row that says which: the menu under it is the choice, and the
    /// subtitle is the answer without opening it.
    private var viewAsMenu: UIMenu {
        let chosen = segmentElements.compactMap { $0 as? UIAction }.first { $0.state == .on }
        let menu = UIMenu(
            title: String(localized: "View As"),
            image: UIImage(systemName: "eye"),
            options: .singleSelection,
            children: segmentElements
        )
        menu.subtitle = chosen?.title
        return menu
    }

    /// Everything that is about the file rather than the crash: the formats
    /// it leaves in, and — where Fila is installed — the file where it lies.
    /// The report id is its path, which is what Fila is handed.
    private func reportFileMenu(revealing reportID: String?) -> UIMenu {
        var children = shareElements()
        if let reportID, let fila = SiblingApps.revealInFila(path: reportID) {
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Reveal in Fila"), image: UIImage(systemName: "folder")) { _ in
                    SiblingApps.open(fila)
                },
            ]))
        }
        return UIMenu(
            title: String(localized: "Report File"),
            image: UIImage(systemName: "doc"),
            children: children
        )
    }

    /// Four formats, each a different file: the rendered report, the file the
    /// system wrote, the decoded model, and the short version for a ticket.
    func shareElements() -> [UIMenuElement] {
        guard let report = decodedReport, let stem = shareStem else { return [] }
        var elements: [UIMenuElement] = [
            UIAction(title: String(localized: "Crash Report (.crash)"), image: UIImage(systemName: "doc.plaintext")) {
                [weak self] _ in
                self?.shareText(ReportRenderer.crashText(report), named: "\(stem).crash")
            },
        ]
        if let reportID = libraryReportID {
            elements.append(
                UIAction(title: String(localized: "Original File (.ips)"), image: UIImage(systemName: "doc")) {
                    [weak self] _ in
                    self?.shareOriginal(reportID, named: "\(stem).ips")
                }
            )
        }
        elements.append(contentsOf: [
            UIAction(
                title: String(localized: "Report Data (.json)"),
                image: UIImage(systemName: "curlybraces")
            ) { [weak self] _ in
                guard let data = try? ReportRenderer.modelJSON(report) else { return }
                self?.shareFile(named: "\(stem).json", contents: data)
            },
            UIAction(title: String(localized: "Copy as Markdown"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = ReportRenderer.markdown(report)
                Toast.show(String(localized: "Copied"))
            },
        ])
        return elements
    }

    // MARK: Doing it

    private func shareText(_ text: String, named name: String) {
        shareFile(named: name, contents: Data(text.utf8))
    }

    private func shareFile(named name: String, contents: Data) {
        guard let url = try? ReportShare.file(named: name, contents: contents) else {
            return presentMessage(
                String.LocalizationValue("Unable to Share"),
                message: String.LocalizationValue("The file could not be created. Try again.")
            )
        }
        ReportShare.present([url], from: self, source: view)
    }

    private func shareOriginal(_ reportID: String, named name: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let data = try? await AppEnvironment.shared.library.data(for: reportID) else {
                return presentMessage(
                    String.LocalizationValue("Unable to Share"),
                    message: String.LocalizationValue("The report could not be read.")
                )
            }
            shareFile(named: name, contents: data)
        }
    }

    private func confirmDelete(_ reportID: String) {
        let alert = AlertViewController(
            title: String.LocalizationValue("Delete This Report?"),
            message: String.LocalizationValue(
                "The report file is removed. This cannot be undone."
            )
        ) { [weak self] context in
            context.addAction(title: String.LocalizationValue("Cancel")) { context.dispose() }
            context.addAction(title: String.LocalizationValue("Delete"), attribute: .accent) {
                context.dispose {
                    await AppEnvironment.shared.library.delete([reportID])
                    guard let self else { return }
                    if let reports = self.splitViewController as? ReportsSplitViewController,
                       !reports.isCollapsed
                    {
                        reports.showPlaceholder()
                    } else {
                        self.navigationController?.popViewController(animated: true)
                    }
                }
            }
        }
        present(alert, animated: true)
    }
}

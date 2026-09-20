// The screen is Fila's (MIT, same owner): Fila/Interface/Viewer/MachO/
// MachOInspectorViewController.swift. The rows it builds are copied as they
// are; Fila's tab scaffolding and property-list editor are swapped for Xrash's
// table data source, empty state and read-only text viewer.

import Foundation
import UIKit
import XrashClient
import XrashReport
import XrashSymbols

/// Each architecture has a short summary and separate lists for its metadata.
///
/// The descriptor was opened once — by `xrashd` as root, or by the app itself —
/// and is never turned back into a path. Every read is a `pread` on a duplicate
/// of it, on a cancellable worker that closes its copy when it ends.
final class MachOInspectorViewController: UITableViewController {
    private enum Row {
        case fact(String, String)
        /// Tapping opens the entitlements as read-only text.
        case entitlements(Entitlements)
        /// Tapping opens the full list; the row shows how many there are.
        case list(String, [String])

        /// The left column, and half of the row's identity.
        var label: String {
            switch self {
            case let .fact(label, _): label
            case .entitlements: String(localized: "Entitlements")
            case let .list(label, _): label
            }
        }
    }

    /// A row's identity: which slice, and which fact about it.
    ///
    /// The slice has to be in there. A universal binary states the same facts
    /// once per architecture — "Type · Execute" appears in both the arm64 and
    /// the arm64e section — and a label on its own would put that identifier in
    /// the snapshot twice, which raises rather than draws. Within a slice no two
    /// rows share a label.
    private struct Item: Hashable {
        let slice: Int
        let label: String
    }

    /// The entitlements plist, ready to show. Parsed on the worker so that the
    /// main thread never sees the bytes: a plist is small, but it arrived from
    /// a file this app did not write.
    private struct Entitlements: Sendable {
        let text: String
        let keyCount: Int

        init(plist: Data) {
            let object = try? PropertyListSerialization.propertyList(from: plist, format: nil)
            keyCount = (object as? [String: Any])?.count ?? 0
            if let object,
               let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            {
                text = String(decoding: xml, as: UTF8.self)
            } else {
                // A signature can carry something that is not a plist at all.
                // Whatever is there is still what the binary claims.
                text = String(decoding: plist, as: UTF8.self)
            }
        }
    }

    /// One architecture's worth of everything the screen shows.
    private struct Architecture: Sendable {
        let slice: MachOImage.Slice
        let inspection: MachOImage.Inspection
        let entitlements: Entitlements?
    }

    private let file: FileHandle
    private var dataSource: SectionedTableDataSource<Int, Item>!
    private var readingTask: Task<Void, Never>?
    /// Architecture names, by slice. The section identifier is the slice number
    /// rather than the name because nothing stops a fat file carrying two slices
    /// that name themselves the same; the list is built once and never moves.
    private var names: [String] = []
    private var rows: [Item: Row] = [:]

    init(name: String, file: FileHandle) {
        self.file = file
        super.init(style: .insetGrouped)
        title = name
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit { readingTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        dataSource = SectionedTableDataSource(tableView: tableView) { [weak self] tableView, indexPath, item in
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            self?.configure(cell, item: item)
            return cell
        }
        // The header is asked for a section the snapshot has and this parallel
        // array may not, for the one draw between the two being replaced.
        dataSource.header = { [weak self] slice in
            guard let names = self?.names, names.indices.contains(slice) else { return nil }
            return names[slice]
        }
        tableView.setEmptyState(.loading(String(localized: "Reading…")))
        read()
    }

    // MARK: Reading

    /// A duplicate of the descriptor, so that the worker owns a file of its own:
    /// this screen can be popped while a large binary is still being walked, and
    /// closing under the parser is how that becomes a crash.
    private func read() {
        let descriptor = dup(file.fileDescriptor)
        guard descriptor >= 0 else { return showFailure() }
        readingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> [Architecture] in
                defer { close(descriptor) }
                let image = try MachOImage(descriptor: descriptor)
                return try image.slices.map { slice in
                    try Task.checkCancellation()
                    return try Architecture(
                        slice: slice,
                        inspection: image.inspect(slice),
                        entitlements: image.entitlements(of: slice).map(Entitlements.init)
                    )
                }
            }
            do {
                let architectures = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self else { return }
                show(architectures)
            } catch {
                guard !Task.isCancelled else { return }
                self?.showFailure()
            }
        }
    }

    private func show(_ architectures: [Architecture]) {
        var updatedRows: [Item: Row] = [:]
        var updatedNames: [String] = []
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        for (index, architecture) in architectures.enumerated() {
            let built = Self.rows(
                for: architecture.slice,
                inspection: architecture.inspection,
                entitlements: architecture.entitlements,
                isUniversal: architectures.count > 1
            )
            let items = built.map { Item(slice: index, label: $0.label) }
            for (item, row) in zip(items, built) {
                updatedRows[item] = row
            }
            updatedNames.append(architecture.slice.architecture)
            snapshot.appendSections([index])
            snapshot.appendItems(items, toSection: index)
        }
        rows = updatedRows
        names = updatedNames
        tableView.setEmptyState(snapshot.itemIdentifiers.isEmpty ? .message(
            symbolName: "doc.text.magnifyingglass",
            title: String(localized: "Nothing to Show"),
            description: String(localized: "This file has no architecture Xrash can read."),
            actionTitle: nil
        ) : nil)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func showFailure() {
        guard rows.isEmpty else { return }
        tableView.setEmptyState(.message(
            symbolName: "exclamationmark.triangle",
            title: String(localized: "Unable to Read This Binary"),
            description: String(localized: "The file is not a Mach-O binary, or the part that describes it is damaged."),
            actionTitle: nil
        ))
    }

    // MARK: Rows

    private func configure(_ cell: UITableViewCell, item: Item) {
        var configuration = UIListContentConfiguration.valueCell()
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.text = item.label

        switch rows[item] {
        case let .fact(_, value):
            configuration.secondaryText = value
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case let .entitlements(entitlements):
            configuration.secondaryText = String(inflecting: "^[\(entitlements.keyCount) key](inflect: true)")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case let .list(_, items):
            configuration.secondaryText = String(inflecting: "^[\(items.count) item](inflect: true)")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case nil:
            break
        }
        cell.contentConfiguration = configuration
    }

    private static func rows(
        for architecture: MachOImage.Slice,
        inspection: MachOImage.Inspection,
        entitlements: Entitlements?,
        isUniversal: Bool
    ) -> [Row] {
        var rows: [Row] = [
            .fact(String(localized: "Type"), fileType(architecture.fileType)),
            .fact(String(localized: "Signature"), architecture.isCodeSigned
                ? (inspection.isAdHoc == true ? String(localized: "Ad hoc") : String(localized: "Signed"))
                : String(localized: "None")),
            .list(String(localized: "Linked Libraries"), architecture.linkedLibraries),
        ]
        if let entitlements {
            rows.append(.entitlements(entitlements))
        } else {
            rows.append(.fact(String(localized: "Entitlements"), String(localized: "None")))
        }
        rows.append(.list(String(localized: "Runpaths"), inspection.runpaths))
        rows.append(.list(String(localized: "Load Commands"), inspection.loadCommands))
        rows.append(.list(String(localized: "Segments"), inspection.segments.map { segment in
            [
                segment.name + " · " + segment.protections,
                String(localized: "Virtual Address") + ": " + String(format: "0x%llX", segment.virtualAddress)
                    + " · " + ReportFormat.byteCount(segment.virtualSize),
                String(localized: "File Offset") + ": " + String(format: "0x%llX", segment.fileOffset)
                    + " · " + ReportFormat.byteCount(segment.fileSize),
                String(localized: "Sections") + ": " + segment.sections.joined(separator: ", "),
            ].joined(separator: "\n")
        }))

        rows.append(.list(String(localized: "Details"), detailLines(
            for: architecture,
            inspection: inspection,
            isUniversal: isUniversal
        )))
        return rows
    }

    /// The Details row's lines, in the order a reader of a Mach-O header would
    /// look for them.
    private static func detailLines(
        for architecture: MachOImage.Slice,
        inspection: MachOImage.Inspection,
        isUniversal: Bool
    ) -> [String] {
        var details: [String] = []
        if isUniversal {
            details.append(String(localized: "Slice Size") + ": "
                + ReportFormat.byteCount(UInt64(clamping: architecture.byteCount)))
        }
        if let name = architecture.installName {
            details.append(String(localized: "Install Name") + ": " + name)
        }
        if let platform = inspection.platform {
            details.append(String(localized: "Platform") + ": " + platform)
        }
        if let minimum = inspection.minimumOS {
            details.append(String(localized: "Minimum OS") + ": " + minimum)
        }
        if let sdk = inspection.sdk {
            details.append(String(localized: "SDK") + ": " + sdk)
        }
        if let source = inspection.sourceVersion {
            details.append(String(localized: "Source Version") + ": " + source)
        }
        if let entry = inspection.entryOffset {
            details.append(String(localized: "Entry Offset") + ": " + String(format: "0x%llX", entry))
        }
        if let count = inspection.symbolCount {
            details.append(String(localized: "Symbols") + ": " + String(count))
        }
        if let uuid = architecture.uuid {
            details.append(String(localized: "UUID") + ": " + uuid.uuidString)
        }
        if !inspection.flags.isEmpty {
            details.append(String(localized: "Flags") + ": " + inspection.flags.joined(separator: ", "))
        }
        let encryption = if let method = inspection.encryptionMethod, method != 0 {
            String(localized: """
            Encrypted, method \(method), \
            \(ReportFormat.byteCount(UInt64(inspection.encryptedByteCount ?? 0))) region
            """)
        } else {
            String(localized: "Not encrypted")
        }
        details.append(String(localized: "Encryption") + ": " + encryption)
        if let identifier = inspection.signingIdentifier {
            details.append(String(localized: "Signing Identifier") + ": " + identifier)
        }
        if let team = inspection.teamIdentifier {
            details.append(String(localized: "Team Identifier") + ": " + team)
        }
        return details
    }

    private static func fileType(_ value: MachOImage.FileType?) -> String {
        switch value {
        case .object: String(localized: "Object File")
        case .executable: String(localized: "Executable")
        case .core: String(localized: "Core Dump")
        case .dynamicLibrary: String(localized: "Dynamic Library")
        case .dynamicLinker: String(localized: "Dynamic Linker")
        case .bundle: String(localized: "Bundle")
        case .dynamicLibraryStub: String(localized: "Library Stub")
        case .debugSymbols: String(localized: "Debug Symbols")
        case .kernelExtension: String(localized: "Kernel Extension")
        case .fileSet: String(localized: "File Set")
        case .fixedVMLibrary: String(localized: "Fixed VM Library")
        case .preload: String(localized: "Preload File")
        case nil: String(localized: "Unknown")
        }
    }

    // MARK: Selection

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case let .fact(_, value) = rows[item] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = value
                    Toast.show(String(localized: "Copied"))
                },
            ])
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch rows[item] {
        case .fact, nil:
            break
        case let .entitlements(entitlements):
            navigationController?.pushViewController(
                ReportTextViewController(
                    title: String(localized: "Entitlements"),
                    text: entitlements.text,
                    language: .plain
                ),
                animated: true
            )
        case let .list(label, items):
            navigationController?.pushViewController(
                InspectorListViewController(title: label, rows: items),
                animated: true
            )
        }
    }
}

extension UIViewController {
    /// Pushes the inspector for one of a report's images.
    ///
    /// Not every image has a file to open: a system library lives inside the
    /// dyld shared cache, and a report carried over from another device names
    /// binaries this one never had. Both say so in a sentence — the path is not
    /// what the reader is looking at.
    func inspectBinary(_ image: BinaryImage) {
        guard image.source != "S" else {
            return presentMessage(
                "Binary Not Available",
                message: "This image lives in the system’s shared cache and has no file of its own."
            )
        }
        Task { [weak self] in
            guard let self else { return }
            guard let file = try? await AppEnvironment.shared.backend.openImage(at: image.path) else {
                return presentMessage(
                    "Binary Not Available",
                    message: """
                    This binary could not be opened. It may belong to another device, or to software \
                    that is no longer installed.
                    """
                )
            }
            navigationController?.pushViewController(
                MachOInspectorViewController(name: image.name, file: file),
                animated: true
            )
        }
    }
}

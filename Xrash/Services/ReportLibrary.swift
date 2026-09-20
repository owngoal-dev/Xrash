import Combine
import Foundation
import XrashClient
import XrashProtocol
import XrashReport
import XrashSymbols

/// Every report the app knows about: the system's, through the backend, and
/// the ones the user imported. The interface observes the subjects; all
/// mutation happens on the main actor, all parsing off it.
@MainActor
final class ReportLibrary {
    /// Newest first.
    let summaries = CurrentValueSubject<[ReportSummary], Never>([])
    let isLoading = CurrentValueSubject<Bool, Never>(false)
    /// Reports never opened on this device.
    let unreadIDs = CurrentValueSubject<Set<String>, Never>([])

    /// Reports opened from Files, other apps or drag and drop are copied here.
    let importedDirectory: URL

    private static let headerPrefixByteCount = 8 * 1024
    private static let seenDefaultsKey = "ReportLibrary.seenIDs"

    private let backend: ReportBackend
    private let symbolicator: Symbolicator
    private var decoded = [String: Report]()
    private var symbolicated = [String: Report]()
    private var refreshing: Task<Void, Never>?

    nonisolated init(backend: ReportBackend, symbolicator: Symbolicator) {
        self.backend = backend
        self.symbolicator = symbolicator
        importedDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Imported", isDirectory: true)
    }

    // MARK: Listing

    /// Lists, reads every header, then publishes once. A row's group and title
    /// come from its header, so publishing name-only rows first made every row
    /// hop between sections a moment later; the list waits the extra moment
    /// behind its loading state instead and appears finished.
    ///
    /// A second caller joins the pass already running: the scene delegate
    /// starts one at launch and the list asks again as it loads, and the
    /// second must not throw the first one's work away.
    func refresh() async {
        if let refreshing {
            return await refreshing.value
        }
        let task = Task { await listAndPublish() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func listAndPublish() async {
        isLoading.send(true)
        defer { isLoading.send(false) }

        let entries = await((try? backend.listReports()) ?? []) + importedEntries()
        var rows = entries.map {
            ReportDecoder.summary(path: $0.path, byteCount: $0.byteCount, modified: $0.modified)
        }

        // ponytail: headers are re-read on every refresh; persist them keyed
        // by (path, mtime) if a device with thousands of reports feels it.
        for index in rows.indices {
            guard let header = await header(of: rows[index].id) else { continue }
            rows[index] = ReportDecoder.enrich(rows[index], header: header, executablePath: nil)
        }
        publish(rows)
    }

    private func publish(_ rows: [ReportSummary]) {
        summaries.send(rows.sorted { $0.date > $1.date })
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenDefaultsKey) ?? [])
        unreadIDs.send(Set(rows.map(\.id)).subtracting(seen))
    }

    private func importedEntries() -> [ReportEntry] {
        guard let root = PathGuard.canonical(importedDirectory.path) else { return [] }
        return ReportScanner(roots: [root]).scan()
    }

    private func header(of id: String) async -> ReportHeader? {
        guard let handle = try? await open(id) else { return nil }
        let prefix = (try? handle.read(upToCount: Self.headerPrefixByteCount)) ?? Data()
        return ReportDecoder.header(fromPrefix: prefix)
    }

    // MARK: Reading

    func data(for id: String) async throws -> Data {
        try await open(id).readToEnd() ?? Data()
    }

    func report(for id: String) async throws -> Report {
        if let report = decoded[id] {
            return report
        }
        let data = try await data(for: id)
        let fileName = (id as NSString).lastPathComponent
        let report = try await Task.detached { try ReportDecoder.decode(data, fileName: fileName) }.value
        decoded[id] = report
        return report
    }

    /// The report with its frames resolved. `force` re-runs after the symbol
    /// stores changed.
    func symbolicatedReport(
        for id: String,
        force: Bool = false,
        progress: (@Sendable (SymbolicationProgress) -> Void)? = nil
    ) async throws -> Report {
        if !force, let report = symbolicated[id] {
            return report
        }
        var report = try await report(for: id)
        if let crash = report.crash {
            report.crash = await symbolicator.symbolicate(crash, progress: progress)
        }
        symbolicated[id] = report
        return report
    }

    func markRead(_ id: String) {
        guard unreadIDs.value.contains(id) else { return }
        var seen = UserDefaults.standard.stringArray(forKey: Self.seenDefaultsKey) ?? []
        seen.append(id)
        UserDefaults.standard.set(seen, forKey: Self.seenDefaultsKey)
        unreadIDs.value.remove(id)
    }

    // MARK: Changing

    /// Returns the ids that could not be removed.
    @discardableResult
    func delete(_ ids: [String]) async -> [String] {
        let failed = await(try? backend.deleteReports(at: ids.filter { !isImported($0) })) ?? ids
        var failedImports = [String]()
        for id in ids where isImported(id) {
            if (try? FileManager.default.removeItem(atPath: id)) == nil {
                failedImports.append(id)
            }
        }
        let removed = Set(ids).subtracting(failed).subtracting(failedImports)
        removed.forEach { decoded[$0] = nil; symbolicated[$0] = nil }
        publish(summaries.value.filter { !removed.contains($0.id) })
        return failed + failedImports
    }

    /// Copies a report from outside into the library and returns its id.
    func importReport(at url: URL) async throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try FileManager.default.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
        var destination = importedDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = importedDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        }
        try FileManager.default.copyItem(at: url, to: destination)
        await refresh()
        return PathGuard.canonical(destination.path) ?? destination.path
    }

    private func isImported(_ id: String) -> Bool {
        guard let root = PathGuard.canonical(importedDirectory.path) else { return false }
        return PathGuard.isInside(id, root: root)
    }

    private func open(_ id: String) async throws -> FileHandle {
        if isImported(id) {
            return try FileHandle(forReadingFrom: URL(fileURLWithPath: id))
        }
        return try await backend.openReport(at: id)
    }
}

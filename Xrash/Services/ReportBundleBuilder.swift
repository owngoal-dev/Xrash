import Combine
import UIKit
import XrashBlame
import XrashBundle
import XrashClient
import XrashReport
import XrashSymbols
import XrashSystemState

/// Turns a primary report and the crashes linked to it into one
/// `.xrashreport`, straight into `SavedBundleStore`'s directory.
///
/// Everything that touches a file runs off the main actor — `@concurrent`,
/// because with approachable concurrency a `nonisolated async` function stays
/// on its caller's actor; `progress` is called back on it. Cancellation is checked between members and between
/// files, so a cancelled build leaves nothing but its working directory,
/// which goes away with it.
enum ReportBundleBuilder {
    struct LinkedReport: Hashable, Sendable {
        var id: String
        var relation: BundleManifest.Relation
    }

    struct Request: Sendable {
        var primaryID: String
        var linked = [LinkedReport]()
        var title = ""
        var notes = ""
        var options = BundleOptions()
        /// Ship the dSYMs that match an image in the primary crash.
        var includesDSYMs = false
        /// Already collected and already reviewed, on disk where the form left
        /// them. Collected here instead and what ships would not be what the
        /// person was shown.
        var systemFiles = [SystemStateFile]()
    }

    enum Failure: LocalizedError {
        case reportUnavailable(String)

        var errorDescription: String? {
            switch self {
            case let .reportUnavailable(id):
                String(localized: "\((id as NSString).lastPathComponent) is no longer in the library.")
            }
        }
    }

    /// Past this the copy stops and the notes say what was left out. Bundles
    /// are meant to be attached to an issue, not to fill a disk.
    private static let binaryByteLimit: UInt64 = 200 * 1024 * 1024
    private static let copyChunkByteCount = 1 << 20

    // MARK: Building

    @MainActor
    static func build(
        _ request: Request,
        environment: AppEnvironment = .shared,
        progress: @escaping @MainActor (Double, String) -> Void,
    ) async throws -> SavedBundleStore.SavedBundle {
        let working = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleBuild", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: working) }

        let library = environment.library
        let summaries = Dictionary(
            library.summaries.value.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first },
        )
        let wanted: [(id: String, relation: BundleManifest.Relation?)] =
            [(request.primaryID, nil)] + request.linked.map { ($0.id, $0.relation) }

        var files = [BundleFile]()
        var members = [BundleManifest.Member]()
        for (offset, entry) in wanted.enumerated() {
            try Task.checkCancellation()
            guard let summary = summaries[entry.id] else { throw Failure.reportUnavailable(entry.id) }
            progress(
                0.05 + 0.35 * Double(offset) / Double(wanted.count),
                String(localized: "Reading \(summary.processName)…"),
            )
            let report = try await report(for: entry.id, in: library)
            var member = BundleManifest.Member(
                id: UUID().uuidString,
                summary: summary,
                relation: entry.relation,
                report: report,
            )
            let raw = request.options.includesReports ? try? await library.data(for: entry.id) : nil
            let written = try await write(member, raw: raw, options: request.options, into: working)
            member.rawPath = written.rawPath
            member.textPath = written.textPath
            member.jsonPath = written.jsonPath
            files.append(contentsOf: written.files)
            members.append(member)
        }

        guard let primary = members.first else { throw Failure.reportUnavailable(request.primaryID) }
        var manifest = BundleManifest(
            id: UUID().uuidString,
            created: Date(),
            title: request.title,
            notes: request.notes,
            generator: DeviceInfo.generator,
            primary: primary,
        )
        manifest.linked = Array(members.dropFirst())
        manifest.deviceModel = DeviceInfo.model
        manifest.osVersion = DeviceInfo.osVersion

        let primaryCrash = primary.report.crash
        if request.options.includesBinaries, let crash = primaryCrash {
            try Task.checkCancellation()
            progress(0.4, String(localized: "Copying binaries…"))
            let copied = await copyImages(
                includedImages(in: crash),
                into: working,
                backend: environment.backend,
            ) { fraction, name in
                Task { @MainActor in progress(0.4 + 0.3 * fraction, String(localized: "Copying \(name)…")) }
            }
            manifest.binaries = copied.binaries
            files.append(contentsOf: copied.files)
            if !copied.skipped.isEmpty {
                manifest.notes = appendingSkipNote(to: manifest.notes, skipped: copied.skipped)
            }
        }

        if request.includesDSYMs, let crash = primaryCrash {
            try Task.checkCancellation()
            progress(0.72, String(localized: "Adding debug symbols…"))
            files.append(contentsOf: matchingDSYMs(for: crash, in: environment.dsyms))
        }

        if request.options.includesPDF {
            try Task.checkCancellation()
            progress(0.76, String(localized: "Creating PDF…"))
            let packages = environment.packages
            // Both are read here, on the main actor, because the renderer runs
            // off it and neither UIKit's asset manager nor dpkg's cache likes
            // being reached from two places at once.
            let icon = ReportPDFRenderer.appIcon
            if let pdf = await renderPDF(manifest, packages: packages, icon: icon, into: working) {
                manifest.pdfPath = BundleLayout.pdf
                files.append(pdf)
            }
        }

        // After the PDF, so the summary is drawn from a manifest that has never
        // heard of system state: a one-page summary of a crash is not the place
        // to print what is installed.
        if request.options.includesSystemState, !request.systemFiles.isEmpty {
            try Task.checkCancellation()
            progress(0.82, String(localized: "Adding system state…"))
            manifest.systemFiles = request.systemFiles.map {
                BundleManifest.SystemFile(
                    name: $0.name,
                    archivePath: BundleLayout.systemFile(name: $0.name),
                    byteCount: $0.byteCount,
                )
            }
            files.append(contentsOf: request.systemFiles.map {
                BundleFile(source: $0.url, archivePath: BundleLayout.systemFile(name: $0.name))
            })
        }

        try Task.checkCancellation()
        progress(0.85, String(localized: "Writing the archive…"))
        let destination = environment.savedBundles.archiveURL(for: manifest.id)
        do {
            try await writeArchive(manifest, files: files, to: destination) { fraction in
                Task { @MainActor in progress(0.85 + 0.15 * fraction, String(localized: "Writing the archive…")) }
            }
            // libarchive cannot be stopped part-way, so a cancellation during
            // the write shows up here — with a finished file nobody asked for.
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(1, String(localized: "Done"))
        return try environment.savedBundles.adopt(manifest, at: destination)
    }

    /// The images a bundle would carry: the crashed executable plus every
    /// non-system image on the faulting stack or in the last exception
    /// backtrace. Shared-cache images are Apple's and already sit on any
    /// machine that opens the report.
    static func includedImages(in crash: CrashReport) -> [BinaryImage] {
        var indices = Set<Int>()
        if let thread = crash.faultingThread {
            indices.formUnion(thread.frames.compactMap(\.imageIndex))
        }
        indices.formUnion(crash.lastExceptionBacktrace.compactMap(\.imageIndex))

        var candidates = indices.sorted().compactMap { index -> BinaryImage? in
            crash.images.indices.contains(index) ? crash.images[index] : nil
        }
        if let executable = crash.images.first(where: { $0.path == crash.process.path }) {
            candidates.insert(executable, at: 0)
        }
        var seen = Set<String>()
        // A bundle files a binary under its UUID. An image the report gave
        // none — a jailbreak's own reporter — cannot be tied to a file on disk.
        return candidates.filter { isThirdParty($0) && !$0.uuid.isEmpty && seen.insert($0.uuid).inserted }
    }

    /// Not Apple's, by the report's own `source` column or by where the image
    /// lives. The one definition: what is worth bundling, what is worth a
    /// dSYM and what a PDF lists by name are the same question.
    static func isThirdParty(_ image: BinaryImage) -> Bool {
        guard image.source != "S", !image.path.isEmpty else { return false }
        return !["/System/", "/usr/lib/", "/usr/libexec/"].contains { image.path.hasPrefix($0) }
    }

    /// What the Include section shows beside the Binaries switch.
    // ponytail: sizes come from stat, so an image only root can read counts as
    // nothing until the copy actually opens it. Measure through the backend if
    // the estimate ever reads wrong enough to matter.
    static func estimatedByteCount(of images: [BinaryImage]) -> UInt64 {
        images.reduce(0) { total, image in
            let attributes = try? FileManager.default.attributesOfItem(atPath: image.path)
            return total + ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    // MARK: Members

    /// Symbolicated if the stores can manage it, decoded if they cannot: a
    /// bundle with unresolved frames still beats no bundle.
    @MainActor
    private static func report(for id: String, in library: ReportLibrary) async throws -> Report {
        if let symbolicated = try? await library.symbolicatedReport(for: id) {
            return symbolicated
        }
        return try await library.report(for: id)
    }

    private struct MemberFiles: Sendable {
        var files = [BundleFile]()
        var rawPath: String?
        var textPath: String?
        var jsonPath: String?
    }

    @concurrent private nonisolated static func write(
        _ member: BundleManifest.Member,
        raw: Data?,
        options: BundleOptions,
        into working: URL,
    ) async throws -> MemberFiles {
        var result = MemberFiles()
        // One option covers all three forms of a report, so nothing to write
        // means not even a directory to write it into.
        guard options.includesReports else { return result }

        func put(_ data: Data, at archivePath: String) throws {
            let url = working.appendingPathComponent(archivePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try data.write(to: url, options: .atomic)
            result.files.append(BundleFile(source: url, archivePath: archivePath))
        }

        if let raw {
            let path = BundleLayout.rawReport(member: member.id, fileName: sanitised(member.summary.fileName))
            try put(raw, at: path)
            result.rawPath = path
        }
        if let text = ReportRenderer.crashText(member.report).data(using: .utf8) {
            let path = BundleLayout.crashText(member: member.id)
            try put(text, at: path)
            result.textPath = path
        }
        if let json = try? ReportRenderer.modelJSON(member.report) {
            let path = BundleLayout.reportJSON(member: member.id)
            try put(json, at: path)
            result.jsonPath = path
        }
        return result
    }

    // MARK: Binaries and symbols

    @concurrent private nonisolated static func copyImages(
        _ images: [BinaryImage],
        into working: URL,
        backend: ReportBackend,
        progress: @escaping @Sendable (Double, String) -> Void,
    ) async -> (binaries: [BundleManifest.IncludedBinary], files: [BundleFile], skipped: [String]) {
        let directory = working.appendingPathComponent("binaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var binaries = [BundleManifest.IncludedBinary]()
        var files = [BundleFile]()
        var skipped = [String]()
        var total: UInt64 = 0

        for (offset, image) in images.enumerated() {
            guard !Task.isCancelled else { break }
            progress(Double(offset) / Double(max(images.count, 1)), image.name)
            let archivePath = BundleLayout.binary(uuid: image.uuid, name: sanitised(image.name))
            let destination = working.appendingPathComponent(archivePath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                let copied = try await copy(
                    imageAt: image.path,
                    to: destination,
                    backend: backend,
                    byteLimit: binaryByteLimit - total,
                )
                total += copied
                binaries.append(BundleManifest.IncludedBinary(
                    uuid: image.uuid,
                    originalPath: image.path,
                    archivePath: archivePath,
                    byteCount: copied,
                ))
                files.append(BundleFile(source: destination, archivePath: archivePath))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                skipped.append(image.name)
            }
        }
        return (binaries, files, skipped)
    }

    @concurrent private nonisolated static func copy(
        imageAt path: String,
        to destination: URL,
        backend: ReportBackend,
        byteLimit: UInt64,
    ) async throws -> UInt64 {
        let source = try await backend.openImage(at: path)
        defer { try? source.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let sink = try FileHandle(forWritingTo: destination)
        defer { try? sink.close() }

        var copied: UInt64 = 0
        while let chunk = try source.read(upToCount: copyChunkByteCount), !chunk.isEmpty {
            guard copied + UInt64(chunk.count) <= byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            try sink.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            try Task.checkCancellation()
        }
        return copied
    }

    private static func matchingDSYMs(for crash: CrashReport, in store: DSYMStore) -> [BundleFile] {
        var seen = Set<String>()
        return crash.images.compactMap { image in
            guard seen.insert(image.uuid).inserted, let url = store.url(forUUID: image.uuid) else { return nil }
            return BundleFile(source: url, archivePath: BundleLayout.dsym(uuid: image.uuid))
        }
    }

    private static func appendingSkipNote(to notes: String, skipped: [String]) -> String {
        let note = String(localized: "Left out of the bundle: \(skipped.joined(separator: ", ")).")
        return notes.isEmpty ? note : notes + "\n\n" + note
    }

    // MARK: Off-main work

    @concurrent private nonisolated static func renderPDF(
        _ manifest: BundleManifest,
        packages: DpkgDatabase?,
        icon: UIImage?,
        into working: URL,
    ) async -> BundleFile? {
        let url = working.appendingPathComponent(BundleLayout.pdf)
        let data = ReportPDFRenderer.pdf(for: manifest, packages: packages, icon: icon)
        guard (try? data.write(to: url)) != nil else { return nil }
        return BundleFile(source: url, archivePath: BundleLayout.pdf)
    }

    @concurrent private nonisolated static func writeArchive(
        _ manifest: BundleManifest,
        files: [BundleFile],
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void,
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? FileManager.default.removeItem(at: destination)
        try BundleArchive.write(manifest, files: files, to: destination, progress: progress)
    }

    // MARK: Paths

    /// A name from a report can carry anything; an archive entry may not carry
    /// a separator, a NUL or a walk upwards.
    private static func sanitised(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "report" : cleaned
    }
}

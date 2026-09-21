import Combine
import Foundation
import XrashBundle

/// The `.xrashreport` archives the user made or imported, kept in `directory`.
@MainActor
final class SavedBundleStore {
    struct SavedBundle: Hashable, Identifiable {
        var id: String {
            manifest.id
        }

        /// The archive on disk.
        var url: URL
        var manifest: BundleManifest
    }

    /// Newest first.
    let bundles = CurrentValueSubject<[SavedBundle], Never>([])
    let directory: URL

    private static let archiveExtension = "xrashreport"
    /// A bundle's manifest, cached beside its archive as `<id>.plist`, so that
    /// showing the page — or a member's report — never unzips anything.
    private static let sidecarExtension = "plist"

    nonisolated init(directory: URL) {
        self.directory = directory
    }

    /// The archives on disk, each with the manifest cached next to it. An
    /// archive whose sidecar is missing or stale is opened once to rebuild it.
    func reload() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let found = contents
            .filter { $0.pathExtension == Self.archiveExtension }
            .compactMap { archive -> SavedBundle? in
                if let manifest = cachedManifest(for: archive) {
                    return SavedBundle(url: archive, manifest: manifest)
                }
                return try? rebuildSidecar(for: archive)
            }
        publish(found)
    }

    /// Copies an archive from outside into the store. The manifest is read by
    /// unpacking into a temporary directory that is thrown away again.
    @discardableResult
    func add(archiveAt url: URL) throws -> SavedBundle {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let staging = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manifest = try BundleArchive.read(url, extractingInto: staging)

        let destination = archiveURL(for: manifest.id)
        if destination != url {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return try adopt(manifest, at: destination)
    }

    /// Registers an archive this app just wrote, whose manifest is already in
    /// hand — unzipping what we packed a moment ago would only cost time.
    @discardableResult
    func adopt(_ manifest: BundleManifest, at url: URL) throws -> SavedBundle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(manifest).write(to: sidecarURL(for: manifest.id), options: .atomic)

        let bundle = SavedBundle(url: url, manifest: manifest)
        publish(bundles.value.filter { $0.id != bundle.id } + [bundle])
        return bundle
    }

    func remove(_ bundle: SavedBundle) throws {
        try FileManager.default.removeItem(at: bundle.url)
        try? FileManager.default.removeItem(at: sidecarURL(for: bundle.id))
        publish(bundles.value.filter { $0.id != bundle.id })
    }

    /// Unpacks a bundle into a fresh temporary directory so its files can be
    /// previewed or shared. The caller owns what comes back.
    func extract(_ bundle: SavedBundle) throws -> URL {
        let directory = temporaryDirectory()
        _ = try BundleArchive.read(bundle.url, extractingInto: directory)
        return directory
    }

    /// Where `ReportBundleBuilder` writes, so that adopting it is a rename-free
    /// registration.
    func archiveURL(for id: String) -> URL {
        directory.appendingPathComponent(Self.component(id)).appendingPathExtension(Self.archiveExtension)
    }

    /// A manifest's id as a file name. The id comes out of an archive someone
    /// else may have written and is about to be joined onto the store, where
    /// `..` would walk out of it; every id this app mints is a UUID, so
    /// anything else is filed under a name that cannot.
    private static func component(_ id: String) -> String {
        guard UUID(uuidString: id) == nil else { return id }
        return Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    // MARK: Plumbing

    private func sidecarURL(for id: String) -> URL {
        directory.appendingPathComponent(Self.component(id)).appendingPathExtension(Self.sidecarExtension)
    }

    private func cachedManifest(for archive: URL) -> BundleManifest? {
        let sidecar = archive.deletingPathExtension().appendingPathExtension(Self.sidecarExtension)
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        return try? PropertyListDecoder().decode(BundleManifest.self, from: data)
    }

    private func rebuildSidecar(for archive: URL) throws -> SavedBundle {
        let staging = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let manifest = try BundleArchive.read(archive, extractingInto: staging)
        return try adopt(manifest, at: archive)
    }

    /// The archive under the name a person gave it. On disk an archive is
    /// named by its id, which is what AirDrop and Files would otherwise show.
    /// A hard link where the volume allows one, a copy where it does not, and
    /// the archive itself if neither works: sharing an ugly name beats not
    /// sharing.
    func shareURL(for bundle: SavedBundle) -> URL {
        let title = bundle.manifest.title
            .components(separatedBy: CharacterSet(charactersIn: "/:\0").union(.newlines))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != ".", title != ".." else { return bundle.url }
        let named = temporaryDirectory()
            .appendingPathComponent(String(title.prefix(120)))
            .appendingPathExtension(Self.archiveExtension)
        let files = FileManager.default
        if (try? files.linkItem(at: bundle.url, to: named)) != nil
            || (try? files.copyItem(at: bundle.url, to: named)) != nil
        {
            return named
        }
        return bundle.url
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bundles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func publish(_ found: [SavedBundle]) {
        bundles.send(found.sorted { $0.manifest.created > $1.manifest.created })
    }
}

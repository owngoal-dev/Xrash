import Foundation

/// dSYMs published as a GitHub release asset. The sibling apps' release
/// workflows attach `<App>_<version>_dSYMs.zip`, a zip of `.dSYM` folders, and
/// ldid signs without stripping — so the UUIDs inside match the binaries that
/// shipped, and a crash from a release build symbolicates from them.
///
/// Everything here is a pure function of its input except `releases`, which is
/// one unauthenticated GET. No token, no writing, nothing but HTTPS.
enum GitHubReleaseSymbols {
    struct Repository: Hashable, Sendable {
        var owner: String
        var name: String

        var slug: String {
            "\(owner)/\(name)"
        }
    }

    struct Asset: Hashable, Sendable {
        var name: String
        var downloadURL: URL
        var byteCount: Int64
    }

    struct Release: Hashable, Sendable, Identifiable {
        var id: String {
            tag
        }

        var tag: String
        var name: String?
        var published: Date?
        var isPrerelease: Bool
        var assets: [Asset]

        /// The assets that hold debug symbols, in the order GitHub listed them.
        var symbolAssets: [Asset] {
            assets.filter { isSymbolArchive($0.name) }
        }
    }

    enum Failure: LocalizedError {
        case repositoryNotFound
        case rateLimited
        case offline
        case noReleases
        case noSymbolArchive
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .repositoryNotFound:
                String(localized: "That repository does not exist, or it is private.")
            case .rateLimited:
                String(localized: "Too many requests to GitHub. Try again in a few minutes.")
            case .offline:
                String(localized: "Xrash could not reach GitHub. Check the network and try again.")
            case .noReleases:
                String(localized: "That repository has no releases.")
            case .noSymbolArchive:
                String(localized: "That release has no debug symbol archive attached.")
            case .tooLarge:
                String(localized: "That archive is too large to import. The limit is 1 GB.")
            case .unreadable:
                String(localized: "Xrash could not read GitHub’s response. Try again later.")
            }
        }
    }

    /// Past this a download is refused rather than filling the device.
    static let downloadByteLimit: Int64 = 1024 * 1024 * 1024

    // MARK: Pure

    /// `owner/repo`, a `github.com` URL with or without `.git`, and anything
    /// hanging off the end of one — `/releases/tag/v1.2.3` is where a person
    /// copies the link from, so it has to be accepted.
    static func repository(from text: String) -> Repository? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "git@"] where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        trimmed = trimmed.replacingOccurrences(of: "github.com:", with: "github.com/")
        for prefix in ["github.com/", "www.github.com/"] where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        guard isSegment(owner), isSegment(name) else { return nil }
        return Repository(owner: owner, name: name)
    }

    /// `Fila_0.5.9_dSYMs.zip`, `Xrash_0.1.0_dSYM.zip`, `App.dSYMs.zip` and a
    /// bare `dsyms.zip` — but not `Fila_0.5.9.zip` and not `notdsym.zip`, where
    /// "dsym" is only the tail of a longer word.
    static func isSymbolArchive(_ name: String) -> Bool {
        name.range(of: "(^|[_.-])dSYMs?\\.zip$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isSegment(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) }
    }

    // MARK: Network

    /// The repository's releases, newest first as GitHub returns them. Drafts
    /// are not visible without a token, so nothing here pretends to show them.
    static func releases(in repository: Repository) async throws -> [Release] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository.owner)/\(repository.name)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else { throw Failure.repositoryNotFound }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Xrash", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.offline
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 403, 429: throw Failure.rateLimited
        case 404: throw Failure.repositoryNotFound
        default: throw Failure.unreadable
        }

        guard let payload = try? JSONDecoder().decode([Payload].self, from: data) else {
            throw Failure.unreadable
        }
        let releases = payload.map(\.release)
        guard !releases.isEmpty else { throw Failure.noReleases }
        return releases
    }

    /// Downloads an asset to `destination`, reporting bytes as they land.
    /// `URLSession`'s async `download(from:)` says nothing until it is done,
    /// and a dSYM archive is tens of megabytes.
    static func download(
        _ asset: Asset,
        to destination: URL,
        progress: @escaping @Sendable (Double?, Int64) -> Void,
    ) async throws {
        guard asset.byteCount <= downloadByteLimit else { throw Failure.tooLarge }
        let downloader = Downloader(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: asset.downloadURL)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Downloader: NSObject, URLSessionDownloadDelegate {
        var continuation: CheckedContinuation<Void, Error>?

        private let destination: URL
        private let progress: @Sendable (Double?, Int64) -> Void

        init(destination: URL, progress: @escaping @Sendable (Double?, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(
            _: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64,
        ) {
            guard totalBytesWritten <= GitHubReleaseSymbols.downloadByteLimit else { return downloadTask.cancel() }
            let fraction = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : nil
            progress(fraction, totalBytesWritten)
        }

        func urlSession(
            _: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL,
        ) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return finish(.failure(Failure.unreadable)) }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success(()))
            } catch {
                finish(.failure(Failure.unreadable))
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error = error as NSError? else { return }
            finish(.failure(error.code == NSURLErrorCancelled ? CancellationError() : Failure.offline))
        }

        /// `didFinishDownloadingTo` and `didCompleteWithError` both arrive for
        /// one task; whichever is first is the answer. The slot is emptied
        /// before the resume, so a one-shot continuation is resumed once.
        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    // MARK: Remembered repositories

    /// The last few repositories the user typed, newest first.
    private static let recentDefaultsKey = "GitHubReleaseSymbols.recent"
    private static let recentLimit = 5

    static var recentRepositories: [Repository] {
        (UserDefaults.standard.stringArray(forKey: recentDefaultsKey) ?? [])
            .compactMap(repository(from:))
    }

    static func remember(_ repository: Repository) {
        var slugs = recentRepositories.filter { $0 != repository }.map(\.slug)
        slugs.insert(repository.slug, at: 0)
        UserDefaults.standard.set(Array(slugs.prefix(recentLimit)), forKey: recentDefaultsKey)
    }

    /// The wire shape, kept private so the rest of the app never sees GitHub's
    /// spelling of anything.
    private struct Payload: Decodable {
        struct AssetPayload: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int64
        }

        var tag_name: String
        var name: String?
        var published_at: String?
        var prerelease: Bool?
        var assets: [AssetPayload]?

        var release: Release {
            Release(
                tag: tag_name,
                name: (name?.isEmpty == false && name != tag_name) ? name : nil,
                published: published_at.flatMap(Payload.formatter.date(from:)),
                isPrerelease: prerelease ?? false,
                assets: (assets ?? []).map {
                    Asset(name: $0.name, downloadURL: $0.browser_download_url, byteCount: $0.size)
                },
            )
        }

        private static let formatter = ISO8601DateFormatter()
    }
}

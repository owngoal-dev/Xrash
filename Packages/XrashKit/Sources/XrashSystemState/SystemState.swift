import Foundation
import XrashBlame

#if canImport(IcliSystem)
    import IcliSystem
#endif

/// One collected file, written to disk under the directory the caller named.
///
/// On disk rather than in memory because everything that happens to it next
/// wants a path: the review screen reads it, Fila opens it, the archive stores
/// it, and the services dump alone is a few megabytes.
public struct SystemStateFile: Hashable, Sendable, Identifiable {
    public var id: String {
        name
    }

    /// `launchd-services.json`.
    public var name: String
    public var url: URL
    public var byteCount: UInt64

    public init(name: String, url: URL, byteCount: UInt64) {
        self.name = name
        self.url = url
        self.byteCount = byteCount
    }
}

/// A read-only dump of the machine: the services launchd knows, the apps
/// LaunchServices has registered, the installed packages, the tweaks, the
/// running processes, the device itself and the kernel's memory policy.
///
/// Every file is collected on its own and a collector that fails writes
/// `{"error": …}` in place of its contents, because a bundle that loses the
/// process list because launchd would not talk is worse than one that says so.
/// JSON is written with sorted keys and indentation so that two collections of
/// the same device diff line by line.
public enum SystemState {
    /// False off a device: `IcliSystem` reads launchd, LaunchServices and the
    /// bootstrap, and neither the simulator nor a Mac has those to read.
    /// Nothing is offered rather than offered disabled — there is no excuse
    /// worth giving a person for a row about another machine's insides.
    public static var isAvailable: Bool {
        #if canImport(IcliSystem) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
            true
        #else
            false
        #endif
    }

    /// The launchd variables worth recording: the search path, and the ways
    /// something gets itself into every process on the machine.
    static let environmentKeys = [
        "PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "_MSSafeMode",
    ]

    /// Collects into `directory`, which the caller owns and removes. `progress`
    /// is called with each file's name as that file is started; there is no
    /// cancellation because the slow part is one launchd call that cannot be
    /// stopped once it has been asked.
    ///
    /// `packages` is the dpkg database the app already has; without one the
    /// package list fails like any other collector and says so in its file.
    ///
    /// Synchronous, and meant to be called off the main actor.
    public static func collect(
        into directory: URL,
        packages: DpkgDatabase?,
        progress: (String) -> Void = { _ in }
    ) -> [SystemStateFile] {
        // ponytail: one lock around the whole collection. The icli calls are
        // synchronous and not audited for concurrency, and nothing here is hot
        // enough to want two at once.
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var collected = [SystemStateFile]()
        for collector in collectors(packages: packages) {
            progress(collector.name)
            let data: Data
            do {
                data = try serialise(collector.collect())
            } catch {
                data = failure(error)
            }
            let url = directory.appendingPathComponent(collector.name)
            guard (try? data.write(to: url, options: .atomic)) != nil else { continue }
            collected.append(
                SystemStateFile(name: collector.name, url: url, byteCount: UInt64(data.count))
            )
        }
        return collected
    }

    /// The files, in the order they are collected and shown. One list per
    /// build, so the review screen and the archive cannot disagree about
    /// either; both lists carry the same names in the same order, because a
    /// snapshot taken off a device should still have a device's shape.
    private static func collectors(packages: DpkgDatabase?) -> [Collector] {
        #if canImport(IcliSystem)
            return [
                Collector("device.json") { try deviceSnapshot() },
                Collector("launchd-services.json") { try servicesDump() },
                Collector("launchd-disabled.json") { try disabledServiceOverrides() },
                Collector("launchd-environment.json") { try environment() },
                Collector("apps.json") { try listApps() },
                Collector("packages.json") { try SystemState.packages(packages) },
                Collector("tweaks.json") { try tweaks(packages) },
                Collector("processes.json") { try listProcesses(filter: nil) },
                Collector("jetsam.json") { try jetsam() },
                Collector("jetsam-properties.json") { try jetsamProperties() },
            ]
        #else
            // The dpkg database is a file, so it reads anywhere; everything
            // else here is launchd, LaunchServices or the kernel, and each of
            // those files says so instead of being missing.
            return [
                Collector("device.json") { throw off },
                Collector("launchd-services.json") { throw off },
                Collector("launchd-disabled.json") { throw off },
                Collector("launchd-environment.json") { throw off },
                Collector("apps.json") { throw off },
                Collector("packages.json") { try SystemState.packages(packages) },
                Collector("tweaks.json") { throw off },
                Collector("processes.json") { throw off },
                Collector("jetsam.json") { throw off },
                Collector("jetsam-properties.json") { throw off },
            ]
        #endif
    }

    private struct Collector {
        var name: String
        var collect: () throws -> [String: Any]

        init(_ name: String, _ collect: @escaping () throws -> [String: Any]) {
            self.name = name
            self.collect = collect
        }
    }

    private static let lock = NSLock()

    // MARK: Writing

    /// Sorted keys and indentation: the whole point of these files is that two
    /// of them can be diffed.
    static func serialise(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// What a collector's failure looks like on disk. Not thrown onwards: the
    /// other nine files are still worth having.
    static func failure(_ error: Error) -> Data {
        (try? serialise(["error": reason(of: error)])) ?? Data(#"{"error": ""}"#.utf8)
    }

    /// A collector's complaint as its file should record it. These words are
    /// evidence inside a JSON file rather than interface copy, so they are not
    /// catalogue keys: `IcliError` keeps its own in `message`, where
    /// `localizedDescription` on one reads "IcliError error 4".
    static func reason(of error: Error) -> String {
        if let failure = error as? SystemStateFailure {
            return failure.reason
        }
        #if canImport(IcliSystem)
            if let icli = error as? IcliError {
                return icli.message
            }
        #endif
        return error.localizedDescription
    }

    /// Every installed package as the dpkg database describes it.
    ///
    /// Not from `IcliSystem`: Xrash reads dpkg itself for the blame column, and
    /// two readers of one database would drift apart.
    static func packages(_ database: DpkgDatabase?) throws -> [String: Any] {
        guard let database else {
            throw SystemStateFailure(reason: "no install root, so no package database")
        }
        let rows = database.installedPackages().map { owner -> [String: Any] in
            var row: [String: Any] = ["identifier": owner.identifier]
            row["name"] = owner.name
            row["version"] = owner.version
            row["maintainer"] = owner.maintainer
            row["installed"] = owner.installed.map(Self.timestamp.string(from:))
            return row
        }
        return ["packages": rows, "count": rows.count]
    }

    private static let timestamp = ISO8601DateFormatter()

    // MARK: The device's own answers

    #if canImport(IcliSystem)
        /// One call per key, each failing on its own: a variable launchd will
        /// not answer for must not cost the others.
        private static func environment() throws -> [String: Any] {
            var values = [String: Any]()
            for key in environmentKeys {
                do {
                    values[key] = try launchdEnvironment(key)
                } catch {
                    values[key] = ["error": reason(of: error)]
                }
            }
            return ["environment": values]
        }

        /// The injected dylibs, each with the package that installed it — the
        /// question a crash report actually asks of this list.
        private static func tweaks(_ packages: DpkgDatabase?) throws -> [String: Any] {
            let paths = try listTweaks()["tweaks"] as? [String] ?? []
            let rows = paths.sorted().map { path -> [String: Any] in
                var row: [String: Any] = ["path": path]
                guard let owner = packages?.owner(ofPath: path) else { return row }
                row["package"] = owner.identifier
                row["packageName"] = owner.name
                row["packageVersion"] = owner.version
                return row
            }
            return ["tweaks": rows, "count": rows.count]
        }

        /// The bands and the memory pressure. The property lists are a file of
        /// their own: they are the largest part of the snapshot and the part
        /// that is the same in every report from one OS build.
        private static func jetsam() throws -> [String: Any] {
            var snapshot = try jetsamSnapshot()
            snapshot.removeValue(forKey: "properties")
            return snapshot
        }

        private static func jetsamProperties() throws -> [String: Any] {
            try ["properties": jetsamSnapshot()["properties"] as? [String: Any] ?? [:]]
        }
    #else
        private static let off = SystemStateFailure(
            reason: "system state can only be collected on the device"
        )
    #endif
}

/// Why a collector wrote an error instead of its contents. Recorded in that
/// file and nowhere else — `collect` never throws, so this never reaches the
/// interface and needs no words from the catalogue.
public struct SystemStateFailure: Error, Hashable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

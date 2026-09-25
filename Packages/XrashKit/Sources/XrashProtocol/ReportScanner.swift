import Darwin
import Foundation

/// Where the system writes reports. Fixed here and nowhere else: the daemon
/// lists, opens and deletes below these and refuses everything outside them.
public enum ReportRoots {
    private static let fixed = [
        "/private/var/mobile/Library/Logs/CrashReporter",
        "/private/var/root/Library/Logs/CrashReporter",
        "/Library/Logs/CrashReporter",
    ]
    private static let systemGroups = "/private/var/containers/Shared/SystemGroup"
    private static let analyticsSuffix = "systemgroup.com.apple.osanalytics/DiagnosticReports"
    /// Where a Mac writes the same reports, per user and for the system.
    /// Listed without a compilation condition: a root that does not resolve is
    /// dropped below, and neither of these exists on a device.
    private static let diagnosticReports = "/Library/Logs/DiagnosticReports"

    /// The canonical roots that exist right now.
    public static func current() -> [String] {
        var candidates = fixed
        let groups = (try? FileManager.default.contentsOfDirectory(atPath: systemGroups)) ?? []
        candidates += groups.map { "\(systemGroups)/\($0)/\(analyticsSuffix)" }
        candidates.append(diagnosticReports)
        if let home = homeDirectory() {
            candidates.append(home + diagnosticReports)
        }
        #if targetEnvironment(simulator)
            // The simulator has no reports of its own; the host's make the UI
            // testable there.
            if let host = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
                candidates.append("\(host)/Library/Logs/DiagnosticReports")
            }
        #endif
        var seen = Set<String>()
        return candidates.compactMap(canonicalRoot).filter { seen.insert($0).inserted }
    }

    /// `realpath(3)` of a root, kept only when it still ends in the two
    /// components it was spelled with.
    ///
    /// `mobile` owns the directories above `CrashReporter` and can replace one
    /// of them with a symlink. Canonicalising alone would then follow it and
    /// make another tree the root that everything below is measured against —
    /// which is every open and every unlink the daemon does as root.
    static func canonicalRoot(_ path: String) -> String? {
        guard let resolved = PathGuard.canonical(path) else { return nil }
        let declaredTail = path.split(separator: "/").suffix(2)
        return resolved.split(separator: "/").suffix(2) == declaredTail ? resolved : nil
    }

    /// The account's real home. Not `NSHomeDirectory()`, which answers a
    /// container when the caller is sandboxed — this app is not, but where the
    /// reports are has no business depending on that staying true.
    private static func homeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let home = String(cString: directory)
        return home == "/" ? nil : home
    }
}

/// Where a Mach-O that the app may ask root to open is allowed to live.
///
/// `openImage` takes a path from a crash report rather than from a directory
/// the daemon listed itself, so it is an allow-list and not a deny-list: the
/// OS, the bootstrap, installed app bundles and the dyld shared cache. A user's
/// data container is not on it, and neither is `/private/etc`.
public enum ImageRoots {
    private static let fixed = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",
        "/Applications",
        // Where a bootstrap that injects from outside itself keeps its hook.
        "/cores",
        "/private/preboot/Cryptexes",
        // Installed apps, and roothide's randomised bootstrap.
        "/private/var/containers/Bundle",
    ]

    /// Dyld shared cache directories, across the OS versions this app runs on.
    public static let sharedCacheDirectories = [
        "/System/Library/Caches/com.apple.dyld",
        "/System/Library/dyld",
        "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
        "/private/preboot/Cryptexes/OS/System/Library/dyld",
        "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
        "/System/Cryptexes/OS/System/Library/dyld",
    ]

    /// The canonical roots an image may sit under. `installRoot` is one of them
    /// because that is where every tweak on the device lives.
    ///
    /// `/` is the Mac's answer to "which bootstrap": there is none. Adding it
    /// would put every path inside a root and turn the allow-list off.
    public static func current(installRoot: String) -> [String] {
        (fixed + (installRoot == "/" ? [] : [installRoot])).compactMap(PathGuard.canonical)
    }

    /// A subcache is not a Mach-O, so it is the one thing `openImage` hands
    /// back without recognising its first four bytes.
    public static func isSharedCache(_ canonicalPath: String) -> Bool {
        sharedCacheDirectories.compactMap(PathGuard.canonical).contains {
            PathGuard.isInside(canonicalPath, root: $0)
        }
    }
}

/// Walks report roots with whatever permissions the calling process has. The
/// daemon runs it as root; the app runs the same code as its own fallback.
public struct ReportScanner {
    /// `Retired/`, `DiagnosticLogs/…` and friends sit one or two levels down.
    private static let maximumDepth = 3
    private static let maximumEntryCount = 50000

    private let roots: [String]

    public init(roots: [String] = ReportRoots.current()) {
        self.roots = roots
    }

    /// Every regular file below the roots. No extension filter: four reports
    /// in five end in `.synced`, and classifying names is the decoder's job.
    public func scan() -> [ReportEntry] {
        var entries = [ReportEntry]()
        for root in roots {
            walk(root, depth: 0, into: &entries)
        }
        return entries
    }

    private func walk(_ directory: String, depth: Int, into entries: inout [ReportEntry]) {
        guard depth <= Self.maximumDepth,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where !name.hasPrefix(".") {
            guard entries.count < Self.maximumEntryCount else { return }
            let path = "\(directory)/\(name)"
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else { continue }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                walk(path, depth: depth + 1, into: &entries)
            case S_IFREG:
                entries.append(ReportEntry(
                    path: path,
                    byteCount: UInt64(max(metadata.st_size, 0)),
                    modified: Date(
                        timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                            + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000,
                    ),
                    ownerUserID: metadata.st_uid,
                ))
            default:
                continue
            }
        }
    }
}

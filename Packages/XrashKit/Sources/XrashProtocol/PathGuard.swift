import Darwin
import Foundation

/// Path decisions, made the same way on both sides of the wire: canonicalise
/// first, then compare components. A prefix test on strings lets
/// `/var/mobile/Library/Logs/CrashReporterEvil` pass for `…/CrashReporter`.
public enum PathGuard {
    /// `realpath(3)` of `path`, or nil when it has an embedded NUL, is not
    /// absolute, or does not resolve.
    public static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withCString({ realpath($0, &buffer) }) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Whether `path` is strictly below `root`. Both must already be canonical.
    public static func isInside(_ path: String, root: String) -> Bool {
        let pathComponents = path.split(separator: "/")
        let rootComponents = root.split(separator: "/")
        return pathComponents.count > rootComponents.count
            && pathComponents.starts(with: rootComponents)
    }

    /// The canonical form of `path` when it is a regular file below one of
    /// `roots`, else nil.
    public static func regularFile(_ path: String, below roots: [String]) -> String? {
        guard let resolved = canonical(path),
              roots.contains(where: { isInside(resolved, root: $0) }) else { return nil }
        var metadata = stat()
        guard lstat(resolved, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return resolved
    }
}

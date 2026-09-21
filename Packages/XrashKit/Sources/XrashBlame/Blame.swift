import Foundation
import XrashReport

public struct PackageOwner: Codable, Hashable, Sendable {
    /// `com.example.tweak`.
    public var identifier: String
    public var name: String?
    public var version: String?
    /// `Jane Doe <jane@example.com>`, as the status file spells it.
    public var maintainer: String?
    public var installed: Date?

    public init(identifier: String) {
        self.identifier = identifier
    }

    /// The address to write to, out of `Jane Doe <jane@example.com>`; the last
    /// bracketed address wins, and a field without brackets is the address
    /// itself. A status file is a file on disk, so the candidate is checked
    /// rather than trusted: one address, no display name, and nothing that
    /// could carry a second recipient or a header of its own.
    public var maintainerAddress: String? {
        guard let maintainer else { return nil }
        let bracketed = maintainer.split(separator: "<").dropFirst().compactMap { part in
            part.firstIndex(of: ">").map { String(part[..<$0]) }
        }
        let candidate = bracketed.last { $0.contains("@") }
            ?? maintainer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("@"), candidate.rangeOfCharacter(from: Self.notInAnAddress) == nil else {
            return nil
        }
        return candidate
    }

    private static let notInAnAddress = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: ",;<>"))
}

/// Reads dpkg's database below the install root `hello` reported. World
/// readable on both bootstraps, so no daemon operation exists for it.
public final class DpkgDatabase: @unchecked Sendable {
    private let root: String?
    /// ponytail: one lock around one build. Lookups are a dictionary hit after
    /// it; split it only if two report views ever contend on the first query.
    private let lock = NSLock()
    private var index: DpkgIndex?
    private var didBuild = false

    /// `installRoot` is `BackendStatus.privileged(installRoot:)`; nil finds nothing.
    public init(installRoot: String?) {
        root = installRoot.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// The package whose file list contains `path`. A report spells an image
    /// path the way dyld loaded it and dpkg spells it the way the bootstrap
    /// installed it, so neither side is canonical and every form is tried.
    public func owner(ofPath path: String) -> PackageOwner? {
        guard let index = loaded() else { return nil }
        for spelling in Self.spellings(of: path, root: root) {
            guard let package = index.packageByPath[spelling] else { continue }
            return index.ownerByPackage[package] ?? PackageOwner(identifier: package)
        }
        return nil
    }

    /// Every package with a file list, so every installed one, in identifier
    /// order — a report's package list is read beside another report's.
    public func installedPackages() -> [PackageOwner] {
        guard let index = loaded() else { return [] }
        return index.ownerByPackage.values.sorted { $0.identifier < $1.identifier }
    }

    /// Built on the first query and never again: an unreadable database stays
    /// unreadable, and a miss must not re-scan a thousand files.
    private func loaded() -> DpkgIndex? {
        lock.lock()
        defer { lock.unlock() }
        if !didBuild {
            didBuild = true
            index = root.flatMap(DpkgIndex.build(root:))
        }
        return index
    }

    /// The forms a `.list` file might hold this path in. Rootless lists carry
    /// the `/var/jb` symlink and roothide and rootful ones are prefix-relative,
    /// while the path in the report may be either spelling and may or may not
    /// have come through `/private`.
    private static func spellings(of path: String, root: String?) -> [String] {
        var spellings = [String]()
        func add(_ spelling: String) {
            guard spelling.hasPrefix("/"), !spellings.contains(spelling) else { return }
            spellings.append(spelling)
        }
        for form in [path, throughPrivate(path)].compactMap(\.self) {
            add(form)
            if let root, root != "/", form.hasPrefix(root) {
                let relative = String(form.dropFirst(root.count))
                add(relative)
                add(Self.rootlessPrefix + relative)
            }
            if form.hasPrefix(Self.rootlessPrefix + "/") {
                add(String(form.dropFirst(Self.rootlessPrefix.count)))
            }
        }
        return spellings
    }

    /// Where a rootless bootstrap is reached from, as dyld records it.
    private static let rootlessPrefix = "/var/jb"

    /// The same file said the other way round: `/var/x` and `/private/var/x`
    /// are one path, and only one of them matches an install root that has
    /// been through `realpath(3)`.
    private static func throughPrivate(_ path: String) -> String? {
        if path.hasPrefix("/private/") {
            return String(path.dropFirst("/private".count))
        }
        return ["/var/", "/etc/", "/tmp/"].contains(where: path.hasPrefix) ? "/private" + path : nil
    }
}

public struct Suspect: Codable, Hashable, Sendable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        /// Appears on the faulting thread's stack.
        case onFaultingStack
        /// Appears in the last exception backtrace.
        case inExceptionBacktrace
        /// Loaded from a tweak injection directory.
        case injectedTweak
        /// Not Apple's and not the crashed app's own.
        case thirdPartyImage
        /// Installed or updated shortly before the crash.
        case recentlyInstalled
    }

    /// The image path.
    public var id: String
    public var imageName: String
    public var reasons: [Reason]
    public var owner: PackageOwner?
    /// Higher is more likely; only meaningful for ordering.
    public var score: Int

    public init(id: String, imageName: String, reasons: [Reason], owner: PackageOwner?, score: Int) {
        self.id = id
        self.imageName = imageName
        self.reasons = reasons
        self.owner = owner
        self.score = score
    }
}

public enum Blame {}

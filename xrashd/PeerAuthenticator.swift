import Darwin
import Foundation
import XPC
import XrashProtocol

/// Decides who may talk to the daemon, before any request is decoded.
///
/// There are two policies and they never mix; a peer is judged by exactly one:
///
/// - **On the device** this process is root under the bootstrap's launchd. A
///   peer must carry the client entitlement, run as root or mobile, and *be*
///   the installed, root-owned app binary under the install root derived from
///   this process's own path.
/// - **On macOS** it is a per-user LaunchAgent and the client is a Mac Catalyst
///   app, which cannot carry the entitlement at all — an iOS-family binary
///   macOS refuses to launch when it holds one no profile granted. Same user
///   plus the app that shipped beside this helper is the whole gate there, and
///   it has to be: a peer of that uid can already read every report this helper
///   would open for it.
final class PeerAuthenticator {
    private static let mobileUserID: UInt32 = 501
    private static let requiredEntitlements = [
        XrashService.clientEntitlement,
        "platform-application",
        "com.apple.private.security.no-sandbox",
    ]

    /// Whatever precedes `/usr/libexec/xrashd` in this process's own path. No
    /// prefix is written in Swift; `hello` hands this one to the app.
    let installRoot: String?
    private let installedClientPath: String?

    #if os(macOS)

        init() {
            // A Mac has no bootstrap to name, so the root every image is
            // measured against is the filesystem's own — `ImageRoots` drops it
            // rather than letting it widen the allow-list. What *is* derived
            // from `proc_pidpath` here is the client: the app beside this
            // helper in `Contents/MacOS`, where `Scripts/package-mac.sh`
            // stages both and where `BundleProgram` launches this one from.
            installRoot = "/"
            installedClientPath = Self.siblingApp()
        }

        func authenticate(_ connection: xpc_connection_t) -> Bool {
            var token = audit_token_t()
            xrashXPCConnectionGetAuditToken(connection, &token)
            let pid = Int32(bitPattern: token.val.5)
            guard pid > 1, token.val.1 == getuid(), let path = processPath(pid: pid) else { return false }
            if let installedClientPath, path == installedClientPath {
                return true
            }
            #if DEBUG
                // `make mac-run`: this helper is a DerivedData binary loaded
                // through a sidecar LaunchAgent, and the Catalyst app Xcode
                // built beside it is in a different products directory — the
                // two are not bundle siblings and neither is signed by
                // anything. No Release build knows this peer.
                return path.hasSuffix(XrashService.macAppExecutableSuffix)
            #else
                return false
            #endif
        }

        /// `<bundle>/Contents/MacOS/Xrash`, when this helper is itself
        /// `<bundle>/Contents/MacOS/xrashd`. Nil for the harness build, which
        /// sits in DerivedData beside nothing.
        private static func siblingApp() -> String? {
            guard let own = processPath(pid: getpid()) else { return nil }
            let directory = (own as NSString).deletingLastPathComponent
            guard directory.hasSuffix("/Contents/MacOS") else { return nil }
            return PathGuard.canonical(directory + "/" + XrashService.macAppExecutableName)
        }

    #else

        init() {
            let suffix = XrashService.daemonPathSuffix
            if let daemonPath = processPath(pid: getpid()), daemonPath.hasSuffix(suffix) {
                let root = String(daemonPath.dropLast(suffix.count))
                installRoot = root
                installedClientPath = PathGuard.canonical(root + XrashService.appExecutablePathSuffix)
            } else {
                installRoot = nil
                installedClientPath = nil
            }
        }

        func authenticate(_ connection: xpc_connection_t) -> Bool {
            var token = audit_token_t()
            xrashXPCConnectionGetAuditToken(connection, &token)
            let pid = Int32(bitPattern: token.val.5)
            guard pid > 1,
                  token.val.1 == 0 || token.val.1 == Self.mobileUserID,
                  hasRequiredEntitlements(token: &token),
                  let installedClientPath,
                  isRootOwnedExecutable(installedClientPath) else { return false }
            return processPath(pid: pid) == installedClientPath
        }

        private func hasRequiredEntitlements(token: inout audit_token_t) -> Bool {
            Self.requiredEntitlements.allSatisfy { entitlement in
                guard let value = entitlement.withCString({ xrashXPCCopyEntitlement($0, &token) }) else {
                    return false
                }
                return xpc_get_type(value) == XrashXPC.typeBool && xpc_bool_get_value(value)
            }
        }

        private func isRootOwnedExecutable(_ path: String) -> Bool {
            var metadata = stat()
            guard stat(path, &metadata) == 0 else { return false }
            return metadata.st_uid == 0
                && metadata.st_mode & S_IFMT == S_IFREG
                && metadata.st_mode & S_IXUSR != 0
                && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
        }

    #endif
}

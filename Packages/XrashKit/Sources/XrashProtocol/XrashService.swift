/// The names both sides agree on. They are named after the app so two OwnGoal
/// apps cannot admit each other's peers; the packaging inputs spell the same
/// strings and `Scripts/package-deb.sh` reads them back out of the signed app.
public enum XrashService {
    /// The Mach service `xrashd` registers through its launchd plist.
    public static let machServiceName = "wiki.qaq.xrash.service"

    /// The private entitlement the daemon's authenticator requires on a peer.
    public static let clientEntitlement = "wiki.qaq.xrash.client"

    /// Where the daemon sits inside an install root. The root itself is never
    /// written down: the daemon derives it from its own `proc_pidpath`.
    public static let daemonPathSuffix = "/usr/libexec/xrashd"

    /// Where the only admitted client sits inside the same install root.
    public static let appExecutablePathSuffix = "/Applications/Xrash.app/Xrash"

    /// The Mac build carries the helper inside the app bundle, so the client
    /// is its sibling in `Contents/MacOS` rather than a path under a root.
    public static let macAppExecutableName = "Xrash"

    /// What the Mac Catalyst app's executable path ends in, wherever the
    /// bundle sits. `Scripts/package-mac.sh` stages it there and the
    /// `make mac-run` harness builds it there.
    public static let macAppExecutableSuffix = "/Xrash.app/Contents/MacOS/Xrash"

    /// The bundled LaunchAgent, registered by file name through
    /// `SMAppService.agent(plistName:)`. `Scripts/package-mac.sh` stages the
    /// same name into `Contents/Library/LaunchAgents`.
    public static let macAgentPlistName = "wiki.qaq.xrashd.plist"
}

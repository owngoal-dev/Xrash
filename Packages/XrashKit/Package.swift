// swift-tools-version: 5.10
import PackageDescription

/// Everything that is not UIKit lives here so it is testable on a Mac with
/// plain `swift test`: the wire protocol, the report parsers, symbolication.
///
/// `xrashd` links XrashProtocol only. launchd caps a LaunchDaemon at 6 MB, so
/// nothing third-party may reach a target the daemon links.
let package = Package(
    name: "XrashKit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "XrashProtocol", targets: ["XrashProtocol"]),
        // What the app links: one product, so a new module is a line here and
        // never an edit to the hand-written project file.
        .library(name: "XrashKit", targets: [
            "XrashProtocol", "XrashClient", "XrashReport", "XrashSymbols", "XrashBlame", "XrashBundle",
            "XrashSystemState",
        ]),
    ],
    dependencies: [
        // Mach-O and dyld shared cache parsing, as Fila and Irisin use it. It
        // trusts what it reads and traps on nonsense: XrashSymbols validates
        // headers before handing it a file.
        .package(url: "https://github.com/p-x9/MachOKit.git", from: "0.52.2"),
        // MachOKit's own dependency, named here only to hold it back: 0.15.0
        // dropped what swift-fileio-extra 0.2.2 reads. XrashSymbols lists the
        // product because Xcode drops the constraint of a dependency no target
        // uses. Goes when MachOKit has a release that builds against 0.15.
        .package(url: "https://github.com/p-x9/swift-fileio.git", "0.14.0" ..< "0.15.0"),
        // Zip writing and reading for `.xrashreport` and zipped dSYMs.
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "0.1.1"),
        // Read-only system state — launchd, LaunchServices, processes, jetsam —
        // for the report bundle. `IcliSystem` is the half of icli that links
        // Foundation and CoreFoundation and nothing else, and it resolves every
        // private symbol it names at runtime, so it is safe on an iOS 15 floor.
        // Nothing here changes system state; the half that does stays in
        // `IcliKit`, which this does not link.
        .package(url: "https://github.com/owngoal-dev/icli.git", from: "0.5.0"),
    ],
    targets: [
        // The wire vocabulary. Compiled into both sides, so it must stay free
        // of anything platform-specific beyond XPC.
        .target(name: "XrashProtocol", dependencies: ["CXrashXPC"]),

        // The XPC constants, kept in C so that nothing links the Swift XPC
        // overlay — a dylib iOS 15 does not have. See `XrashXPC`.
        .systemLibrary(name: "CXrashXPC", path: "Sources/CXrashXPC"),

        // The app's end of the wire, and its own-permissions fallback.
        .target(name: "XrashClient", dependencies: ["XrashProtocol"]),

        // The report model, the `.ips` / `.crash` decoders and the text forms.
        // Foundation only.
        .target(name: "XrashReport"),

        // Address → name, file and line. The only target that links MachOKit.
        .target(
            name: "XrashSymbols",
            dependencies: [
                "XrashReport",
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "FileIO", package: "swift-fileio"),
            ]
        ),

        // Which tweak or package a crash points at.
        .target(name: "XrashBlame", dependencies: ["XrashReport"]),

        // The `.xrashreport` archive: manifest plist, zip, crash correlation.
        .target(
            name: "XrashBundle",
            dependencies: [
                "XrashReport",
                // The Swift wrapper and its C framework differ only by case.
                // Give the wrapper a distinct module name for Xcode's loader.
                .product(
                    name: "LibArchive",
                    package: "libarchive.xcframework",
                    moduleAliases: ["LibArchive": "XrashLibArchive"]
                ),
            ]
        ),

        // What is installed and running, as the JSON files a bundle carries.
        // `IcliSystem` is an iOS-only product here — the Mac harness and the
        // Catalyst app build this target without it, and `SystemState` then
        // reports itself unavailable rather than growing a second variant.
        .target(
            name: "XrashSystemState",
            dependencies: [
                "XrashBlame",
                .product(name: "IcliSystem", package: "icli", condition: .when(platforms: [.iOS])),
            ]
        ),

        .testTarget(name: "XrashProtocolTests", dependencies: ["XrashProtocol"]),
        .testTarget(name: "XrashReportTests", dependencies: ["XrashReport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "XrashSymbolsTests", dependencies: ["XrashSymbols"], resources: [.copy("Fixtures")]),
        .testTarget(name: "XrashBlameTests", dependencies: ["XrashBlame"]),
        .testTarget(name: "XrashBundleTests", dependencies: ["XrashBundle"]),
        .testTarget(name: "XrashSystemStateTests", dependencies: ["XrashSystemState"]),
    ]
)

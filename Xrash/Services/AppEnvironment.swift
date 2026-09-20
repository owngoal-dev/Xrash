import Combine
import Foundation
import XrashBlame
import XrashClient
import XrashSymbols

/// The app's long-lived services, made once. View controllers take what they
/// need from `AppEnvironment.shared` in their initialisers' defaults; nothing
/// below the interface layer reaches for it.
final class AppEnvironment {
    static let shared = AppEnvironment()

    let backend: ReportBackend
    let dsyms: DSYMStore
    let systemSymbols: SystemSymbolStore
    let symbolicator: Symbolicator
    let library: ReportLibrary
    let savedBundles: SavedBundleStore

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let backend = ReportBackend()
        self.backend = backend
        dsyms = DSYMStore(directory: support.appendingPathComponent("dSYMs", isDirectory: true))
        systemSymbols = SystemSymbolStore(
            directory: support.appendingPathComponent("SystemSymbols", isDirectory: true)
        )
        symbolicator = Symbolicator(dsyms: dsyms, systemSymbols: systemSymbols) {
            try await backend.openImage(at: $0)
        }
        library = ReportLibrary(backend: backend, symbolicator: symbolicator)
        savedBundles = SavedBundleStore(
            directory: support.appendingPathComponent("Bundles", isDirectory: true)
        )
    }

    /// dpkg's database below the install root the daemon reported; nil while
    /// connecting and when sandboxed.
    var packages: DpkgDatabase? {
        guard case let .privileged(installRoot) = backend.status.value else { return nil }
        if cachedPackages?.root != installRoot {
            cachedPackages = (installRoot, DpkgDatabase(installRoot: installRoot))
        }
        return cachedPackages?.database
    }

    private var cachedPackages: (root: String, database: DpkgDatabase)?
}

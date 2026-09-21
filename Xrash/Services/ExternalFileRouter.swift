import UIKit
import UniformTypeIdentifiers
import XrashSymbols

extension UTType {
    /// Declared in `Configuration/Xrash-Info.plist`. Looked up rather than
    /// `UTType(exportedAs:)`, which traps when the declaration is missing.
    static let xrashReport = UTType("wiki.qaq.xrash.report") ?? .zip

    /// Imported in the same file. What a row dragged out of the list is.
    static let diagnosticReport = UTType("com.apple.ips") ?? .data
}

/// Where a file handed to the app goes: a report into the library, a dSYM
/// into the symbol store, an `.xrashreport` into Saved.
///
/// Every route ends on the page that now holds the file, because a file that
/// vanishes into an app without a word looks like a file that was lost.
///
/// The app opens documents in place (`LSSupportsOpeningDocumentsInPlace`), so
/// what arrives here is somebody else's file where it lies — no Inbox copy to
/// inherit. Every route therefore holds
/// `start/stopAccessingSecurityScopedResource` across its read and copies
/// whatever it means to keep before the access is given back.
@MainActor
enum ExternalFileRouter {
    private enum Destination: Int {
        case reports = 0, saved = 1, symbols = 2
    }

    static func open(_ urls: [URL], from root: UIViewController?) {
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "xrashreport":
                openBundle(url, from: root)
            case "ips", "crash", "synced", "json", "txt", "log", "beta", "panic":
                openReport(url, from: root)
            case "dsym", "zip", "dwarf":
                openSymbols(url, from: root)
            default:
                presentUnsupported(url, from: root)
            }
        }
    }

    // MARK: Routes

    private static func openBundle(_ url: URL, from root: UIViewController?) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bundle = try AppEnvironment.shared.savedBundles.add(archiveAt: url)
            (select(.saved, in: root) as? SavedReportsViewController)?.show(bundleID: bundle.id)
        } catch {
            present("Unable to Open Report", error.localizedDescription, from: root)
        }
    }

    private static func openReport(_ url: URL, from root: UIViewController?) {
        Task {
            do {
                _ = try await AppEnvironment.shared.library.importReport(at: url)
                select(.reports, in: root)
            } catch {
                present("Unable to Open Report", error.localizedDescription, from: root)
            }
        }
    }

    private static func openSymbols(_ url: URL, from root: UIViewController?) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            // Through the shared unpacker, not the store: a dropped or opened
            // file is as often a zip of a dSYM as the dSYM itself, and the
            // store reads Mach-O and does not unpack.
            _ = try DSYMImport.run(at: url, into: AppEnvironment.shared.dsyms)
            select(.symbols, in: root)
        } catch {
            present("Unable to Import Symbols", error.localizedDescription, from: root)
        }
    }

    private static func presentUnsupported(_ url: URL, from root: UIViewController?) {
        present(
            "Unable to Open File",
            String(localized: "“\(url.lastPathComponent)” is not a crash report, a dSYM, or an Xrash report."),
            from: root
        )
    }

    // MARK: Plumbing

    /// Brings a page forward and hands back its root controller, so the route
    /// that opened a file can also show it.
    @discardableResult
    private static func select(_ destination: Destination, in root: UIViewController?) -> UIViewController? {
        // The root is the split view, always; the tabs are its compact column.
        // Looked for there as well, or a file opened or dropped on a phone
        // lands in the library and never brings its page forward.
        let tabs = root as? UITabBarController
            ?? (root as? UISplitViewController)?.viewController(for: .compact) as? UITabBarController
        guard let tabs,
              let pages = tabs.viewControllers, pages.indices.contains(destination.rawValue)
        else { return nil }
        tabs.selectedIndex = destination.rawValue
        let page = pages[destination.rawValue]
        return (page as? UINavigationController)?.viewControllers.first ?? page
    }

    /// The message is a failure's own words or a file name — never a literal
    /// to be localised.
    private static func present(
        _ title: String.LocalizationValue,
        _ message: String,
        from root: UIViewController?
    ) {
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        top?.presentMessage(title, message: String.LocalizationValue(message))
    }
}

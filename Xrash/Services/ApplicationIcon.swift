import Foundation
import ImageIO
import ObjectiveC.runtime
import UIKit
import XrashProtocol

/// Ported from Inspector, where the same question is asked of a running
/// process rather than of a report.
enum ApplicationBundleLocator {
    /// An executable path inside `Host.app/PlugIns/Extension.appex` belongs to
    /// the host app, so the first `.app` component is the answer for both the
    /// main executable and every plug-in.
    static func hostApplicationPath(for executablePath: String) -> String? {
        guard let path = PathGuard.canonical(executablePath),
              path.range(of: "/Bundle/Application/", options: .caseInsensitive) != nil
            || path.range(of: "/Applications/", options: .caseInsensitive) != nil,
            let appBoundary = path.range(of: ".app/", options: .caseInsensitive)
        else {
            return nil
        }
        let trailingSlash = path.index(before: appBoundary.upperBound)
        return String(path[..<trailingSlash])
    }
}

/// App icons read from installed bundles, without asking IconServices to
/// render them. Its placeholder compositor can crash inside Core Image before
/// returning an image, even for an intentionally nonexistent bundle id.
/// LaunchServices is used only to locate a bundle; a missing bitmap leaves the
/// row's own fallback artwork in place.
actor ApplicationIconProvider {
    static let shared = ApplicationIconProvider()

    private var cache = [String: UIImage?]()
    private var pending = [String: Task<UIImage?, Never>]()

    /// `bundleID` comes from the report header and wins: a crashed app may
    /// have moved since the report was written. The executable's path is the
    /// fallback when LaunchServices does not know the app.
    func icon(bundleID: String?, executablePath: String?) async -> UIImage? {
        let applicationPath = executablePath.flatMap(ApplicationBundleLocator.hostApplicationPath)
        guard bundleID != nil || applicationPath != nil else { return nil }

        let key = "\(bundleID ?? "")|\(applicationPath ?? "")"
        if let cached = cache[key] {
            return cached
        }
        if let pending = pending[key] {
            return await pending.value
        }

        let load = Task.detached(priority: .utility) {
            Self.loadIcon(bundleID: bundleID, applicationPath: applicationPath)
        }
        pending[key] = load
        let icon = await load.value
        pending[key] = nil
        cache[key] = icon
        return icon
    }

    private nonisolated static func loadIcon(
        bundleID: String?,
        applicationPath: String?
    ) -> UIImage? {
        autoreleasepool {
            if let bundleID, let bundle = registeredBundle(identifier: bundleID),
               let icon = bundledIcon(in: bundle)
            {
                return icon
            }
            guard let applicationPath, let path = PathGuard.canonical(applicationPath),
                  let bundle = Bundle(path: path) else { return nil }
            return bundledIcon(in: bundle)
        }
    }

    private typealias ApplicationProxyImplementation = @convention(c) (
        AnyObject,
        Selector,
        NSString
    ) -> Unmanaged<NSObject>?

    /// Resolve metadata only. No icon method is called on the proxy, and the
    /// private class and selectors are optional on every supported platform.
    private nonisolated static func registeredBundle(identifier: String) -> Bundle? {
        guard !identifier.isEmpty, !identifier.utf8.contains(0) else { return nil }
        if identifier == Bundle.main.bundleIdentifier {
            return .main
        }
        let selector = NSSelectorFromString("applicationProxyForIdentifier:")
        guard let proxyClass = NSClassFromString("LSApplicationProxy"),
              let method = class_getClassMethod(proxyClass, selector) else { return nil }
        let implementation = unsafeBitCast(
            method_getImplementation(method),
            to: ApplicationProxyImplementation.self
        )
        let bundleURL = NSSelectorFromString("bundleURL")
        guard let proxy = implementation(proxyClass as AnyObject, selector, identifier as NSString)?.takeUnretainedValue(),
              proxy.responds(to: bundleURL),
              let url = proxy.perform(bundleURL)?.takeUnretainedValue() as? URL,
              url.isFileURL, let path = PathGuard.canonical(url.path) else { return nil }
        return Bundle(path: path)
    }

    /// actool emits loose fallback PNGs for app icons, including those made
    /// with Icon Composer. Read those files directly, at their native size,
    /// so the detail view can share the row's image without scaling it up first.
    ///
    /// Loose means a file: a name out of someone else's plist is never handed
    /// to `UIImage(named:in:)`. A catalogue built from an Icon Composer `.icon`
    /// holds names that are image stacks with no bitmap, and iOS 26 answers a
    /// lookup of one with an assertion, not nil (`AppIcon` in our own did).
    private nonisolated static func bundledIcon(in bundle: Bundle) -> UIImage? {
        guard let resources = bundle.resourceURL,
              let root = PathGuard.canonical(resources.path) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        var names = info["CFBundleIconFiles"] as? [String] ?? []
        if let name = info["CFBundleIconFile"] as? String {
            names.append(name)
        }
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            names.append(contentsOf: files)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        // Keep the bitmap with the most pixels for both the row and the
        // report header. A file can be declared under more than one key.
        var best: UIImage?
        var visited = Set<String>()
        for name in names.reversed() {
            let stem = (name as NSString).deletingPathExtension
            guard !stem.isEmpty else { continue }
            let matches = files.filter { file in
                let fileStem = (file as NSString).deletingPathExtension
                let matchesName = fileStem == stem || fileStem.hasPrefix(stem + "@") || fileStem.hasPrefix(stem + "~")
                return matchesName && ["png", "icns"].contains((file as NSString).pathExtension.lowercased())
            }
            for file in matches {
                if let path = PathGuard.regularFile(root + "/" + file, below: [root]),
                   visited.insert(path).inserted,
                   let image = bitmap(at: path),
                   image.size.width * image.scale > (best.map { $0.size.width * $0.scale } ?? 0)
                {
                    best = image
                }
            }
        }
        return best
    }

    /// Native Mac apps declare an .icns file. ImageIO decodes its largest
    /// bitmap directly too; it does not ask the system to compose an app icon.
    private nonisolated static func bitmap(at path: String) -> UIImage? {
        if (path as NSString).pathExtension.lowercased() == "png" {
            return UIImage(contentsOfFile: path)
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        var largestIndex: Int?
        var largestWidth = 0
        for index in 0 ..< CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  width > largestWidth else { continue }
            largestIndex = index
            largestWidth = width
        }
        guard let largestIndex, let image = CGImageSourceCreateImageAtIndex(source, largestIndex, nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

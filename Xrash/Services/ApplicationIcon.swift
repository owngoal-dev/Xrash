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
    /// main executable and every plug-in. This reads the spelling only; the
    /// bundle is canonicalised by `installedApplication` before it is opened.
    static func hostApplicationPath(for executablePath: String) -> String? {
        guard executablePath.hasPrefix("/"), !executablePath.utf8.contains(0) else { return nil }
        let components = (executablePath as NSString).pathComponents
        guard let bundle = components.dropFirst().firstIndex(where: { $0.lowercased().hasSuffix(".app") }),
              bundle < components.count - 1 else { return nil }
        return NSString.path(withComponents: Array(components[...bundle]))
    }

    /// `realpath(3)` of the bundle, not of the executable: a main binary that
    /// is a link out of its `.app` still names that `.app`. Kept only when the
    /// canonical components are an `.app` below an `Applications` directory
    /// or a `Bundle/Application` container.
    static func installedApplication(at applicationPath: String) -> String? {
        guard let path = PathGuard.canonical(applicationPath) else { return nil }
        let components = (path as NSString).pathComponents.map { $0.lowercased() }
        guard let bundle = components.last, bundle.hasSuffix(".app") else { return nil }
        let parents = components.dropLast()
        let installed = parents.contains("applications")
            || zip(parents, parents.dropFirst()).contains { $0 == "bundle" && $1 == "application" }
        return installed ? path : nil
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
            let registered = bundleID.flatMap(registeredBundlePath)
            if let registered, let icon = bundledIcon(at: registered) {
                return icon
            }
            // The executable's own bundle, unless that is the one just read.
            guard let applicationPath,
                  let path = ApplicationBundleLocator.installedApplication(at: applicationPath),
                  path != registered else { return nil }
            return bundledIcon(at: path)
        }
    }

    private typealias ApplicationProxyImplementation = @convention(c) (
        AnyObject,
        Selector,
        NSString
    ) -> Unmanaged<NSObject>?

    /// Resolve metadata only. No icon method is called on the proxy, and the
    /// private class and selectors are optional on every supported platform.
    private nonisolated static func registeredBundlePath(identifier: String) -> String? {
        guard !identifier.isEmpty, !identifier.utf8.contains(0) else { return nil }
        if identifier == Bundle.main.bundleIdentifier {
            return PathGuard.canonical(Bundle.main.bundlePath)
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
              url.isFileURL else { return nil }
        return PathGuard.canonical(url.path)
    }

    /// The report header's tile at the densest display: 80 points at 3x.
    /// Nothing draws an icon larger, so nothing is decoded or kept larger.
    private static let largestPixelSide = 240

    /// actool emits loose fallback PNGs for app icons, including those made
    /// with Icon Composer. Read those files directly; the row and the report
    /// header share the largest one.
    ///
    /// Loose means a file: a name out of someone else's plist is never handed
    /// to `UIImage(named:in:)`. A catalogue built from an Icon Composer `.icon`
    /// holds names that are image stacks with no bitmap, and iOS 26 answers a
    /// lookup of one with an assertion, not nil (`AppIcon` in our own did).
    private nonisolated static func bundledIcon(at path: String) -> UIImage? {
        guard let bundle = Bundle(path: path), let resources = bundle.resourceURL,
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
        let stems = Set(names.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        // Every candidate is measured from its header; only the largest is
        // decoded. A universal app declares a dozen sizes of the same picture.
        var best: (source: CGImageSource, index: Int, width: Int)?
        for file in files where isIconFile(file, declaredBy: stems) {
            guard let candidate = PathGuard.regularFile(root + "/" + file, below: [root]),
                  let largest = largestImage(at: candidate),
                  largest.width > best?.width ?? 0 else { continue }
            best = largest
        }
        guard let best else { return nil }
        return decode(best.source, index: best.index)
    }

    private nonisolated static func isIconFile(_ file: String, declaredBy stems: Set<String>) -> Bool {
        guard ["png", "icns"].contains((file as NSString).pathExtension.lowercased()) else { return false }
        let fileStem = (file as NSString).deletingPathExtension
        return stems.contains { stem in
            fileStem == stem || fileStem.hasPrefix(stem + "@") || fileStem.hasPrefix(stem + "~")
        }
    }

    /// The widest image in a file, read from its properties without decoding
    /// it. A PNG holds one; a Mac `.icns` holds every size it was made at.
    private nonisolated static func largestImage(at path: String) -> (source: CGImageSource, index: Int, width: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        var largest: (source: CGImageSource, index: Int, width: Int)?
        for index in 0 ..< CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  width > largest?.width ?? 0 else { continue }
            largest = (source, index, width)
        }
        return largest
    }

    /// Decoded here, off the main thread, and no larger than the header draws
    /// it: a Mac app's 1024-pixel `.icns` would otherwise stay in the cache at
    /// 4 MB for a 38-point row. ImageIO scales down only, never up.
    private nonisolated static func decode(_ source: CGImageSource, index: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: largestPixelSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

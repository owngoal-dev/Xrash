import Foundation
import ObjectiveC.runtime
import UIKit

/// Ported from CocoaInspector, where the same question is asked of a running
/// process rather than of a report.
enum ApplicationBundleLocator {
    /// An executable path inside `Host.app/PlugIns/Extension.appex` belongs to
    /// the host app, so the first `.app` component is the answer for both the
    /// main executable and every plug-in.
    static func hostApplicationPath(for executablePath: String) -> String? {
        let path = (executablePath as NSString).standardizingPath
        guard path.range(of: "/Bundle/Application/", options: .caseInsensitive) != nil
            || path.range(of: "/Applications/", options: .caseInsensitive) != nil,
            let appBoundary = path.range(of: ".app/", options: .caseInsensitive)
        else {
            return nil
        }
        let trailingSlash = path.index(before: appBoundary.upperBound)
        return String(path[..<trailingSlash])
    }
}

/// App icons for report rows, by bundle id when the report carries one and by
/// executable path otherwise. Cached both ways — including the misses, so a
/// scroll over a hundred daemon reports asks IconServices once each.
actor ApplicationIconProvider {
    static let shared = ApplicationIconProvider()

    private static let listRowFormat: Int32 = 1
    /// No app has ever had this identifier, so whatever IconServices answers
    /// for it is the generic placeholder and nothing else.
    private static let unknownBundleIdentifier = "wiki.qaq.xrash.unknown-application"

    private var cache = [String: UIImage?]()
    private var pending = [String: Task<UIImage?, Never>]()
    private var placeholders = [CGFloat: Data?]()

    /// `bundleID` comes from the report header and wins: a crashed app may
    /// have been updated, moved or deleted since, and IconServices still knows
    /// it. The path is the fallback for reports with no header.
    func icon(bundleID: String?, executablePath: String?, scale: CGFloat) async -> UIImage? {
        let applicationPath = executablePath.flatMap(ApplicationBundleLocator.hostApplicationPath)
        guard bundleID != nil || applicationPath != nil else { return nil }

        let key = "\(bundleID ?? "")|\(applicationPath ?? "")|\(scale)"
        if let cached = cache[key] {
            return cached
        }
        if let pending = pending[key] {
            return await pending.value
        }

        let placeholder = placeholderFingerprint(scale: scale)
        let load = Task.detached(priority: .utility) {
            Self.loadIcon(
                bundleID: bundleID,
                applicationPath: applicationPath,
                scale: scale,
                rejecting: placeholder
            )
        }
        pending[key] = load
        let icon = await load.value
        pending[key] = nil
        cache[key] = icon
        return icon
    }

    /// IconServices answers an identifier it does not know with a grey grid
    /// rather than with nothing, and a list of those reads as broken. The grid
    /// is the same image every time, so it is fetched once per scale and
    /// anything equal to it is treated as a miss.
    private func placeholderFingerprint(scale: CGFloat) -> Data? {
        if let known = placeholders[scale] {
            return known
        }
        let data = Self.iconServicesImage(
            bundleIdentifier: Self.unknownBundleIdentifier,
            scale: scale
        )?.pngData()
        placeholders[scale] = data
        return data
    }

    private nonisolated static func loadIcon(
        bundleID: String?,
        applicationPath: String?,
        scale: CGFloat,
        rejecting placeholder: Data?
    ) -> UIImage? {
        autoreleasepool {
            if let bundleID, let icon = iconServicesImage(bundleIdentifier: bundleID, scale: scale),
               placeholder == nil || icon.pngData() != placeholder
            {
                return icon
            }
            guard let applicationPath, let bundle = Bundle(path: applicationPath) else { return nil }
            if let identifier = bundle.bundleIdentifier, identifier != bundleID,
               let icon = iconServicesImage(bundleIdentifier: identifier, scale: scale),
               placeholder == nil || icon.pngData() != placeholder
            {
                return icon
            }
            return bundledIcon(in: bundle)
        }
    }

    private typealias ApplicationIconImplementation = @convention(c) (
        AnyObject,
        Selector,
        NSString,
        Int32,
        CGFloat
    ) -> Unmanaged<UIImage>?

    private nonisolated static func iconServicesImage(
        bundleIdentifier: String,
        scale: CGFloat
    ) -> UIImage? {
        let selector = NSSelectorFromString(
            "_applicationIconImageForBundleIdentifier:format:scale:"
        )
        guard let method = class_getClassMethod(UIImage.self, selector) else { return nil }
        let implementation = unsafeBitCast(
            method_getImplementation(method),
            to: ApplicationIconImplementation.self
        )
        return implementation(
            UIImage.self,
            selector,
            bundleIdentifier as NSString,
            listRowFormat,
            scale
        )?.takeUnretainedValue()
    }

    /// IconServices is preferred because it understands compiled asset
    /// catalogs. Loose `CFBundleIconFiles` remain a useful fallback for older
    /// and hand-packaged custom firmware apps — of which this device has many.
    private nonisolated static func bundledIcon(in bundle: Bundle) -> UIImage? {
        let info = bundle.infoDictionary ?? [:]
        var names = info["CFBundleIconFiles"] as? [String] ?? []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let files = primary["CFBundleIconFiles"] as? [String] else { continue }
            names.append(contentsOf: files)
        }
        // Last first: the catalogue lists the smallest icon first.
        for name in names.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
        }
        return nil
    }
}

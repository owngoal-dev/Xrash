import Foundation

/// A short string two reports of the same bug share. Built from image-relative
/// offsets only, never absolute addresses, so ASLR does not change it.
enum CrashSignature {
    private static let systemPrefixes = ["/System/", "/usr/lib/", "/usr/libexec/", "/Developer/"]
    private static let interestingFrameCount = 5
    private static let fallbackFrameCount = 3
    /// Offsets are rounded to a page so a rebuild that moves a function a few
    /// bytes still groups with its earlier crashes.
    private static let offsetGranularity: UInt64 = 4096

    static func signature(of crash: CrashReport) -> String {
        let exception = crash.exception
        let stack = crash.lastExceptionBacktrace.isEmpty
            ? (crash.faultingThread?.frames ?? [])
            : crash.lastExceptionBacktrace

        var frames = stack.filter { !isSystem($0, images: crash.images) }.prefix(interestingFrameCount)
        if frames.isEmpty {
            frames = stack.prefix(fallbackFrameCount)
        }

        let parts = frames.map { describe($0, images: crash.images) }
        return ([exception?.type ?? "", exception?.signal ?? ""] + parts).joined(separator: "|")
    }

    private static func isSystem(_ frame: Frame, images: [BinaryImage]) -> Bool {
        guard let image = images.image(for: frame) else { return true }
        if image.source == "S" {
            return true
        }
        return systemPrefixes.contains { image.path.hasPrefix($0) }
    }

    private static func describe(_ frame: Frame, images: [BinaryImage]) -> String {
        let name = images.image(for: frame)?.name ?? "?"
        if let symbol = frame.symbol {
            return "\(name)+\(symbol)"
        }
        let page = frame.imageOffset - frame.imageOffset % offsetGranularity
        return name + String(format: "+0x%llx", page)
    }
}

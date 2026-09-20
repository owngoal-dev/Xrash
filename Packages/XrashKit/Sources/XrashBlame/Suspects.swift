import Foundation
import XrashReport

/// How an image came to be in the process, which is what decides whether it
/// may be blamed at all.
enum ImageOrigin {
    /// Apple's, by the report's own `source` column or by where it lives.
    case apple
    /// Inside the crashed app's own bundle — its frameworks are not suspects.
    case ownBundle
    /// The bootstrap injects these into every process on the device, so their
    /// presence in a crash says nothing on its own.
    case bootstrapHook
    /// A tweak, loaded out of an injection directory.
    case injectedTweak
    case thirdParty
}

/// Scores every non-Apple image against the crash and explains each score.
extension Blame {
    /// Checked before the Apple prefixes: on a rootful bootstrap tweaks live
    /// in `/usr/lib/TweakInject`, which would otherwise read as Apple's.
    private static let tweakDirectories = ["/MobileSubstrate/DynamicLibraries/", "/TweakInject/"]
    private static let applePrefixes = [
        "/System/", "/usr/lib/", "/usr/libexec/", "/private/preboot/Cryptexes/",
    ]
    /// ponytail: the injectors we have seen, by name. A bootstrap that names
    /// its hook something else is merely scored as an ordinary third party —
    /// noisier, never wrong — so this list grows only when one shows up.
    private static let bootstrapHooks: Set<String> = [
        "systemhook.dylib", "libsystemhook.dylib", "libellekit.dylib", "libsubstrate.dylib",
        "CydiaSubstrate", "libhooker.dylib", "libsubstitute.dylib", "TweakInject.dylib",
    ]
    /// A package unpacked this long before the crash is worth mentioning.
    private static let recentInstallWindow: TimeInterval = 72 * 60 * 60
    /// Frames this near the top of the faulting thread weigh more.
    private static let topFrameCount = 8

    /// Ranked suspects with their reasons — never a bare verdict. Empty when
    /// nothing but Apple's code and the app itself is involved.
    public static func suspects(in crash: CrashReport, packages: DpkgDatabase?) -> [Suspect] {
        let bundleDirectory = appBundleDirectory(of: crash.process.path)
        let faultingFrames = crash.faultingThread?.frames ?? []
        let onStack = Set(faultingFrames.compactMap(\.imageIndex))
        let nearTop = Set(faultingFrames.prefix(topFrameCount).compactMap(\.imageIndex))
        let inException = Set(crash.lastExceptionBacktrace.compactMap(\.imageIndex))
        // A sideloaded app's own frameworks sit beside it rather than inside
        // the bundle often enough that "third party" alone must not accuse them.
        let processIsThirdParty = !applePrefixes.contains { crash.process.path.hasPrefix($0) }

        var suspects = [Suspect]()
        for (index, image) in crash.images.enumerated() {
            let origin = origin(of: image, bundleDirectory: bundleDirectory)
            guard origin != .apple, origin != .ownBundle else { continue }

            var reasons = [Suspect.Reason]()
            var score = 0
            if onStack.contains(index) {
                reasons.append(.onFaultingStack)
                score += nearTop.contains(index) ? 70 : 50
            }
            if inException.contains(index) {
                reasons.append(.inExceptionBacktrace)
                score += 40
            }
            // Everything carries one of these, so the hook that is in every
            // process on the device would otherwise be in every verdict.
            guard origin != .bootstrapHook || !reasons.isEmpty else { continue }

            if origin == .injectedTweak {
                reasons.append(.injectedTweak)
                score += 30
            } else {
                reasons.append(.thirdPartyImage)
                score += 10
            }

            let owner = packages?.owner(ofPath: image.path)
            if let installed = owner?.installed, let captured = crash.device.captureDate,
               installed <= captured, captured.timeIntervalSince(installed) <= recentInstallWindow
            {
                reasons.append(.recentlyInstalled)
                score += 15
            }

            guard !processIsThirdParty || reasons != [.thirdPartyImage] else { continue }
            suspects.append(Suspect(
                id: image.path,
                imageName: image.name,
                reasons: reasons,
                owner: owner,
                score: score
            ))
        }
        return suspects.sorted {
            $0.score == $1.score ? $0.imageName < $1.imageName : $0.score > $1.score
        }
    }

    /// `/…/Fila.app/` for `/…/Fila.app/Frameworks/X.framework/X`.
    private static func appBundleDirectory(of executablePath: String) -> String? {
        if let app = executablePath.range(of: ".app/") {
            return String(executablePath[executablePath.startIndex ..< app.upperBound])
        }
        return executablePath.hasSuffix(".app") ? executablePath + "/" : nil
    }

    private static func origin(of image: BinaryImage, bundleDirectory: String?) -> ImageOrigin {
        if tweakDirectories.contains(where: { image.path.contains($0) }) {
            return .injectedTweak
        }
        if image.source == "S" || applePrefixes.contains(where: { image.path.hasPrefix($0) }) {
            return .apple
        }
        if let bundleDirectory, image.path.hasPrefix(bundleDirectory) {
            return .ownBundle
        }
        if image.path.hasPrefix("/cores/")
            || bootstrapHooks.contains((image.path as NSString).lastPathComponent)
        {
            return .bootstrapHook
        }
        return .thirdParty
    }
}

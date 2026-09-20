import Foundation
import UIKit

/// What this machine is, in the form a bundle manifest and a PDF cover want:
/// the model identifier reports themselves use, the OS with its build, and the
/// app's own version string. All three are read once and never change.
enum DeviceInfo {
    /// `iPhone14,2`. On the simulator `hw.machine` is the Mac's architecture,
    /// so the device it pretends to be is taken from the environment instead.
    static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        return sysctlString("hw.machine") ?? UIDevice.current.model
    }()

    /// `iOS 17.5 (21F79)` — the build is what system symbols are keyed on.
    static let osVersion: String = {
        let system = UIDevice.current.systemName
        let version = UIDevice.current.systemVersion
        guard !osBuild.isEmpty else { return "\(system) \(version)" }
        return "\(system) \(version) (\(osBuild))"
    }()

    /// `23G83`, the key `SystemSymbolStore` stores a set under.
    static let osBuild: String = sysctlString("kern.osversion") ?? ""

    /// `Xrash 0.1.0 (11)` — `BundleManifest.generator`.
    static let generator: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Xrash \(version) (\(build))"
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

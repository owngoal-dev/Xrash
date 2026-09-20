import Foundation

/// Reading `JSONSerialization` output without trusting it. A base address in a
/// panic log is larger than `Int64.max`, so every integer goes through
/// `NSNumber` rather than `as? Int`, and a missing or wrongly typed field is
/// nil instead of a trap.
enum JSONNumber {
    static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        switch String(cString: number.objCType) {
        case "f", "d":
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double < 18_446_744_073_709_551_616 else { return nil }
            return UInt64(double)
        case "c", "s", "i", "l", "q":
            // Signed on the way in: `-1` is a corrupt field, and `uint64Value`
            // would hand it back as an address one byte below the top of the
            // space. Only the unsigned box below may exceed `Int64.max`.
            guard let wide = Int64(exactly: number), wide >= 0 else { return nil }
            return UInt64(wide)
        default:
            return number.uint64Value
        }
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let wide = number.int64Value
        guard wide >= Int64(Int.min), wide <= Int64(Int.max) else { return nil }
        return Int(wide)
    }
}

extension [String: Any] {
    /// Empty strings are absent fields: `app_version` is `""` for a command
    /// line tool, and a row saying `Version: ` helps nobody.
    func string(_ key: String) -> String? {
        guard let text = self[key] as? String, !text.isEmpty else { return nil }
        return text
    }

    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [Any] {
        (self[key] as? [Any]) ?? []
    }

    func objects(_ key: String) -> [[String: Any]] {
        array(key).compactMap { $0 as? [String: Any] }
    }

    func strings(_ key: String) -> [String] {
        array(key).compactMap { $0 as? String }
    }

    func uint64(_ key: String) -> UInt64? {
        JSONNumber.uint64(self[key])
    }

    func int(_ key: String) -> Int? {
        JSONNumber.int(self[key])
    }

    func int32(_ key: String) -> Int32? {
        guard let value = int(key), let narrow = Int32(exactly: value) else { return nil }
        return narrow
    }

    func double(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }

    func bool(_ key: String) -> Bool {
        (self[key] as? NSNumber)?.boolValue ?? false
    }
}

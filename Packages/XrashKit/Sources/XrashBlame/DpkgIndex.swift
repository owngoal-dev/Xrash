import Foundation

/// dpkg's `info/<package>.list` files read into one path → package map.
///
/// Every lookup is a miss until the whole database is in memory — a report has
/// a hundred images and dpkg has a thousand lists — so it is read in a single
/// pass instead of seeking per query. A few megabytes of text on the devices
/// this runs on.
struct DpkgIndex {
    /// Every line of every `.list`, as dpkg spells it.
    let packageByPath: [String: String]
    /// Only the packages that have a `.list`, so only installed ones.
    let ownerByPackage: [String: PackageOwner]

    /// ponytail: a flat byte budget rather than a real memory watermark. A
    /// bootstrap large enough to hit it loses the tail of its index and blames
    /// nothing for those files; raise it or index on demand if that ever shows.
    private static let listBudget = 64 << 20
    private static let statusBudget = 32 << 20

    static func build(root: String) -> DpkgIndex? {
        let database = root + "/var/lib/dpkg"
        let info = database + "/info"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: info) else { return nil }

        var packageByPath = [String: String]()
        var installed = [String: Date]()
        var budget = listBudget
        for name in names where name.hasSuffix(".list") {
            let package = String(name.dropLast(".list".count))
            let path = info + "/" + name
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int, size <= budget,
                  let data = FileManager.default.contents(atPath: path) else { continue }
            budget -= data.count
            if let modified = attributes[.modificationDate] as? Date {
                installed[package] = modified
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let entry = line.hasSuffix("\r") ? line.dropLast() : line
                // `/.` is dpkg's name for the bootstrap root itself.
                guard entry.hasPrefix("/"), entry != "/.", entry.count > 1 else { continue }
                packageByPath[String(entry)] = package
            }
        }

        let described = describe(statusAt: database + "/status")
        var ownerByPackage = [String: PackageOwner]()
        for (package, date) in installed {
            var owner = PackageOwner(identifier: package)
            let description = described[package]
            owner.name = description?.name
            owner.version = description?.version
            owner.installed = date
            ownerByPackage[package] = owner
        }
        return DpkgIndex(packageByPath: packageByPath, ownerByPackage: ownerByPackage)
    }

    /// `status` is RFC-822 paragraphs. Only `Package`, `Name` and `Version`
    /// matter here; continuation lines start with a space and are skipped.
    private static func describe(statusAt path: String) -> [String: (name: String?, version: String?)] {
        guard let data = FileManager.default.contents(atPath: path), data.count <= statusBudget else { return [:] }

        var described = [String: (name: String?, version: String?)]()
        var package: String?
        var name: String?
        var version: String?
        func endParagraph() {
            if let package, !package.isEmpty {
                described[package] = (name, version)
            }
            package = nil
            name = nil
            version = nil
        }

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            let field = line.hasSuffix("\r") ? line.dropLast() : line
            if field.isEmpty {
                endParagraph()
                continue
            }
            guard !field.hasPrefix(" "), !field.hasPrefix("\t"), let colon = field.firstIndex(of: ":") else { continue }
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch field[..<colon] {
            case "Package": package = value
            case "Name": name = value
            case "Version": version = value
            default: break
            }
        }
        endParagraph()
        return described
    }
}

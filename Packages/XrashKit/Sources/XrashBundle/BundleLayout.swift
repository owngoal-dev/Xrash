import Foundation

/// Where everything sits inside an `.xrashreport`:
///
/// ```
/// Report.plist                              the manifest — XML, so it reads by hand
/// Report.pdf                                the rendered report, when one was made
/// reports/<memberID>/<original file name>   the member's file, byte for byte
/// reports/<memberID>/report.crash           the same report as text
/// reports/<memberID>/report.json            the decoded model as JSON
/// binaries/<UUID>/<name>                    a binary kept for later symbolication
/// dsyms/<UUID>.dwarf                        its DWARF, when one was found
/// ```
///
/// Spelled once here so that no caller builds these strings itself and no two
/// callers disagree about them.
public enum BundleLayout {
    public static let manifest = BundleManifest.fileName
    public static let pdf = "Report.pdf"

    /// The member's file exactly as it was on the device, name included: the
    /// name is evidence too (`Fila-2026-09-08-191717.ips.synced`).
    public static func rawReport(member: String, fileName: String) -> String {
        "reports/\(member)/\(fileName)"
    }

    public static func crashText(member: String) -> String {
        "reports/\(member)/report.crash"
    }

    public static func reportJSON(member: String) -> String {
        "reports/\(member)/report.json"
    }

    public static func binary(uuid: String, name: String) -> String {
        "binaries/\(uuid)/\(name)"
    }

    public static func dsym(uuid: String) -> String {
        "dsyms/\(uuid).dwarf"
    }

    /// The one form of an archive name that may be joined onto a directory.
    ///
    /// Checked by walking components, never by normalising the string: folding
    /// `a/../../b` the way the kernel would turns an escape into a legal-looking
    /// relative path.
    static func validated(_ declared: String) -> String? {
        guard !declared.isEmpty, !declared.hasPrefix("/"), !declared.utf8.contains(0) else { return nil }
        var components = [String]()
        for component in declared.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": return nil
            default: components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}

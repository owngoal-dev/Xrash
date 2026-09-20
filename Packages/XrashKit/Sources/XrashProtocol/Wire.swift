import Foundation

/// The closed set of things `xrashd` does. There is no generic operation: no
/// path-and-flags open, no exec, nothing that takes an argv.
public enum XrashOperation: UInt64, Sendable {
    case hello = 1
    /// Lists the fixed report roots. Takes nothing; replies `[ReportEntry]`.
    case listReports = 2
    /// `path` inside a report root → a read-only descriptor in `descriptor`.
    case openReport = 3
    /// `payload` = `[String]` of paths inside the report roots → `[String]` of
    /// the paths that could not be removed.
    case deleteReports = 4
    /// `path` of a Mach-O or a dyld shared cache file → a read-only descriptor.
    case openImage = 5
    case goodbye = 6
}

public enum XrashReplyCode: Int64, Sendable {
    case success = 0
    case invalidRequest = 1
    /// The path resolved outside what the operation is allowed to touch.
    case refused = 2
    case notFound = 3
    case operationFailed = 4
}

public enum XrashWireKey {
    public static let version = "v"
    public static let operation = "op"
    public static let code = "code"
    public static let payload = "payload"
    public static let path = "path"
    public static let descriptor = "fd"
    /// `errno` of the failing call, when there was one.
    public static let errorNumber = "errno"
}

public enum XrashWire {
    public static let version: UInt64 = 1
    public static let maximumPayloadByteCount = 16 * 1024 * 1024

    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try PropertyListDecoder().decode(type, from: data)
    }
}

/// What `hello` answers. The install root is the only place the app learns the
/// bootstrap prefix from; its presence is what "privileged" means.
public struct HelloReply: Codable, Equatable, Sendable {
    /// Whatever precedes `/usr/libexec/xrashd` in the daemon's own canonical
    /// path: the randomized bootstrap on roothide, `/private/var/jb`'s target
    /// on rootless.
    public var installRoot: String

    public init(installRoot: String) {
        self.installRoot = installRoot
    }
}

/// One file under a report root. Nothing here is parsed from the file.
public struct ReportEntry: Codable, Hashable, Sendable {
    /// Canonical absolute path; the identity of the report everywhere.
    public var path: String
    public var byteCount: UInt64
    public var modified: Date
    public var ownerUserID: UInt32

    public init(path: String, byteCount: UInt64, modified: Date, ownerUserID: UInt32) {
        self.path = path
        self.byteCount = byteCount
        self.modified = modified
        self.ownerUserID = ownerUserID
    }
}

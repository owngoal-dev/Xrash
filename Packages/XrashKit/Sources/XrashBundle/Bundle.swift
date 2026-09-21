import Foundation
import XrashReport

/// `Report.plist` at the root of an `.xrashreport` archive. Everything needed
/// to show the bundle again after import, without re-parsing its members.
public struct BundleManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileName = "Report.plist"

    public enum Relation: String, Codable, Sendable {
        /// Same incident or coalition as the primary.
        case sameIncident
        /// Died within moments of the primary.
        case sameTime
        /// Named by the primary's termination, or names it.
        case terminator
        /// Parent or child of the primary's process.
        case relatedProcess
        /// Shares a suspect image with the primary.
        case sharedSuspect
        /// Added by hand.
        case manual
    }

    public struct Member: Codable, Hashable, Sendable, Identifiable {
        /// A UUID minted when the bundle is made.
        public var id: String
        public var summary: ReportSummary
        /// Nil for the primary.
        public var relation: Relation?
        /// The decoded — and, when it was done, symbolicated — report.
        public var report: Report
        /// Archive-relative paths of this member's files, by role.
        public var rawPath: String?
        public var textPath: String?
        public var jsonPath: String?

        public init(id: String, summary: ReportSummary, relation: Relation?, report: Report) {
            self.id = id
            self.summary = summary
            self.relation = relation
            self.report = report
        }
    }

    public struct IncludedBinary: Codable, Hashable, Sendable {
        public var uuid: String
        public var originalPath: String
        public var archivePath: String
        public var byteCount: UInt64

        public init(uuid: String, originalPath: String, archivePath: String, byteCount: UInt64) {
            self.uuid = uuid
            self.originalPath = originalPath
            self.archivePath = archivePath
            self.byteCount = byteCount
        }
    }

    /// One file of collected system state: services, registered apps,
    /// installed packages, tweaks, processes, jetsam configuration.
    public struct SystemFile: Codable, Hashable, Sendable {
        /// `launchd-services.json`.
        public var name: String
        public var archivePath: String
        public var byteCount: UInt64

        public init(name: String, archivePath: String, byteCount: UInt64) {
            self.name = name
            self.archivePath = archivePath
            self.byteCount = byteCount
        }
    }

    public var schemaVersion = BundleManifest.currentSchemaVersion
    public var id: String
    public var created: Date
    public var title: String
    public var notes: String
    /// `Xrash 0.1.0 (12)`.
    public var generator: String
    public var deviceModel: String?
    public var osVersion: String?
    public var primary: Member
    public var linked: [Member]
    public var binaries: [IncludedBinary]
    public var pdfPath: String?
    /// Nil in a bundle made without system state, and in every bundle made
    /// before it existed; optional so both still decode. A bundle that has
    /// any names what is installed and running, and sharing it says so first.
    public var systemFiles: [SystemFile]?

    public init(id: String, created: Date, title: String, notes: String, generator: String, primary: Member) {
        self.id = id
        self.created = created
        self.title = title
        self.notes = notes
        self.generator = generator
        self.primary = primary
        linked = []
        binaries = []
    }
}

/// What goes into the archive besides the manifest.
public struct BundleOptions: Codable, Hashable, Sendable {
    public var includesRawReports = true
    public var includesCrashText = true
    public var includesJSON = true
    public var includesPDF = true
    /// Off by default: binaries are large and may not be the user's to share.
    public var includesBinaries = false
    /// Off by default: it names everything installed and running on the
    /// machine, which is the person's business and not a default.
    public var includesSystemState = false

    public init() {}
}

/// A file the caller already has on disk, to be stored at `archivePath`.
public struct BundleFile: Hashable, Sendable {
    public var source: URL
    public var archivePath: String

    public init(source: URL, archivePath: String) {
        self.source = source
        self.archivePath = archivePath
    }
}

public enum BundleArchiveError: Error, Equatable, Sendable {
    case cannotWrite(String)
    case cannotRead(String)
    case missingManifest
    case unsupportedSchema(Int)
    /// An entry tried to leave the extraction directory.
    case unsafeEntryPath(String)
}

/// `.xrashreport` is a zip written and read with libarchive.
public enum BundleArchive {
    /// Writes `Report.plist` plus `files`. `progress` is 0…1.
    public static func write(
        _ manifest: BundleManifest,
        files: [BundleFile],
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        try ZipWriter.write(manifest, files: files, to: destination, progress: progress)
    }

    /// Extracts into `directory` and returns the manifest.
    public static func read(_ archive: URL, extractingInto directory: URL) throws -> BundleManifest {
        try ZipReader.extract(archive, into: directory)
        return try ZipReader.manifest(in: directory)
    }

    /// Unpacks any zip — used for zipped dSYMs. Same path containment rules.
    public static func extractZip(_ archive: URL, into directory: URL) throws {
        try ZipReader.extract(archive, into: directory)
    }
}

public struct LinkSuggestion: Hashable, Sendable, Identifiable {
    public var id: String {
        summary.id
    }

    public var summary: ReportSummary
    public var relation: BundleManifest.Relation
    /// Higher first.
    public var score: Int

    public init(summary: ReportSummary, relation: BundleManifest.Relation, score: Int) {
        self.summary = summary
        self.relation = relation
        self.score = score
    }
}

public enum CrashCorrelation {}

import Foundation

// The report model. Everything is a value, Codable (bundles and caches embed
// it in plists) and free of UIKit. Symbolication returns a new `CrashReport`
// with the frames filled in; nothing here is mutated in place by a viewer.

// MARK: Classification

/// What a file under a report root is, decided from its header's `bug_type`
/// and, failing that, its name.
public enum ReportKind: String, Codable, Sendable {
    /// 309 (and 109, 385 …): a process died. The only kind with threads.
    case crash
    /// 298: JetsamEvent — memory pressure kills.
    case jetsam
    /// 210, 110: kernel panic.
    case panic
    /// 228, 288 …: hangs, spins, stackshots.
    case hang
    /// 202, 206 …: cpu / wakeups / disk-write resource reports.
    case resource
    /// 211, 313 and the other Analytics/feedback payloads.
    case analytics
    /// Plain logs and everything undecodable.
    case other
}

/// The sections of the report list.
public enum ReportGroup: String, Codable, Sendable, CaseIterable {
    /// A crash, hang or resource report whose executable sits inside an `.app`.
    case app
    /// The same kinds for daemons, XPC services and command-line tools.
    case service
    case jetsam
    case other
}

/// The first JSON object of an `.ips`. `bug_type` is a string on disk.
public struct ReportHeader: Codable, Hashable, Sendable {
    public var bugType: String
    public var name: String?
    public var appName: String?
    public var appVersion: String?
    public var buildVersion: String?
    public var bundleID: String?
    public var incidentID: String?
    public var osVersion: String?
    public var timestamp: Date?
    public var sliceUUID: String?
    public var isFirstParty: Bool?

    public init(bugType: String) {
        self.bugType = bugType
    }
}

/// What a list row needs. Built from the file name alone at first, then
/// enriched once the header line has been read.
public struct ReportSummary: Codable, Hashable, Sendable, Identifiable {
    /// Canonical path — `ReportEntry.path`.
    public var id: String
    public var fileName: String
    /// `Fila` for `Fila-2026-09-08-191717.ips.synced`.
    public var processName: String
    public var kind: ReportKind
    public var group: ReportGroup
    public var date: Date
    public var byteCount: UInt64
    public var bundleID: String?
    public var appVersion: String?
    public var osVersion: String?
    public var incidentID: String?
    /// The system already uploaded it (`.synced` suffix).
    public var isSynced: Bool

    public init(
        id: String,
        fileName: String,
        processName: String,
        kind: ReportKind,
        group: ReportGroup,
        date: Date,
        byteCount: UInt64,
        isSynced: Bool
    ) {
        self.id = id
        self.fileName = fileName
        self.processName = processName
        self.kind = kind
        self.group = group
        self.date = date
        self.byteCount = byteCount
        self.isSynced = isSynced
    }
}

// MARK: A decoded report

public struct Report: Codable, Hashable, Sendable {
    public var header: ReportHeader
    public var kind: ReportKind
    /// Present for `.crash`, and for hang/resource reports that carry threads.
    public var crash: CrashReport?
    public var jetsam: JetsamReport?
    public var panic: PanicReport?
    /// The file as text, untouched — what the JSON viewer shows.
    public var rawText: String

    public init(header: ReportHeader, kind: ReportKind, rawText: String) {
        self.header = header
        self.kind = kind
        self.rawText = rawText
    }
}

public struct CrashReport: Codable, Hashable, Sendable {
    public var process = ProcessDetails()
    public var device = DeviceDetails()
    public var exception: ExceptionDetails?
    public var termination: TerminationDetails?
    /// `asi`, flattened to `"libsystem_c.dylib: abort() called"` lines.
    public var applicationInfo = [String]()
    public var faultingThreadIndex: Int?
    public var threads = [ReportThread]()
    public var lastExceptionBacktrace = [Frame]()
    public var images = [BinaryImage]()
    public var sharedCache: SharedCacheDetails?
    public var vmSummary: String?

    public init() {}

    public var faultingThread: ReportThread? {
        faultingThreadIndex.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
    }
}

public struct ProcessDetails: Codable, Hashable, Sendable {
    public var name = ""
    public var path = ""
    public var pid: Int32?
    public var bundleID: String?
    public var version: String?
    public var build: String?
    public var parentName: String?
    public var parentPID: Int32?
    public var responsibleName: String?
    public var coalitionName: String?
    public var userID: UInt32?
    public var role: String?
    public var launchDate: Date?
    public var codeSigningID: String?
    public var teamID: String?
    public var cpuType: String?

    public init() {}
}

public struct DeviceDetails: Codable, Hashable, Sendable {
    public var model: String?
    /// `iPhone OS 26.6.1`.
    public var osTrain: String?
    /// `23G83` — the key system symbols are stored under.
    public var osBuild: String?
    public var captureDate: Date?
    public var uptime: TimeInterval?
    public var incidentID: String?
    public var crashReporterKey: String?
    public var bootSessionUUID: String?

    public init() {}
}

public struct ExceptionDetails: Codable, Hashable, Sendable {
    /// `EXC_CRASH`.
    public var type: String
    /// `SIGABRT`.
    public var signal: String?
    /// `KERN_INVALID_ADDRESS at 0x…`.
    public var subtype: String?
    public var codes: String?
    public var message: String?

    public init(type: String) {
        self.type = type
    }

    /// `EXC_CRASH (SIGABRT)` — the one spelling every renderer prints.
    public var typeAndSignal: String {
        signal.map { "\(type) (\($0))" } ?? type
    }
}

public struct TerminationDetails: Codable, Hashable, Sendable {
    /// `SIGNAL`, `SPRINGBOARD`, `CODESIGNING`, `DYLD` …
    public var namespace: String?
    public var code: UInt64?
    public var indicator: String?
    public var byProcess: String?
    public var byPID: Int32?
    public var reasons = [String]()

    public init() {}
}

public struct ReportThread: Codable, Hashable, Sendable {
    public var index: Int
    public var id: UInt64?
    public var name: String?
    public var queue: String?
    public var isTriggered = false
    public var frames = [Frame]()
    /// In display order: `x0…x28`, `fp`, `lr`, `sp`, `pc`, `cpsr`, `far`, `esr`.
    public var registers = [Register]()

    public init(index: Int) {
        self.index = index
    }
}

public struct Register: Codable, Hashable, Sendable {
    public var name: String
    public var value: UInt64

    public init(name: String, value: UInt64) {
        self.name = name
        self.value = value
    }
}

/// Where a frame's name came from, best first.
public enum SymbolSource: String, Codable, Sendable {
    case dsym, binary, systemSymbols, sharedCache
    /// The `symbol` field Apple wrote into the report.
    case report
}

public struct Frame: Codable, Hashable, Sendable {
    /// Index into `CrashReport.images`; nil when the report names none.
    public var imageIndex: Int?
    public var imageOffset: UInt64
    /// `images[imageIndex].base + imageOffset`, computed at decode time.
    public var address: UInt64
    /// Demangled when a symbolicator produced it.
    public var symbol: String?
    /// Bytes past the start of `symbol`.
    public var symbolLocation: UInt64?
    public var sourceFile: String?
    public var sourceLine: Int?
    public var symbolSource: SymbolSource?
    /// True for frames the symbolicator expanded out of an inlined call.
    public var isInlined = false

    public init(imageIndex: Int?, imageOffset: UInt64, address: UInt64) {
        self.imageIndex = imageIndex
        self.imageOffset = imageOffset
        self.address = address
    }
}

public struct BinaryImage: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    /// Uppercase, dashed.
    public var uuid: String
    public var arch: String?
    public var base: UInt64
    public var size: UInt64
    /// `P` process, `S` shared cache, `A` absolute — as the report says.
    public var source: String?

    public init(name: String, path: String, uuid: String, base: UInt64, size: UInt64) {
        self.name = name
        self.path = path
        self.uuid = uuid
        self.base = base
        self.size = size
    }
}

public struct SharedCacheDetails: Codable, Hashable, Sendable {
    public var uuid: String
    public var base: UInt64
    public var size: UInt64

    public init(uuid: String, base: UInt64, size: UInt64) {
        self.uuid = uuid
        self.base = base
        self.size = size
    }
}

// MARK: The other kinds

public struct JetsamReport: Codable, Hashable, Sendable {
    public var pageSize: UInt64
    public var largestProcess: String?
    public var processes = [JetsamProcess]()

    public init(pageSize: UInt64) {
        self.pageSize = pageSize
    }
}

public struct JetsamProcess: Codable, Hashable, Sendable {
    public var name: String
    public var pid: Int32?
    public var residentPages: UInt64
    /// Set on the processes that were killed: `per-process-limit`, `vm-pageshortage` …
    public var reason: String?
    public var states = [String]()

    public init(name: String, residentPages: UInt64) {
        self.name = name
        self.residentPages = residentPages
    }
}

public struct PanicReport: Codable, Hashable, Sendable {
    public var panicString: String
    public var product: String?
    public var build: String?

    public init(panicString: String) {
        self.panicString = panicString
    }
}

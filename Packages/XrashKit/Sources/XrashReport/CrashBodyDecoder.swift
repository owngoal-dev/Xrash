import Foundation

/// The body of a 309 — and of the hang and resource reports that share its
/// shape. Key names are the ones the device writes, verified against reports
/// pulled off a vphone.
enum CrashBodyDecoder {
    static func decode(_ body: [String: Any]) -> CrashReport {
        var crash = CrashReport()
        crash.process = process(from: body)
        crash.device = device(from: body)
        crash.exception = exception(from: body)
        crash.termination = termination(from: body)
        crash.applicationInfo = applicationInfo(from: body)
        crash.images = images(from: body)
        crash.threads = threads(from: body, images: crash.images)
        crash.lastExceptionBacktrace = frames(body.objects("lastExceptionBacktrace"), images: crash.images)
        crash.faultingThreadIndex = faultingThreadIndex(from: body, threads: crash.threads)
        crash.sharedCache = sharedCache(from: body)
        crash.vmSummary = body.string("vmSummary")
        return crash
    }

    // MARK: Header-ish detail

    private static func process(from body: [String: Any]) -> ProcessDetails {
        var process = ProcessDetails()
        process.name = body.string("procName") ?? ""
        process.path = body.string("procPath") ?? ""
        process.pid = body.int32("pid")
        process.userID = body.uint64("userID").map { UInt32(truncatingIfNeeded: $0) }
        process.role = body.string("procRole")
        process.parentName = body.string("parentProc")
        process.parentPID = body.int32("parentPid")
        process.responsibleName = body.string("responsibleProc")
        process.coalitionName = body.string("coalitionName")
        process.launchDate = ReportDates.date(from: body.string("procLaunch"))
        process.codeSigningID = body.string("codeSigningID")
        process.teamID = body.string("codeSigningTeamID")
        process.cpuType = body.string("cpuType")
        if let bundle = body.object("bundleInfo") {
            process.bundleID = bundle.string("CFBundleIdentifier")
            process.version = bundle.string("CFBundleShortVersionString")
            process.build = bundle.string("CFBundleVersion")
        }
        return process
    }

    private static func device(from body: [String: Any]) -> DeviceDetails {
        var device = DeviceDetails()
        device.model = body.string("modelCode")
        if let os = body.object("osVersion") {
            device.osTrain = os.string("train")
            device.osBuild = os.string("build")
        }
        device.captureDate = ReportDates.date(from: body.string("captureTime"))
        device.uptime = body.double("uptime")
        device.incidentID = body.string("incident")
        device.crashReporterKey = body.string("crashReporterKey")
        device.bootSessionUUID = body.string("bootSessionUUID")
        return device
    }

    private static func exception(from body: [String: Any]) -> ExceptionDetails? {
        guard let raw = body.object("exception") else { return nil }
        var exception = ExceptionDetails(type: raw.string("type") ?? "")
        exception.signal = raw.string("signal")
        exception.subtype = raw.string("subtype")
        exception.codes = raw.string("codes")
        exception.message = raw.string("message")
        return exception
    }

    private static func sharedCache(from body: [String: Any]) -> SharedCacheDetails? {
        guard let cache = body.object("sharedCache") else { return nil }
        return SharedCacheDetails(
            uuid: cache.string("uuid")?.uppercased() ?? "",
            base: cache.uint64("base") ?? 0,
            size: cache.uint64("size") ?? 0,
        )
    }

    private static func termination(from body: [String: Any]) -> TerminationDetails? {
        guard let raw = body.object("termination") else { return nil }
        var termination = TerminationDetails()
        termination.namespace = raw.string("namespace")
        termination.code = raw.uint64("code")
        termination.indicator = raw.string("indicator")
        termination.byProcess = raw.string("byProc")
        termination.byPID = raw.int32("byPid")
        // A DYLD failure writes the libraries it could not load into `reasons`
        // and its footnote ("terminated at launch; ignore backtrace") into
        // `details`. Both print as Termination Description, details last.
        termination.reasons = raw.strings("reasons") + raw.strings("details")
        return termination
    }

    /// `asi` is `{"libsystem_c.dylib": ["abort() called"]}`. Sorted by library
    /// so the same crash renders the same way twice.
    private static func applicationInfo(from body: [String: Any]) -> [String] {
        guard let asi = body.object("asi") else { return [] }
        return asi.keys.sorted().flatMap { library in
            asi.strings(library).map { "\(library): \($0)" }
        }
    }

    // MARK: Threads and images

    private static func images(from body: [String: Any]) -> [BinaryImage] {
        body.objects("usedImages").map { entry in
            let path = entry.string("path") ?? ""
            var image = BinaryImage(
                name: entry.string("name") ?? path.split(separator: "/").last.map(String.init) ?? "",
                path: path,
                uuid: entry.string("uuid")?.uppercased() ?? "",
                base: entry.uint64("base") ?? 0,
                size: entry.uint64("size") ?? 0,
            )
            image.arch = entry.string("arch")
            image.source = entry.string("source")
            return image
        }
    }

    private static func threads(from body: [String: Any], images: [BinaryImage]) -> [ReportThread] {
        body.objects("threads").enumerated().map { index, entry in
            var thread = ReportThread(index: index)
            thread.id = entry.uint64("id")
            thread.name = entry.string("name")
            thread.queue = entry.string("queue")
            thread.isTriggered = entry.bool("triggered")
            thread.frames = frames(entry.objects("frames"), images: images)
            if let state = entry.object("threadState") {
                thread.registers = registers(from: state)
            }
            return thread
        }
    }

    private static func frames(_ entries: [[String: Any]], images: [BinaryImage]) -> [Frame] {
        entries.map { entry in
            let offset = entry.uint64("imageOffset") ?? 0
            let index = entry.int("imageIndex").flatMap { images.indices.contains($0) ? $0 : nil }
            let base = index.map { images[$0].base } ?? 0
            var frame = Frame(imageIndex: index, imageOffset: offset, address: base &+ offset)
            if let symbol = entry.string("symbol") {
                frame.symbol = symbol
                frame.symbolLocation = entry.uint64("symbolLocation")
                frame.symbolSource = .report
            }
            frame.sourceFile = entry.string("sourceFile")
            frame.sourceLine = entry.int("sourceLine")
            return frame
        }
    }

    /// In the order the classic report prints them, not the order JSON
    /// happened to serialise them in.
    private static let trailingRegisters = ["fp", "lr", "sp", "pc", "cpsr", "far", "esr"]

    private static func registers(from state: [String: Any]) -> [Register] {
        var registers = state.array("x").enumerated().compactMap { index, entry -> Register? in
            guard let value = (entry as? [String: Any])?.uint64("value") else { return nil }
            return Register(name: "x\(index)", value: value)
        }
        for name in trailingRegisters {
            guard let value = state.object(name)?.uint64("value") else { continue }
            registers.append(Register(name: name, value: value))
        }
        return registers
    }

    private static func faultingThreadIndex(from body: [String: Any], threads: [ReportThread]) -> Int? {
        if let index = body.int("faultingThread"), threads.indices.contains(index) {
            return index
        }
        return threads.firstIndex { $0.isTriggered }
    }
}

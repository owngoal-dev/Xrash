import Dispatch
import Foundation
import XrashProtocol

// The daemon's own child, reading one report with no privileges left.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == NoticeDescriber.argument {
    NoticeDescriber.runChild(fileName: CommandLine.arguments[2])
}

let server = DaemonServer()
guard server.start() else {
    NSLog("xrashd: could not listen on %@", XrashService.machServiceName)
    exit(EXIT_FAILURE)
}

dispatchMain()

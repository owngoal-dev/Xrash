import Dispatch
import Foundation
import XrashProtocol

let server = DaemonServer()
guard server.start() else {
    NSLog("xrashd: could not listen on %@", XrashService.machServiceName)
    exit(EXIT_FAILURE)
}

dispatchMain()

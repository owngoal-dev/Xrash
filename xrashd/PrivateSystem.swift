import Darwin
import XPC
import XrashProtocol

// Declared here rather than imported: none of these is in the public iOS SDK
// headers, and all of them are in libSystem on every iOS this daemon runs on.

@_silgen_name("proc_pidpath")
func xrashProcPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("xpc_connection_get_audit_token")
func xrashXPCConnectionGetAuditToken(
    _ connection: xpc_connection_t,
    _ token: UnsafeMutablePointer<audit_token_t>
)

@_silgen_name("xpc_copy_entitlement_for_token")
func xrashXPCCopyEntitlement(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<audit_token_t>
) -> xpc_object_t?

@_silgen_name("xpc_connection_create_mach_service")
func xrashCreateMachServiceListener(
    _ name: UnsafePointer<CChar>,
    _ targetQueue: DispatchQueue?,
    _ flags: UInt64
) -> xpc_connection_t?

enum PrivateSystemConstant {
    /// `XPC_CONNECTION_MACH_SERVICE_LISTENER`.
    static let machServiceListener: UInt64 = 1
}

/// The canonical path of the executable behind `pid`.
func processPath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBytes {
        xrashProcPIDPath(pid, $0.baseAddress!, UInt32($0.count))
    }
    return length > 0 ? PathGuard.canonical(String(cString: buffer)) : nil
}

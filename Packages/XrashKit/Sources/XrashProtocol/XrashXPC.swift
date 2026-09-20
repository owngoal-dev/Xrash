#if canImport(XPC)
    import CXrashXPC
    import XPC

    /// The XPC constants, read through C rather than through Swift's XPC overlay.
    ///
    /// Naming the SDK's XPC type, array-append or connection-error macros in Swift
    /// links `/usr/lib/swift/libswiftXPC.dylib` as a required library, and iOS 15
    /// does not have it: dyld terminates the process before `main` with "Library
    /// not loaded". Through the C shim they are the libSystem globals they have
    /// always been, the overlay stays weakly linked and unused, and the same binary
    /// runs on iOS 15 and on iOS 26 — one path on every OS, so the version you test
    /// on is the version that runs everywhere.
    ///
    /// Both the app and `xrashd` link XrashProtocol; `make check` fails on any
    /// Swift file that spells the macros directly.
    public enum XrashXPC {
        public static var typeBool: xpc_type_t {
            app_xpc_type_bool()
        }

        public static var typeConnection: xpc_type_t {
            app_xpc_type_connection()
        }

        public static var typeDictionary: xpc_type_t {
            app_xpc_type_dictionary()
        }

        public static var typeError: xpc_type_t {
            app_xpc_type_error()
        }
    }
#endif

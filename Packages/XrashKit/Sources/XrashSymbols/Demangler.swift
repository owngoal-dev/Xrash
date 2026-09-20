import Foundation

/// Mangled names in readable form.
///
/// Both demanglers are already in the process — `swift_demangle` in the Swift
/// runtime, `__cxa_demangle` in libc++abi — so they are looked up rather than
/// linked: an iOS 15 device has the Swift runtime in the shared cache, and
/// declaring the symbols would make this module link a library instead of
/// asking for one.
public enum Demangler {
    /// Swift and C++ names in readable form; anything else unchanged.
    public static func demangle(_ symbol: String) -> String {
        // `__cxa_demangle` recurses once per type constructor, and a name out
        // of an imported dSYM is as long as its string table allows: twenty
        // kilobytes of `P` overflows a 1 MB stack. No real name is near this.
        guard !symbol.isEmpty, symbol.utf8.count <= 8192 else { return symbol }

        if swiftPrefixes.contains(where: symbol.hasPrefix), let swift = swiftDemangle {
            let demangled = symbol.withCString { name in
                swift(name, strlen(name), nil, nil, 0)
            }
            if let demangled {
                defer { free(demangled) }
                return String(cString: demangled)
            }
        }

        if symbol.hasPrefix("_Z") || symbol.hasPrefix("__Z"), let cxx = cxxDemangle {
            // A C++ symbol in a Mach-O carries the linker's leading underscore
            // as well as its own; the demangler wants the name without it.
            let mangled = symbol.hasPrefix("__Z") ? String(symbol.dropFirst()) : symbol
            var status: Int32 = 0
            let demangled = mangled.withCString { name in
                cxx(name, nil, nil, &status)
            }
            if let demangled {
                defer { free(demangled) }
                if status == 0 {
                    return String(cString: demangled)
                }
            }
        }

        // A plain C symbol: `_main` is `main` everywhere but the symbol table.
        // `__mh_execute_header` keeps both, which the second character decides.
        if symbol.hasPrefix("_"), symbol.count > 1, !symbol.hasPrefix("__") {
            return String(symbol.dropFirst())
        }
        return symbol
    }

    private static let swiftPrefixes = ["$s", "_$s", "$S", "_$S", "_T0"]

    private typealias SwiftDemangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private typealias CXXDemangle = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?,
        UnsafeMutablePointer<Int32>?
    ) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: SwiftDemangle? = load("swift_demangle")
    private static let cxxDemangle: CXXDemangle? = load("__cxa_demangle")

    private static func load<T>(_ name: String) -> T? {
        guard let handle = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(handle, to: T.self)
    }
}

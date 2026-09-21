import Darwin
import Foundation
import LibArchive

/// The bits both ends of the zip need: libarchive's status convention, and the
/// locale it insists on converting names through.
enum Zip {
    /// Big enough that a 200 MB binary is a few thousand reads, small enough
    /// that nothing here holds a whole file in memory.
    static let chunkByteCount = 64 * 1024

    /// libarchive converts entry names through the native locale even when it
    /// is handed UTF-8. An app that never called `setlocale` runs in "C", where
    /// a Japanese process name becomes a damaged entry. Scoped to the call so
    /// no other thread's locale moves.
    static func withUTF8Locale<T>(_ body: () throws -> T) rethrows -> T {
        guard let locale = newlocale(LC_CTYPE_MASK, "UTF-8", nil) else { return try body() }
        let previous = uselocale(locale)
        defer {
            uselocale(previous)
            freelocale(locale)
        }
        return try body()
    }

    /// `ARCHIVE_WARN` means the call did what was asked and had a remark about
    /// it; anything else is a failure.
    private static func succeeded(_ status: Int32) -> Bool {
        status == ARCHIVE_OK || status == ARCHIVE_WARN
    }

    static func checkWrite(_ status: Int32) throws {
        guard succeeded(status) else { throw BundleArchiveError.cannotWrite }
    }

    static func checkRead(_ status: Int32) throws {
        guard succeeded(status) else { throw BundleArchiveError.cannotRead }
    }

    /// Seconds since 1970, clamped rather than trapped: `time_t(someDouble)`
    /// traps on a value outside `time_t`, and these come off a filesystem that
    /// root has been editing.
    static func unixTime(_ date: Date) -> time_t {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        if seconds >= Double(time_t.max) {
            return .max
        }
        if seconds <= Double(time_t.min) {
            return .min
        }
        return time_t(seconds)
    }
}

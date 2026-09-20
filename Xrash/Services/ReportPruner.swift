import Combine
import Foundation
import UIKit
import XrashReport

/// Auto-delete. Runs after a refresh, deletes by age and nothing else — read
/// or unread, synced or not. The Settings footer says exactly that, because a
/// cleanup with a hidden exception is a cleanup nobody can predict.
@MainActor
enum ReportPruner {
    /// Returns the ids it removed. `days` of zero keeps everything. A long
    /// sweep shows the progress card and can be cancelled.
    @discardableResult
    static func prune(
        _ library: ReportLibrary,
        olderThan days: Int,
        from presenter: UIViewController
    ) async -> [String] {
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let expired = library.summaries.value.filter { $0.date < cutoff }.map(\.id)
        guard !expired.isEmpty else { return [] }
        guard let removed = await ReportDeletion.delete(expired, from: presenter, library: library) else {
            return []
        }
        let failed = Set(removed)
        return expired.filter { !failed.contains($0) }
    }
}

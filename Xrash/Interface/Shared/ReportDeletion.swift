import UIKit

/// Deleting a pile of reports, with a progress card in front of it.
///
/// The backend takes the whole list in one call, which says nothing until it
/// is finished; deleting in batches is what makes a fraction and a Cancel
/// honest. Sixty-six reports on the test device is one batch and no card —
/// `ProgressCard` only appears once the work has taken a moment.
@MainActor
enum ReportDeletion {
    private static let batchSize = 20

    /// The ids that could not be removed, or nil when the user cancelled.
    static func delete(
        _ ids: [String],
        from presenter: UIViewController,
        library: ReportLibrary,
    ) async -> [String]? {
        guard ids.count > 1 else { return await library.delete(ids) }
        do {
            return try await ProgressCard.run(from: presenter, title: String(localized: "Deleting Reports")) { report in
                var failed = [String]()
                var done = 0
                for start in stride(from: 0, to: ids.count, by: batchSize) {
                    try Task.checkCancellation()
                    let batch = Array(ids[start ..< min(start + batchSize, ids.count)])
                    failed += await library.delete(batch)
                    done += batch.count
                    report(Double(done) / Double(ids.count), String(localized: "\(done) of \(ids.count)"))
                }
                return failed
            }
        } catch {
            return nil
        }
    }
}

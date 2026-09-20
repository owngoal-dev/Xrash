import Foundation

/// A short wait for a screen's first data, so the screen comes up finished
/// instead of coming up empty and filling in a moment later. Past the budget
/// the caller shows its loading state and the data lands when it lands.
///
/// The work runs on the main actor between its awaits, so the wait turns the
/// run loop rather than blocking it — a semaphore here would deadlock.
@MainActor
enum LoadBudget {
    /// A page inside the app. About twelve frames: shorter than a push.
    static let page: TimeInterval = 0.2
    /// The cold launch, spent once behind the launch screen.
    static let launch: TimeInterval = 1

    static func wait(_ budget: TimeInterval, for work: @escaping @MainActor () async -> Void) {
        var isFinished = false
        Task { @MainActor in
            await work()
            isFinished = true
        }
        let deadline = Date().addingTimeInterval(budget)
        while !isFinished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

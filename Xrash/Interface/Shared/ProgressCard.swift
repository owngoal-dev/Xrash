import Combine
import UIKit

/// Work that makes the user wait, under the one progress card
/// (`ProgressCoverViewController`): it appears only once the work has taken a
/// moment, and it is gone before `run` returns.
///
/// Returning only after the dismissal is the point. A toast or an alert the
/// caller shows next would otherwise be presented into the card's own
/// dismissal and never appear.
///
/// Cancel stops the work and `run` throws `CancellationError` once it has
/// stopped — even where the work finished anyway, because the user was told it
/// would not. Ported from Fila's `ProgressCard`.
@MainActor
enum ProgressCard {
    /// `operation` reports its progress as a fraction — nil while it cannot
    /// say — and the line that names what it is doing now.
    static func run<T: Sendable>(
        from presenter: UIViewController,
        title: String,
        operation: @escaping @MainActor (
            _ report: @escaping @MainActor (_ fraction: Double?, _ detail: String) -> Void
        ) async throws -> T
    ) async throws -> T {
        let state = CurrentValueSubject<ProgressCoverViewController.Source.Snapshot?, Never>(
            .init(title: title, detail: "", fraction: nil, isCancellable: true)
        )
        let work = Task { @MainActor in
            try await operation { fraction, detail in
                guard var snapshot = state.value else { return }
                snapshot.fraction = fraction
                snapshot.detail = detail
                state.value = snapshot
            }
        }

        let settlement = Settlement()
        let reveal = ProgressCoverViewController.present(
            .init(
                snapshot: { state.value },
                changes: state.map { _ in }.eraseToAnyPublisher(),
                cancel: { work.cancel() }
            ),
            from: presenter,
            dismissed: { settlement.settle() }
        )

        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        // Read before the wait: a Cancel tapped while the card is leaving came
        // after the work ended and must not discard its result.
        let cancelled = work.isCancelled
        state.value = nil
        reveal.cancel()
        await settlement.wait()
        if cancelled {
            throw CancellationError()
        }
        return try result.get()
    }

    /// "The card is gone", answered once and to everyone who asks, whether or
    /// not a card was ever put on the screen.
    @MainActor
    private final class Settlement {
        private var isSettled = false
        private var waiting = [CheckedContinuation<Void, Never>]()

        func settle() {
            guard !isSettled else { return }
            isSettled = true
            let waiting = waiting
            self.waiting = []
            waiting.forEach { $0.resume() }
        }

        func wait() async {
            guard !isSettled else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }
}

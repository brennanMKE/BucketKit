import Foundation

/// Internal storage shared by every concrete ``BucketTransferTask``.
///
/// `TransferTaskState` owns the three pieces of mutable state a
/// transfer task needs:
///
/// 1. The `AsyncStream<TransferProgress>` continuation that operation
///    code yields progress events into.
/// 2. The pending callers awaiting ``BucketTransferTask/value`` —
///    suspended `CheckedContinuation`s resumed once on completion,
///    failure, or cancellation.
/// 3. The terminal outcome (success, failure, or cancelled) so
///    callers that arrive *after* the transfer finishes get the same
///    answer as those that were already waiting.
///
/// The actor is generic over the task's `Output` so a single type
/// powers all four concrete tasks (`Data`, `URL`, `UploadResult`,
/// `UploadResult`). Each public task is a `Sendable` value type that
/// holds a reference to one of these actors.
///
/// All members are `internal` — only the operation code in
/// `Sources/Bucket/Operations/` (landing in #0011 and #0012) and the
/// concrete task types in this directory should touch them.
final actor TransferTaskState<Output: Sendable> {

    /// Terminal state of a transfer. Once set, never changes; late
    /// awaiters see exactly the same outcome as anyone who was
    /// already suspended on ``value``.
    private enum Outcome {
        case success(Output)
        case failure(any Error)
    }

    /// Continuation used to yield progress events. Held here so the
    /// public task can return its `AsyncStream` directly while the
    /// operation drives this continuation from inside the actor.
    private let progressContinuation: AsyncStream<TransferProgress>.Continuation

    /// Outcome of the transfer, or `nil` while still in flight.
    private var outcome: Outcome?

    /// Continuations awaiting the final ``value``. Multiple awaiters
    /// are allowed even though most callers only `await` once.
    private var valueContinuations: [CheckedContinuation<Output, any Error>] = []

    /// Whether ``cancel()`` has been called. One-way flag.
    private var isCancelled = false

    /// Whether the transfer is currently paused. Today this is
    /// purely advisory — operation code does not yet observe it
    /// because real pause/resume requires `URLSession` integration
    /// that isn't landed. Tracked for future work.
    private var isPaused = false

    /// Creates a new transfer state, capturing the progress stream
    /// continuation. Operations build the public task via the
    /// concrete task's `make(...)` factory, which calls into here.
    init(progressContinuation: AsyncStream<TransferProgress>.Continuation) {
        self.progressContinuation = progressContinuation
    }

    // MARK: - Driving the transfer (operation-side API)

    /// Yields a progress event to subscribers. No-op once the
    /// transfer has finished or been cancelled — late events from a
    /// raced callback won't accidentally re-open a finished stream.
    func yieldProgress(_ progress: TransferProgress) {
        guard outcome == nil, !isCancelled else { return }
        progressContinuation.yield(progress)
    }

    /// Marks the transfer successful, finishes the progress stream,
    /// and resumes any pending ``value`` awaiters.
    func finish(with value: Output) {
        guard outcome == nil, !isCancelled else { return }
        outcome = .success(value)
        progressContinuation.finish()
        let waiters = valueContinuations
        valueContinuations.removeAll()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    /// Marks the transfer failed, finishes the progress stream, and
    /// resumes any pending ``value`` awaiters by throwing.
    func fail(with error: any Error) {
        guard outcome == nil, !isCancelled else { return }
        outcome = .failure(error)
        progressContinuation.finish()
        let waiters = valueContinuations
        valueContinuations.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    // MARK: - Caller-side API

    /// Cancels the transfer. Idempotent; subsequent calls are
    /// no-ops. Cancellation finishes the progress stream and causes
    /// any pending ``value`` awaiters to throw `CancellationError`.
    /// Operation code in #0011 / #0012 will additionally tear down
    /// the underlying HTTP request.
    func cancel() {
        guard !isCancelled, outcome == nil else { return }
        isCancelled = true
        outcome = .failure(CancellationError())
        progressContinuation.finish()
        let waiters = valueContinuations
        valueContinuations.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    /// Marks the transfer paused. Today this only flips a flag —
    /// operation code does not observe it yet. See ``isPaused``.
    // TODO: real pause/resume requires URLSession integration in
    // #0011 / #0012 / multipart work. For now this just records
    // intent so callers can poll the flag if useful.
    func pause() {
        guard outcome == nil, !isCancelled else { return }
        isPaused = true
    }

    /// Clears the paused flag. See ``pause()``.
    // TODO: see ``pause()`` — no-op until URLSession integration
    // lands.
    func resume() {
        guard outcome == nil, !isCancelled else { return }
        isPaused = false
    }

    /// Awaits the transfer's final value. If the transfer has
    /// already finished (success, failure, or cancelled) this
    /// resumes immediately with the recorded outcome; otherwise it
    /// suspends until the operation calls ``finish(with:)``,
    /// ``fail(with:)``, or ``cancel()``.
    func awaitValue() async throws -> Output {
        if let outcome {
            switch outcome {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            valueContinuations.append(continuation)
        }
    }
}

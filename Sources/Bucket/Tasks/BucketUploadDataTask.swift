import Foundation

/// In-flight upload of an in-memory `Data` payload.
///
/// Returned from ``BucketClient/uploadData(bucket:path:data:options:)``
/// (wired in #0011). The public type is a `Sendable` struct holding
/// a reference to the shared internal ``TransferTaskState`` actor —
/// the actor owns the progress continuation and the final-value
/// continuation; this struct just forwards calls.
///
/// On success, ``value`` resolves to an ``UploadResult`` carrying the
/// object key, ETag, and (when the bucket is versioned) the version
/// ID returned by S3.
public struct BucketUploadDataTask: BucketTransferTask {
    public typealias Output = UploadResult

    /// Shared internal state. Held as a strong reference so multiple
    /// copies of the task value all refer to the same in-flight
    /// transfer.
    let state: TransferTaskState<UploadResult>

    /// The progress stream returned to callers. The matching
    /// continuation lives inside ``state``.
    public let progress: AsyncStream<TransferProgress>

    /// Awaits the final ``UploadResult``. Suspends until the
    /// underlying operation finishes; throws on failure or
    /// cancellation.
    public var value: UploadResult {
        get async throws { try await state.awaitValue() }
    }

    /// Internal initializer — operations construct tasks via
    /// ``make()``. Direct construction is not part of the public
    /// API.
    init(
        state: TransferTaskState<UploadResult>,
        progress: AsyncStream<TransferProgress>
    ) {
        self.state = state
        self.progress = progress
    }

    /// Builds a fresh task and its backing state. Used by upload
    /// operation code in #0011.
    static func make() -> (task: BucketUploadDataTask, state: TransferTaskState<UploadResult>) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TransferProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let state = TransferTaskState<UploadResult>(progressContinuation: continuation)
        let task = BucketUploadDataTask(state: state, progress: stream)
        return (task, state)
    }

    public func cancel() {
        Task { await state.cancel() }
    }

    public func pause() {
        Task { await state.pause() }
    }

    public func resume() {
        Task { await state.resume() }
    }
}

import Foundation

/// In-flight upload of a file at a local `URL`.
///
/// Returned from
/// ``BucketClient/uploadFile(bucket:path:local:options:)`` (wired in
/// #0011). For files above the multipart threshold (default 100
/// MiB), the operation transparently uses S3 multipart with parallel
/// parts; cancellation triggers a best-effort
/// `AbortMultipartUpload`.
///
/// The public type is a `Sendable` struct holding a reference to the
/// shared internal ``TransferTaskState`` actor.
public struct BucketUploadFileTask: BucketTransferTask {
    public typealias Output = UploadResult

    /// Shared internal state. See ``BucketUploadDataTask`` for the
    /// rationale behind the value-type-over-actor design.
    let state: TransferTaskState<UploadResult>

    public let progress: AsyncStream<TransferProgress>

    public var value: UploadResult {
        get async throws { try await state.awaitValue() }
    }

    init(
        state: TransferTaskState<UploadResult>,
        progress: AsyncStream<TransferProgress>
    ) {
        self.state = state
        self.progress = progress
    }

    static func make() -> (task: BucketUploadFileTask, state: TransferTaskState<UploadResult>) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TransferProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let state = TransferTaskState<UploadResult>(progressContinuation: continuation)
        let task = BucketUploadFileTask(state: state, progress: stream)
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

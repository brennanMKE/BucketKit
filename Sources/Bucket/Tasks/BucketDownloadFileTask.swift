import Foundation

/// In-flight download of an object's bytes to a local file.
///
/// Returned from
/// ``BucketClient/downloadFile(bucket:path:local:options:)`` (wired
/// in #0012). On success, ``value`` resolves to the local `URL` the
/// operation wrote to — typically the `local` argument the caller
/// supplied, possibly normalized.
///
/// The public type is a `Sendable` struct holding a reference to the
/// shared internal ``TransferTaskState`` actor.
public struct BucketDownloadFileTask: BucketTransferTask {
    public typealias Output = URL

    /// Shared internal state.
    let state: TransferTaskState<URL>

    public let progress: AsyncStream<TransferProgress>

    public var value: URL {
        get async throws { try await state.awaitValue() }
    }

    init(
        state: TransferTaskState<URL>,
        progress: AsyncStream<TransferProgress>
    ) {
        self.state = state
        self.progress = progress
    }

    static func make() -> (task: BucketDownloadFileTask, state: TransferTaskState<URL>) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TransferProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let state = TransferTaskState<URL>(progressContinuation: continuation)
        let task = BucketDownloadFileTask(state: state, progress: stream)
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

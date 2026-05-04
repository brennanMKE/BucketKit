import Foundation

/// In-flight download of an object's bytes into memory.
///
/// Returned from
/// ``BucketClient/downloadData(bucket:path:options:)`` (wired in
/// #0012). The public type is a `Sendable` struct holding a
/// reference to the shared internal ``TransferTaskState`` actor.
///
/// On success, ``value`` resolves to the object's bytes as `Data`.
public struct BucketDownloadDataTask: BucketTransferTask {
    public typealias Output = Data

    /// Shared internal state.
    let state: TransferTaskState<Data>

    public let progress: AsyncStream<TransferProgress>

    public var value: Data {
        get async throws { try await state.awaitValue() }
    }

    init(
        state: TransferTaskState<Data>,
        progress: AsyncStream<TransferProgress>
    ) {
        self.state = state
        self.progress = progress
    }

    static func make() -> (task: BucketDownloadDataTask, state: TransferTaskState<Data>) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TransferProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let state = TransferTaskState<Data>(progressContinuation: continuation)
        let task = BucketDownloadDataTask(state: state, progress: stream)
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

import Foundation

/// A long-running upload or download exposed to callers as a value
/// type they can observe and control.
///
/// `BucketTransferTask` is the shared shape of every upload and
/// download returned by ``BucketClient``. It deliberately mirrors
/// Amplify's `StorageTask` so callers familiar with Amplify Storage
/// see the same three affordances:
///
/// - ``progress`` — an `AsyncStream<TransferProgress>` of byte-count
///   updates. The stream finishes when the operation completes,
///   fails, or is cancelled. Iterating progress is opt-in; simple
///   callers just await ``value``.
/// - ``value`` — the final result of the transfer (`Data`, `URL`, or
///   ``UploadResult`` depending on the concrete task). Throws on
///   failure or cancellation.
/// - ``cancel()``, ``pause()``, ``resume()`` — out-of-band controls
///   that are independent of structured task cancellation. They
///   exist because uploads and downloads frequently outlive the
///   `Task` that started them (e.g. driven by a button on a long-
///   lived view) and pause/resume has no analogue in plain
///   `async`/`await`.
///
/// All concrete tasks are `Sendable` value types backed by a shared
/// internal actor that owns the progress continuation and the final-
/// value continuation. See the `Tasks/` directory for the four
/// concrete types: ``BucketUploadDataTask``,
/// ``BucketUploadFileTask``, ``BucketDownloadDataTask``, and
/// ``BucketDownloadFileTask``.
///
/// `Output` is constrained to `Sendable` so the result can cross the
/// internal actor boundary back to the caller.
public protocol BucketTransferTask<Output>: Sendable {
    /// The type of value produced by this transfer when it succeeds.
    associatedtype Output: Sendable

    /// Stream of progress events. Buffers the most recent event so a
    /// slow consumer cannot drown in updates from a fast multipart
    /// upload — only the latest delta is retained when the consumer
    /// falls behind.
    ///
    /// The stream finishes (without yielding a terminal sentinel)
    /// when the transfer completes, fails, or is cancelled. The
    /// authoritative outcome is delivered through ``value``.
    var progress: AsyncStream<TransferProgress> { get }

    /// The final result of the transfer. Suspends until the
    /// underlying operation finishes; throws if the operation fails
    /// or is cancelled.
    ///
    /// Callers who only want the result can ignore ``progress`` and
    /// simply `await task.value`.
    var value: Output { get async throws }

    /// Cancels the transfer. Finishes ``progress`` and causes
    /// ``value`` to throw. Cancellation is a one-way transition;
    /// subsequent calls are no-ops. Cancellation also forwards
    /// through to the underlying HTTP request when the operation is
    /// driving the task (wired in #0011 / #0012); for multipart
    /// uploads this is a best-effort `AbortMultipartUpload`.
    func cancel()

    /// Pauses the transfer. Currently a no-op; real pause/resume
    /// requires a `URLSession`-driven implementation that is not
    /// landed yet. Tracked for #0011 / #0012 / multipart work.
    func pause()

    /// Resumes a paused transfer. Currently a no-op; see ``pause()``.
    func resume()
}

/// A single byte-count snapshot from an in-flight transfer.
///
/// `TransferProgress` is intentionally minimal. Callers that want
/// throughput, ETA, or smoothing should derive those from a sequence
/// of snapshots — we don't bake any policy into the model.
///
/// `totalBytes` and `fractionCompleted` are optional because the
/// total is unknown for some downloads (e.g. an HTTP response with
/// `Transfer-Encoding: chunked` and no `Content-Length`). When the
/// total is known, ``fractionCompleted`` is provided as a
/// convenience — it equals `Double(bytesTransferred) /
/// Double(totalBytes!)` clamped to `0...1`.
public struct TransferProgress: Sendable, Hashable {
    /// Total expected byte count, or `nil` if the size is unknown.
    public let totalBytes: Int64?

    /// Bytes transferred so far. Monotonically non-decreasing within
    /// a single transfer.
    public let bytesTransferred: Int64

    /// `bytesTransferred / totalBytes`, clamped to `0...1`, or `nil`
    /// when ``totalBytes`` is `nil`.
    public let fractionCompleted: Double?

    /// Creates a progress snapshot.
    ///
    /// - Parameters:
    ///   - totalBytes: Total expected byte count, or `nil` if
    ///     unknown.
    ///   - bytesTransferred: Bytes transferred so far.
    ///   - fractionCompleted: Pass `nil` to compute the fraction
    ///     automatically from ``totalBytes`` and
    ///     ``bytesTransferred``; pass an explicit value to override
    ///     (e.g. when reporting multipart progress derived from
    ///     completed parts rather than raw bytes).
    public init(
        totalBytes: Int64?,
        bytesTransferred: Int64,
        fractionCompleted: Double? = nil
    ) {
        self.totalBytes = totalBytes
        self.bytesTransferred = bytesTransferred
        if let fractionCompleted {
            self.fractionCompleted = fractionCompleted
        } else if let totalBytes, totalBytes > 0 {
            let raw = Double(bytesTransferred) / Double(totalBytes)
            self.fractionCompleted = max(0.0, min(1.0, raw))
        } else {
            self.fractionCompleted = nil
        }
    }
}

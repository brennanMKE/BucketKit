import Foundation

/// Client-side errors BucketKit raises before, around, or instead of
/// a service-level ``BucketServiceError``.
///
/// Per PRD §8 these are the only two error types the public API
/// throws. ``BucketClientError`` covers everything that is *not* a
/// well-formed S3 protocol error: configuration problems, signing
/// bugs, transport failures (DNS/TLS/no-network), response decoding
/// failures, multipart misuse, and structured task cancellation.
public enum BucketClientError: Error, Sendable {
    /// Configuration could not be used to build a valid request
    /// (missing scheme/host, malformed endpoint, etc.). The
    /// associated string is a short human-readable diagnostic.
    case invalidConfiguration(String)

    /// SigV4 signing produced an invalid signature or could not be
    /// computed. The associated string carries a short diagnostic.
    case signingFailed(String)

    /// The underlying transport failed before a complete HTTP
    /// response could be observed (DNS, TLS, connectivity, timeout).
    /// `URLError` is `Sendable` on Apple platforms.
    case transport(URLError)

    /// A response body could not be decoded into the expected XML
    /// model. The associated string carries a short diagnostic.
    case decodingFailed(String)

    /// A multipart upload part was supplied below S3's 5 MiB minimum
    /// (any part except the last). Carries the offending part
    /// number and its size in bytes for the caller to act on.
    case multipartPartTooSmall(partNumber: Int, size: Int)

    /// The operation was cancelled, either via structured task
    /// cancellation or an explicit `task.cancel()` on a
    /// ``BucketTransferTask``.
    case cancelled
}

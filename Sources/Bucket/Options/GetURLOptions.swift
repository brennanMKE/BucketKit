import Foundation

/// Options for ``BucketClient/getURL(bucket:path:options:)``.
///
/// A presigned URL packages a single S3 operation into a self-contained
/// URL whose query string carries the credential scope, expiry, and
/// SigV4 signature. Default values produce a one-hour `GET` URL with
/// no extra signed headers — the most common shape.
///
/// - ``method`` — HTTP verb the URL is bound to. A presigned `GET`
///   URL cannot be used for `PUT` and vice versa.
/// - ``expiresIn`` — lifetime of the URL. Defaults to one hour;
///   capped at S3's 7-day maximum (``Duration.seconds(604_800)``).
///   Values outside `[1s, 7d]` cause
///   ``BucketClientError/invalidConfiguration(_:)`` at signing time.
/// - ``headersToSign`` — extra headers folded into the signature
///   beyond the always-required `Host`. **The caller must send
///   these exact headers, with these exact values, when using the
///   resulting URL** — otherwise S3 rejects the request as
///   `SignatureDoesNotMatch`. Names are lowercased before signing.
public struct GetURLOptions: Sendable {
    /// HTTP method the presigned URL is bound to. Defaults to ``HTTPMethod/get``.
    public var method: HTTPMethod

    /// Validity window for the URL. Defaults to one hour. Must fall
    /// within `[1s, 604_800s]` (1 second to 7 days) — outside that
    /// range, ``BucketClient/getURL(bucket:path:options:)`` throws
    /// ``BucketClientError/invalidConfiguration(_:)``.
    public var expiresIn: Duration

    /// Extra headers to fold into the signature. The caller is
    /// responsible for sending the exact same headers (same names,
    /// same values) when using the URL — see the type docs.
    public var headersToSign: [String: String]

    /// Memberwise initializer. All parameters have defaults, so callers
    /// can write `GetURLOptions()` for the common case.
    public init(
        method: HTTPMethod = .get,
        expiresIn: Duration = .seconds(3600),
        headersToSign: [String: String] = [:]
    ) {
        self.method = method
        self.expiresIn = expiresIn
        self.headersToSign = headersToSign
    }
}

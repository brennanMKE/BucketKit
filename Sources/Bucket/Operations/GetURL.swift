import Foundation
import os

extension BucketClient {
    /// Returns a presigned URL for a single S3 operation against
    /// `bucket`/`path`.
    ///
    /// Computed locally — no network round-trip. The URL embeds the
    /// SigV4 credential scope, expiry, signed-headers list, and the
    /// signature itself, so a third party (browser, CDN, another
    /// service) can run exactly one operation without holding
    /// credentials.
    ///
    /// The URL is bound to the verb in ``GetURLOptions/method``.
    /// Mismatches between the verb in the URL and the request that
    /// uses it surface as `SignatureDoesNotMatch` (HTTP 403).
    ///
    /// If ``GetURLOptions/headersToSign`` is non-empty the caller is
    /// responsible for sending those headers — with those exact
    /// values — when using the URL. Missing or modified signed
    /// headers also produce `SignatureDoesNotMatch`.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name. Combined with the configuration's
    ///     endpoint and `usePathStyle` flag to form the request URL.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - options: Method, expiry, and any extra headers to fold into
    ///     the signature. See ``GetURLOptions``.
    /// - Returns: A signed `URL` ready for a single S3 operation.
    /// - Throws: ``BucketClientError/invalidConfiguration(_:)`` if the
    ///   endpoint is malformed or `expiresIn` is outside `[1s, 7d]`.
    public func getURL(
        bucket: String,
        path: any BucketPath,
        options: GetURLOptions = .init()
    ) async throws -> URL {
        let key = path.resolve()
        let baseURL = try Self.makePresignBaseURL(
            bucket: bucket,
            key: key,
            configuration: configuration
        )

        // Logging is `.debug` and deliberately omits the URL itself —
        // its query string carries the credential and signature once
        // signed, and even the unsigned form leaks the bucket/key.
        // Length stands in for a privacy-safe fingerprint.
        Self.logger.debug(
            "getURL method=\(options.method.rawValue, privacy: .public) bucket=\(bucket, privacy: .public) keyLen=\(key.count, privacy: .public)"
        )

        // Configuration-level extra headers participate in the
        // signature exactly like ``GetURLOptions/headersToSign``.
        // Operation headers win on key conflict — same merge order as
        // every other operation in the package.
        var headersToSign = options.headersToSign
        configuration.mergeBaseHeaders(into: &headersToSign)

        return try PresignedURL.sign(
            method: options.method,
            url: baseURL,
            additionalSignedHeaders: headersToSign,
            credentials: SigV4Signer.Credentials(
                accessKeyID: configuration.accessKeyID,
                secretAccessKey: configuration.secretAccessKey,
                sessionToken: configuration.sessionToken
            ),
            region: configuration.region,
            service: "s3",
            expiresIn: options.expiresIn
        )
    }

    // MARK: - Internals

    private static let logger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "signing"
    )

    /// Constructs the base URL used as input to ``PresignedURL/sign(...)``.
    ///
    /// Same virtual-hosted vs path-style logic as ``Upload`` and
    /// ``Download`` — kept here as a private mirror until the three
    /// builders are unified. The key is encoded one segment at a time
    /// with SigV4's percent-encoding rules so the canonical-URI we
    /// sign matches the URL we return.
    private static func makePresignBaseURL(
        bucket: String,
        key: String,
        configuration: BucketConfiguration
    ) throws -> URL {
        let endpoint = configuration.endpoint
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw BucketClientError.invalidConfiguration(
                "endpoint missing scheme or host: \(endpoint.absoluteString)"
            )
        }

        let encodedKey = key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { sigv4PercentEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")

        var components = URLComponents()
        components.scheme = scheme
        components.port = endpoint.port
        if configuration.usePathStyle {
            components.host = host
            let basePath = endpoint.path.hasSuffix("/")
                ? String(endpoint.path.dropLast())
                : endpoint.path
            components.percentEncodedPath = "\(basePath)/\(bucket)/\(encodedKey)"
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/\(encodedKey)"
        }

        guard let url = components.url else {
            throw BucketClientError.invalidConfiguration(
                "could not build object URL from endpoint: \(endpoint.absoluteString)"
            )
        }
        return url
    }
}

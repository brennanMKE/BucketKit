import Foundation

/// SigV4 query-string presigner.
///
/// Where ``SigV4Signer`` lifts the signature into an `Authorization`
/// header on a live request, presigning lifts it into the URL itself
/// so a third party — a browser, another service, a CDN — can run a
/// single S3 operation without holding credentials.
///
/// Mechanically the two paths differ in just a few places:
///
/// - The five `X-Amz-*` parameters (`Algorithm`, `Credential`, `Date`,
///   `Expires`, `SignedHeaders`) are added to the URL's query string
///   **before** the canonical request is built, so they participate in
///   the signature.
/// - `X-Amz-Security-Token` follows the same pattern when a session
///   token is present.
/// - The payload hash is the literal sentinel ``CanonicalRequest/unsignedPayload``
///   regardless of HTTP method — the body (if any) is sent unsigned.
/// - The signed headers list defaults to just `host`. Callers can fold
///   in additional headers via ``GetURLOptions/headersToSign``; those
///   headers must then be sent verbatim by whoever uses the URL.
/// - The final signature is appended as `&X-Amz-Signature={hex}`. It
///   is **not** itself part of the canonical query string.
///
/// This helper is internal — the public surface is
/// ``BucketClient/getURL(bucket:path:options:)``.
internal enum PresignedURL {
    /// Maximum allowed lifetime per the S3 spec — 7 days.
    fileprivate static let maxExpiresInSeconds: Int64 = 604_800
    /// Minimum allowed lifetime — anything under a second is nonsense.
    fileprivate static let minExpiresInSeconds: Int64 = 1

    /// Produces a presigned URL for the given method and base URL.
    ///
    /// - Parameters:
    ///   - method: HTTP verb the URL is bound to. The same verb must
    ///     be used by whoever ultimately calls the URL.
    ///   - url: Base URL for the operation, including any pre-existing
    ///     query items. Path encoding is the caller's responsibility
    ///     (use the same per-segment SigV4 percent-encoding the rest of
    ///     the package uses).
    ///   - additionalSignedHeaders: Headers to include in the signature
    ///     beyond `host`. Names are lowercased before being added to
    ///     the canonical headers block. Values are signed as supplied
    ///     and must be sent verbatim by the URL's user.
    ///   - credentials: Access key, secret, and optional session token.
    ///   - region: SigV4 region (literal `auto` for R2, `us-east-1` for
    ///     Spaces, etc.).
    ///   - service: SigV4 service token. `s3` for the bucket API.
    ///   - expiresIn: Validity window. Must fall within
    ///     `[1s, 7d]`; outside that range we throw
    ///     ``BucketClientError/invalidConfiguration(_:)``.
    ///   - clock: Source of "now". Injectable so tests can pin a
    ///     specific signing time.
    /// - Returns: The original URL with the `X-Amz-*` parameters and
    ///   `X-Amz-Signature` appended to its query.
    /// - Throws: ``BucketClientError/invalidConfiguration(_:)`` when
    ///   `expiresIn` is out of range or the URL cannot be parsed.
    internal static func sign(
        method: HTTPMethod,
        url: URL,
        additionalSignedHeaders: [String: String],
        credentials: SigV4Signer.Credentials,
        region: String,
        service: String,
        expiresIn: Duration,
        clock: @Sendable () -> Date = { Date() }
    ) throws -> URL {
        let expiresInSeconds = secondsValue(of: expiresIn)
        guard
            expiresInSeconds >= minExpiresInSeconds,
            expiresInSeconds <= maxExpiresInSeconds
        else {
            throw BucketClientError.invalidConfiguration(
                "expiresIn must be 1s–7d"
            )
        }

        let now = clock()
        let amzDate = amzDateFormatter.string(from: now)
        let dateStamp = dateStampFormatter.string(from: now)

        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = url.host
        else {
            throw BucketClientError.invalidConfiguration(
                "could not parse URL for presigning: \(url.absoluteString)"
            )
        }

        // Build the headers we will sign. `host` is always required;
        // additional headers (lowercased) ride along verbatim.
        var signedHeaders: [String: String] = [:]
        signedHeaders["host"] = hostHeader(host: host, port: url.port, scheme: url.scheme)
        for (name, value) in additionalSignedHeaders {
            signedHeaders[name.lowercased()] = value
        }

        let signedHeaderList = signedHeaders.keys.sorted().joined(separator: ";")

        // Existing query items on the URL — preserve them so callers
        // can presign URLs that already carry sub-resource markers
        // like `?uploads` or `?versionId=...`. We re-canonicalize them
        // alongside the X-Amz-* additions below.
        let existingItems = parseExistingQueryItems(components)

        let credential =
            "\(credentials.accessKeyID)/\(dateStamp)/\(region)/\(service)/\(CanonicalRequest.requestType)"

        // Five mandatory presigning parameters, plus the optional
        // session-token parameter. Names are case-sensitive on the wire
        // — keep them as `X-Amz-*` exactly.
        var presignItems: [URLQueryItem] = [
            URLQueryItem(name: "X-Amz-Algorithm", value: CanonicalRequest.algorithm),
            URLQueryItem(name: "X-Amz-Credential", value: credential),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expiresInSeconds)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: signedHeaderList),
        ]
        if let token = credentials.sessionToken, !token.isEmpty {
            presignItems.append(
                URLQueryItem(name: "X-Amz-Security-Token", value: token)
            )
        }

        // Canonical query string includes both the URL's pre-existing
        // items and the X-Amz-* additions. The canonicalizer sorts and
        // re-encodes per SigV4 percent-encoding rules.
        let canonicalQueryItems = existingItems + presignItems

        let path = url.path.isEmpty ? "/" : url.path
        let canonicalInput = CanonicalRequest.Input(
            method: method.rawValue,
            path: path,
            queryItems: canonicalQueryItems,
            headers: signedHeaders,
            payloadHash: CanonicalRequest.unsignedPayload
        )

        let (canonical, _) = CanonicalRequest.canonicalize(canonicalInput)

        let (stringToSign, _) = CanonicalRequest.stringToSign(
            amzDate: amzDate,
            dateStamp: dateStamp,
            region: region,
            service: service,
            canonicalRequest: canonical
        )

        let signingKey = CanonicalRequest.deriveSigningKey(
            secretAccessKey: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: service
        )

        let signature = CanonicalRequest.signature(
            stringToSign: stringToSign,
            signingKey: signingKey
        )

        // Build the final query string by emitting every item with the
        // SigV4 percent-encoding so the URL we return matches what was
        // signed. We then append `X-Amz-Signature={hex}` last — the
        // signature is not itself part of the canonical query string,
        // but its position in the URL is conventional.
        let finalItemsWithoutSignature = canonicalQueryItems
        let encodedQuery = encodeQueryItems(finalItemsWithoutSignature)
        let signatureSuffix = "X-Amz-Signature=\(signature)"
        components.percentEncodedQuery =
            encodedQuery.isEmpty ? signatureSuffix : "\(encodedQuery)&\(signatureSuffix)"

        guard let signedURL = components.url else {
            throw BucketClientError.invalidConfiguration(
                "could not assemble presigned URL"
            )
        }
        return signedURL
    }

    // MARK: - Helpers

    /// Pulls existing query items off a `URLComponents`, preserving
    /// the original (non-encoded) name/value pairs so the canonical
    /// request layer can re-encode them under SigV4's rules without
    /// double-encoding. Mirrors ``SigV4Signer``'s parser.
    private static func parseExistingQueryItems(
        _ components: URLComponents
    ) -> [URLQueryItem] {
        if let encoded = components.percentEncodedQueryItems {
            return encoded.map { item in
                URLQueryItem(
                    name: item.name.removingPercentEncoding ?? item.name,
                    value: item.value?.removingPercentEncoding ?? item.value
                )
            }
        }
        return components.queryItems ?? []
    }

    /// Encode a list of query items into the on-wire query string
    /// using the same SigV4 percent-encoding rules the canonicalizer
    /// uses. Sorting matches the canonical-query-string ordering so the
    /// URL we return is byte-equivalent to what was signed (modulo the
    /// trailing `X-Amz-Signature` parameter, which we append separately).
    private static func encodeQueryItems(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let encoded: [(String, String)] = items.map { item in
            let n = sigv4PercentEncode(item.name, encodeSlash: true)
            let v = sigv4PercentEncode(item.value ?? "", encodeSlash: true)
            return (n, v)
        }
        let sorted = encoded.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// Build the `Host` header value used in the canonical headers
    /// block. Includes the port only when it is non-default for the
    /// scheme — matches ``SigV4Signer``'s `hostHeader`.
    private static func hostHeader(host: String, port: Int?, scheme: String?) -> String {
        if let port, !isDefaultPort(port, scheme: scheme) {
            return "\(host):\(port)"
        }
        return host
    }

    private static func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        switch scheme?.lowercased() {
        case "https": return port == 443
        case "http": return port == 80
        default: return false
        }
    }

    /// Convert a `Duration` to an integer number of seconds, flooring
    /// any sub-second remainder. A `Duration` is `(seconds, attoseconds)`;
    /// we drop the attoseconds because S3 only accepts whole-second
    /// expiry values.
    private static func secondsValue(of duration: Duration) -> Int64 {
        Int64(duration.components.seconds)
    }

    // MARK: - Date formatting

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC. Mirrors ``SigV4Signer`` so the
    /// two paths produce identical timestamps for the same `Date`.
    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// `yyyyMMdd` in UTC.
    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

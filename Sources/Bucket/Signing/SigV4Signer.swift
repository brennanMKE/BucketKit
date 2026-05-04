import Foundation

/// Produces SigV4 `Authorization` headers (and the supporting
/// `x-amz-*` headers) for an in-memory request representation.
///
/// The signer is deliberately transport-agnostic: it does not depend on
/// `URLRequest`, `URLSession`, or any higher-level client type. Callers
/// hand in the request shape, get back the headers to attach. This
/// keeps the signer trivially testable against the official AWS SigV4
/// test vectors (#0007) and lets the future presigner (#0018) reuse
/// the same canonical-request layer.
///
/// Marked `internal` while the API churns — it can be widened later
/// once the surface stabilizes.
struct SigV4Signer: Sendable {
    /// Credentials and scope this signer carries. A signer is bound to
    /// a single `(credentials, region, service)` triple at
    /// construction; rotating credentials means building a new signer.
    let credentials: Credentials
    let region: String
    let service: String

    /// Source of "now" for `x-amz-date`. Injectable so that test
    /// vectors (#0007) can pin a specific signing time. The default
    /// captures `Date()` on each call.
    private let clock: @Sendable () -> Date

    /// Credential triple. Kept as a separate value so callers that
    /// already split credentials out of `BucketConfiguration` do not
    /// need to materialize a full configuration just to sign.
    struct Credentials: Sendable {
        var accessKeyID: String
        var secretAccessKey: String
        var sessionToken: String?

        init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    // MARK: - Init

    init(
        credentials: Credentials,
        region: String,
        service: String = "s3",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.region = region
        self.service = service
        self.clock = clock
    }

    /// Convenience initializer that pulls credentials and region from a
    /// `BucketConfiguration`. The `service` is hardcoded to `"s3"` for
    /// now; this will become configurable when (or if) BucketKit grows
    /// support for other AWS services.
    init(
        configuration: BucketConfiguration,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            credentials: Credentials(
                accessKeyID: configuration.accessKeyID,
                secretAccessKey: configuration.secretAccessKey,
                sessionToken: configuration.sessionToken
            ),
            region: configuration.region,
            service: "s3",
            clock: clock
        )
    }

    // MARK: - Request shape

    /// Description of an HTTP request to be signed. Callers fill this
    /// in from whatever transport they use; the signer reads it and
    /// returns the headers to attach.
    struct Request: Sendable {
        var method: String
        /// Absolute URL for the request. Host, path, and query are read
        /// from this; scheme/port are not part of the signature.
        var url: URL
        /// Caller-supplied headers. Names are case-insensitive on the
        /// wire. The signer will add `host`, `x-amz-date`,
        /// `x-amz-content-sha256`, and (when present) `x-amz-security-token`
        /// before signing — callers do not need to pre-populate them.
        var headers: [String: String]
        /// Either a hex SHA-256 of the body, or
        /// `CanonicalRequest.unsignedPayload` for streamed bodies, or
        /// `CanonicalRequest.emptyPayloadHash` for empty bodies. The
        /// signer also writes this value into the
        /// `x-amz-content-sha256` header.
        var payloadHash: String

        init(
            method: String,
            url: URL,
            headers: [String: String] = [:],
            payloadHash: String
        ) {
            self.method = method
            self.url = url
            self.headers = headers
            self.payloadHash = payloadHash
        }
    }

    /// The output of `sign(_:)`. The `headers` dictionary is what the
    /// transport layer should merge onto the outgoing request — it
    /// includes the `Authorization` header plus the `x-amz-*` headers
    /// the signer added or computed.
    struct SignedHeaders: Sendable {
        var headers: [String: String]
        /// The semicolon-joined, lowercased list of header names that
        /// were included in the signature. Useful for diagnostics and
        /// for #0018's presigning path.
        var signedHeaderList: String
        /// The credential scope (`{date}/{region}/{service}/aws4_request`),
        /// kept for diagnostics and #0018.
        var credentialScope: String
    }

    // MARK: - Signing

    /// Signs a request and returns the headers to attach.
    ///
    /// Mutates nothing on the input. The returned `headers` dictionary
    /// includes everything the caller needs to put on the wire to
    /// produce a valid request — `Authorization`, `x-amz-date`,
    /// `x-amz-content-sha256`, plus `x-amz-security-token` when a
    /// session token is configured, and a synthesized `host` header
    /// (since URLSession sets `Host` itself, the caller may drop ours
    /// when building the actual `URLRequest`; the value is still part
    /// of the signed headers and must therefore match what the
    /// transport sends).
    func sign(_ request: Request) -> SignedHeaders {
        let now = clock()
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        // Build the headers we will sign over. We start from the
        // caller-supplied set (case-insensitive insert) and add the
        // SigV4-required ones.
        var headers = CaseInsensitiveHeaders(request.headers)
        headers.set("host", value: hostHeader(from: request.url))
        headers.set("x-amz-date", value: amzDate)
        headers.set("x-amz-content-sha256", value: request.payloadHash)
        if let token = credentials.sessionToken, !token.isEmpty {
            headers.set("x-amz-security-token", value: token)
        }

        let path = request.url.path.isEmpty ? "/" : request.url.path
        let queryItems = parseQueryItems(from: request.url)

        let canonicalInput = CanonicalRequest.Input(
            method: request.method,
            path: path,
            queryItems: queryItems,
            headers: headers.dictionary,
            payloadHash: request.payloadHash
        )

        let (canonical, signedHeaderList) = CanonicalRequest.canonicalize(canonicalInput)

        let (stringToSign, credentialScope) = CanonicalRequest.stringToSign(
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

        let credential = "\(credentials.accessKeyID)/\(credentialScope)"
        let authorization =
            "\(CanonicalRequest.algorithm) " +
            "Credential=\(credential), " +
            "SignedHeaders=\(signedHeaderList), " +
            "Signature=\(signature)"

        // Never log the Authorization value, credentials, session
        // tokens, or the request URL (which carries bucket/key and
        // for presigned requests would carry the signature itself).
        // Logging the method and the signed-header list is safe and
        // helpful for diagnosing SignatureDoesNotMatch.
        BucketLog.signing.debug("Signed \(request.method, privacy: .public) request; signed-headers=\(signedHeaderList, privacy: .public)")

        var output = headers.dictionary
        output["Authorization"] = authorization

        return SignedHeaders(
            headers: output,
            signedHeaderList: signedHeaderList,
            credentialScope: credentialScope
        )
    }

    // MARK: - Helpers

    /// Build the `Host` header value from a URL. Includes the port
    /// only when it is non-default for the scheme — S3 in production
    /// is always `https` on 443, so the bare host is correct, but
    /// MinIO and similar gateways often run on a custom port and need
    /// the port included in the canonical `host` header.
    private func hostHeader(from url: URL) -> String {
        guard let host = url.host else { return "" }
        if let port = url.port, !isDefaultPort(port, scheme: url.scheme) {
            return "\(host):\(port)"
        }
        return host
    }

    private func isDefaultPort(_ port: Int, scheme: String?) -> Bool {
        switch scheme?.lowercased() {
        case "https": return port == 443
        case "http": return port == 80
        default: return false
        }
    }

    /// Pulls the query items out of a URL without re-encoding. We use
    /// `URLComponents` and read the raw `percentEncodedQueryItems` so
    /// callers can pass in already-encoded query components without
    /// double-encoding. The canonicalization layer will re-percent-encode
    /// to the SigV4 rules.
    private func parseQueryItems(from url: URL) -> [URLQueryItem] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }
        // Prefer the percent-encoded form so we can decode then re-encode
        // under SigV4's rules. If the URL has no query, return empty.
        if let encoded = comps.percentEncodedQueryItems {
            return encoded.map { item in
                URLQueryItem(
                    name: item.name.removingPercentEncoding ?? item.name,
                    value: item.value?.removingPercentEncoding ?? item.value
                )
            }
        }
        return comps.queryItems ?? []
    }

    // MARK: - Date formatting

    /// `yyyyMMdd'T'HHmmss'Z'` in UTC.
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

// MARK: - Case-insensitive header bag

/// Lightweight helper that lets us treat a `[String: String]` header
/// dictionary case-insensitively while preserving the lowercased name
/// on output (which is what the canonical-request layer wants anyway).
private struct CaseInsensitiveHeaders {
    private(set) var dictionary: [String: String] = [:]

    init(_ headers: [String: String]) {
        for (name, value) in headers {
            dictionary[name.lowercased()] = value
        }
    }

    mutating func set(_ name: String, value: String) {
        dictionary[name.lowercased()] = value
    }
}

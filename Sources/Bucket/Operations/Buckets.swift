import Foundation
import os

extension BucketClient {
    /// Lists every bucket the configured credentials own (or have
    /// `s3:ListAllMyBuckets` against).
    ///
    /// Issues `GET /` against the **service** endpoint — i.e. the
    /// configuration's host, with no bucket name in either the path or
    /// the hostname. Decodes the `ListAllMyBucketsResult` XML body and
    /// maps each `<Bucket>` entry to a ``BucketInfo``.
    ///
    /// Endpoint addressing note: `ListAllMyBuckets` is conceptually a
    /// virtual-hosted operation (it has no bucket to put in the
    /// host), but for path-style endpoints — MinIO, custom gateways —
    /// the request is identical: host plus `/`, signed with the empty
    /// payload hash. The signer reads its `Host` from the URL, so the
    /// same builder works for both addressing styles.
    ///
    /// On any non-2xx a typed ``BucketServiceError`` is thrown.
    ///
    /// - Returns: Every bucket the caller owns.
    public func listBuckets() async throws -> [BucketInfo] {
        let configuration = self.configuration
        let transport = self.transport

        Self.bucketsLogger.debug("listBuckets start")

        do {
            return try await RetryRunner.run(policy: retryPolicy, logger: Self.bucketsLogger) { _ in
                try Task.checkCancellation()

                let request = try Self.buildSignedListBucketsRequest(
                    configuration: configuration
                )

                try Task.checkCancellation()

                let (responseBody, response) = try await transport.send(request, body: nil)

                try Task.checkCancellation()

                let status = response.statusCode
                guard (200..<300).contains(status) else {
                    throw BucketServiceError.decode(httpStatus: status, body: responseBody)
                }

                let decoded: ListAllMyBucketsResult
                do {
                    decoded = try XMLDecoder.decode(ListAllMyBucketsResult.self, from: responseBody)
                } catch {
                    throw BucketClientError.decodingFailed(String(describing: error))
                }

                let buckets = decoded.buckets.map { entry in
                    BucketInfo(name: entry.name, creationDate: entry.creationDate)
                }

                Self.bucketsLogger.debug("listBuckets finish status=\(status, privacy: .public) count=\(buckets.count, privacy: .public)")
                return buckets
            }
        } catch is CancellationError {
            throw BucketClientError.cancelled
        } catch let urlError as URLError {
            throw BucketClientError.transport(urlError)
        }
    }

    /// Creates a bucket named `name`.
    ///
    /// Issues `PUT /{bucket}` (path-style) or `PUT /` against the
    /// virtual-hosted bucket subdomain. When `locationConstraint` is
    /// supplied **and** is not `"us-east-1"` (the AWS default, which
    /// must NOT include a body), the request carries a
    /// `CreateBucketConfiguration` XML body and is signed with the
    /// SHA-256 of that body; otherwise the body is empty and the
    /// request is signed with the empty payload hash.
    ///
    /// Provider quirks (do not try to be clever about these — pass
    /// through whatever the caller supplies):
    ///
    /// - **AWS S3** treats `us-east-1` as the default and rejects a
    ///   request that includes a `CreateBucketConfiguration` for it.
    ///   Pass `nil` (or omit `locationConstraint`) for `us-east-1`.
    /// - **Cloudflare R2** expects `LocationConstraint` matching its
    ///   jurisdiction (`auto`, `wnam`, `enam`, `weur`, `eeur`, `apac`).
    /// - **DigitalOcean Spaces** ignores `LocationConstraint`
    ///   altogether — the geographic region is encoded in the
    ///   endpoint, not the body.
    /// - **MinIO** generally accepts any `LocationConstraint` and
    ///   ignores it in single-server deployments.
    ///
    /// On non-2xx a typed ``BucketServiceError`` is thrown.
    ///
    /// - Parameters:
    ///   - name: Bucket name. Must be a DNS-valid bucket name; the
    ///     configuration's addressing style determines whether it
    ///     ends up in the path or the host subdomain.
    ///   - locationConstraint: Optional region/jurisdiction string
    ///     forwarded as the `<LocationConstraint>` element. `nil` (the
    ///     default) sends an empty-body request.
    public func createBucket(
        _ name: String,
        locationConstraint: String? = nil
    ) async throws {
        let configuration = self.configuration
        let transport = self.transport

        Self.bucketsLogger.debug(
            "createBucket start bucket=\(name, privacy: .public) locationConstraint=\(locationConstraint ?? "-", privacy: .public)"
        )

        // AWS rejects a CreateBucketConfiguration body for
        // us-east-1. We treat that as "no body" so the call
        // shapes the same request the AWS console would.
        let body: Data? = {
            guard let region = locationConstraint, region != "us-east-1" else {
                return nil
            }
            let xml =
                "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" +
                "<LocationConstraint>\(region)</LocationConstraint>" +
                "</CreateBucketConfiguration>"
            return Data(xml.utf8)
        }()

        do {
            try await RetryRunner.run(policy: retryPolicy, logger: Self.bucketsLogger) { _ in
                try Task.checkCancellation()

                let request = try Self.buildSignedBucketRequest(
                    method: "PUT",
                    bucket: name,
                    configuration: configuration,
                    body: body
                )

                try Task.checkCancellation()

                let transportBody: TransportBody? = body.map { .data($0) }
                let (responseBody, response) = try await transport.send(request, body: transportBody)

                try Task.checkCancellation()

                let status = response.statusCode
                guard (200..<300).contains(status) else {
                    throw BucketServiceError.decode(httpStatus: status, body: responseBody)
                }

                Self.bucketsLogger.debug(
                    "createBucket finish bucket=\(name, privacy: .public) status=\(status, privacy: .public)"
                )
            }
        } catch is CancellationError {
            throw BucketClientError.cancelled
        } catch let urlError as URLError {
            throw BucketClientError.transport(urlError)
        }
    }

    /// Deletes the bucket named `name`.
    ///
    /// Issues `DELETE` against the bucket root (path-style or
    /// virtual-hosted, picked from the configuration). Empty body,
    /// empty payload hash. Returns on 200/204; throws a typed
    /// ``BucketServiceError`` on any non-2xx — most commonly a
    /// `BucketNotEmpty` (409) when the caller forgot to clear the
    /// bucket first.
    ///
    /// - Parameter name: Bucket name to delete.
    public func deleteBucket(_ name: String) async throws {
        let configuration = self.configuration
        let transport = self.transport

        Self.bucketsLogger.debug("deleteBucket start bucket=\(name, privacy: .public)")

        do {
            try await RetryRunner.run(policy: retryPolicy, logger: Self.bucketsLogger) { _ in
                try Task.checkCancellation()

                let request = try Self.buildSignedBucketRequest(
                    method: "DELETE",
                    bucket: name,
                    configuration: configuration,
                    body: nil
                )

                try Task.checkCancellation()

                let (responseBody, response) = try await transport.send(request, body: nil)

                try Task.checkCancellation()

                let status = response.statusCode
                guard (200..<300).contains(status) else {
                    throw BucketServiceError.decode(httpStatus: status, body: responseBody)
                }

                Self.bucketsLogger.debug(
                    "deleteBucket finish bucket=\(name, privacy: .public) status=\(status, privacy: .public)"
                )
            }
        } catch is CancellationError {
            throw BucketClientError.cancelled
        } catch let urlError as URLError {
            throw BucketClientError.transport(urlError)
        }
    }

    /// Probes whether the configured credentials can reach the bucket
    /// `name`, and returns its region.
    ///
    /// Issues `HEAD` against the bucket root. On success returns a
    /// ``BucketMetadata`` whose ``BucketMetadata/region`` is taken
    /// from the `x-amz-bucket-region` response header (looked up
    /// case-insensitively). On 404 — the bucket does not exist or is
    /// not visible to the caller — throws
    /// ``BucketServiceError`` with ``BucketServiceError/httpStatus``
    /// set to `404` so callers can pattern-match by status without
    /// parsing a code.
    ///
    /// - Parameter name: Bucket name.
    /// - Returns: Region (and any future bucket-level metadata).
    public func headBucket(_ name: String) async throws -> BucketMetadata {
        let configuration = self.configuration
        let transport = self.transport

        Self.bucketsLogger.debug("headBucket start bucket=\(name, privacy: .public)")

        do {
            return try await RetryRunner.run(policy: retryPolicy, logger: Self.bucketsLogger) { _ in
                try Task.checkCancellation()

                let request = try Self.buildSignedBucketRequest(
                    method: "HEAD",
                    bucket: name,
                    configuration: configuration,
                    body: nil
                )

                try Task.checkCancellation()

                let (responseBody, response) = try await transport.send(request, body: nil)

                try Task.checkCancellation()

                let status = response.statusCode
                if status == 404 {
                    // Synthesize the typed error explicitly so the body
                    // (which is empty on a HEAD) does not matter — callers
                    // get a populated `httpStatus = 404` error to match on.
                    throw BucketServiceError.decode(httpStatus: 404, body: Data())
                }
                guard (200..<300).contains(status) else {
                    throw BucketServiceError.decode(httpStatus: status, body: responseBody)
                }

                let region = Self.firstHeader(named: "x-amz-bucket-region", in: response)

                Self.bucketsLogger.debug(
                    "headBucket finish bucket=\(name, privacy: .public) status=\(status, privacy: .public) region=\(region ?? "-", privacy: .public)"
                )
                return BucketMetadata(region: region)
            }
        } catch is CancellationError {
            throw BucketClientError.cancelled
        } catch let urlError as URLError {
            throw BucketClientError.transport(urlError)
        }
    }

    // MARK: - Internals

    private static let bucketsLogger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "client"
    )

    /// Builds the signed `URLRequest` for `GET /` against the service
    /// endpoint.
    ///
    /// `ListAllMyBuckets` is service-level: no bucket name appears in
    /// the URL at all. We use the configuration's endpoint host
    /// directly (without the bucket subdomain), with path `/`.
    private static func buildSignedListBucketsRequest(
        configuration: BucketConfiguration
    ) throws -> URLRequest {
        let url = try makeServiceRootURL(configuration: configuration)

        var headers: [String: String] = [:]
        configuration.mergeBaseHeaders(into: &headers)

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "GET",
                url: url,
                headers: headers,
                payloadHash: CanonicalRequest.emptyPayloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in signed.headers {
            // `Host` is set by URLSession itself from the URL; the
            // signer still includes it in the signed-headers list, so
            // omitting it here keeps URLSession from sending a
            // duplicate while leaving the signature valid.
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Builds a signed `URLRequest` for a bucket-level operation
    /// (PUT/DELETE/HEAD) against `bucket`'s root URL.
    ///
    /// When `body` is non-`nil`, signs with the SHA-256 hex of the
    /// body and sets `Content-Type: application/xml` — the only
    /// bucket-level body BucketKit emits today is the
    /// `CreateBucketConfiguration` document. Otherwise signs with the
    /// empty payload hash.
    private static func buildSignedBucketRequest(
        method: String,
        bucket: String,
        configuration: BucketConfiguration,
        body: Data?
    ) throws -> URLRequest {
        let url = try makeBucketRootURL(bucket: bucket, configuration: configuration)

        var headers: [String: String] = [:]
        let payloadHash: String
        if let body {
            payloadHash = CanonicalRequest.sha256Hex(body)
            headers["Content-Type"] = "application/xml"
            headers["Content-Length"] = String(body.count)
        } else {
            payloadHash = CanonicalRequest.emptyPayloadHash
        }

        configuration.mergeBaseHeaders(into: &headers)

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: method,
                url: url,
                headers: headers,
                payloadHash: payloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in signed.headers {
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Constructs the service-root URL used by `ListAllMyBuckets`.
    ///
    /// The bucket name is intentionally absent from both the path and
    /// the host: `ListAllMyBuckets` is service-level, so even on a
    /// virtual-hosted configuration we use the bare endpoint host.
    private static func makeServiceRootURL(
        configuration: BucketConfiguration
    ) throws -> URL {
        let endpoint = configuration.endpoint
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw BucketClientError.invalidConfiguration(
                "endpoint missing scheme or host: \(endpoint.absoluteString)"
            )
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = endpoint.port
        // Preserve any base path the endpoint carries (rare, but
        // allowed for custom gateways), then ensure we end at `/`.
        let basePath = endpoint.path.hasSuffix("/")
            ? String(endpoint.path.dropLast())
            : endpoint.path
        components.percentEncodedPath = basePath.isEmpty ? "/" : "\(basePath)/"

        guard let url = components.url else {
            throw BucketClientError.invalidConfiguration(
                "could not build service root URL from endpoint: \(endpoint.absoluteString)"
            )
        }
        return url
    }

    /// Constructs the bucket-root URL for create/delete/head, picking
    /// virtual-hosted vs path-style addressing from the configuration.
    ///
    /// - Path-style (MinIO, custom gateways): `{endpoint}/{bucket}`.
    /// - Virtual-hosted (AWS, R2, Spaces): `{scheme}://{bucket}.{host}/`.
    ///
    /// The bucket name is assumed to be DNS-valid; we pass it through
    /// without percent-encoding so the slash that separates it from
    /// any base path is preserved as a path separator.
    private static func makeBucketRootURL(
        bucket: String,
        configuration: BucketConfiguration
    ) throws -> URL {
        let endpoint = configuration.endpoint
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw BucketClientError.invalidConfiguration(
                "endpoint missing scheme or host: \(endpoint.absoluteString)"
            )
        }

        var components = URLComponents()
        components.scheme = scheme
        components.port = endpoint.port
        if configuration.usePathStyle {
            components.host = host
            let basePath = endpoint.path.hasSuffix("/")
                ? String(endpoint.path.dropLast())
                : endpoint.path
            components.percentEncodedPath = "\(basePath)/\(bucket)"
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/"
        }

        guard let url = components.url else {
            throw BucketClientError.invalidConfiguration(
                "could not build bucket root URL from endpoint: \(endpoint.absoluteString)"
            )
        }
        return url
    }

    /// Case-insensitive header lookup for `HTTPURLResponse`.
    ///
    /// `HTTPURLResponse.value(forHTTPHeaderField:)` is documented as
    /// case-insensitive on Apple platforms, but we walk
    /// `allHeaderFields` as a belt-and-suspenders fallback for
    /// providers (or test fakes) that do not normalize header casing.
    private static func firstHeader(
        named name: String,
        in response: HTTPURLResponse
    ) -> String? {
        if let direct = response.value(forHTTPHeaderField: name) {
            return direct
        }
        let target = name.lowercased()
        for (rawName, rawValue) in response.allHeaderFields {
            guard let headerName = rawName as? String,
                  let headerValue = rawValue as? String else { continue }
            if headerName.lowercased() == target {
                return headerValue
            }
        }
        return nil
    }
}

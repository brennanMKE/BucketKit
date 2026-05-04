import Foundation
import os

extension BucketClient {
    /// Deletes an object at the key the supplied path resolves to.
    ///
    /// Issues a `DELETE` against `bucket`/`key`. When
    /// ``RemoveOptions/versionID`` is supplied, the request targets a
    /// specific version via `?versionId={value}`; otherwise the
    /// current version is deleted (versioned buckets receive a delete
    /// marker, unversioned buckets remove the object outright).
    ///
    /// On success (HTTP 204 No Content or 200) the resolved key is
    /// returned so callers can correlate the delete with the path
    /// they passed in. On any non-2xx the placeholder error is
    /// thrown today; #0015 will replace it with a typed
    /// ``BucketServiceError``.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - options: Optional version targeting. See ``RemoveOptions``.
    /// - Returns: The resolved object key.
    public func remove(
        bucket: String,
        path: any BucketPath,
        options: RemoveOptions = .init()
    ) async throws -> String {
        try Task.checkCancellation()

        let key = path.resolve()
        Self.removeLogger.debug("remove start key=\(key, privacy: .public) versionID=\(options.versionID ?? "-", privacy: .public)")

        let request = try Self.buildSignedDeleteRequest(
            bucket: bucket,
            key: key,
            configuration: configuration,
            versionID: options.versionID
        )

        try Task.checkCancellation()

        let (responseBody, response) = try await transport.send(request, body: nil)

        try Task.checkCancellation()

        let status = response.statusCode
        guard status == 204 || status == 200 else {
            // TODO: replace with BucketServiceError after #0015.
            throw RemoveError.badStatus(status: status, body: responseBody)
        }

        Self.removeLogger.debug("remove finish key=\(key, privacy: .public) status=\(status, privacy: .public)")
        return key
    }

    /// Fetches metadata for an object without transferring the body.
    ///
    /// Issues a `HEAD` against `bucket`/`key` and parses the response
    /// headers into an ``ObjectMetadata`` value. On any non-2xx the
    /// placeholder error is thrown — note that S3's HEAD responses
    /// have an empty body even on errors (no XML error document), so
    /// the typed mapping in #0015 will rely on the status code and
    /// `x-amz-request-id` rather than parsed XML.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Object key, supplied as a ``BucketPath``.
    /// - Returns: Parsed object metadata.
    public func headObject(
        bucket: String,
        path: any BucketPath
    ) async throws -> ObjectMetadata {
        try Task.checkCancellation()

        let key = path.resolve()
        Self.removeLogger.debug("headObject start key=\(key, privacy: .public)")

        let request = try Self.buildSignedHeadRequest(
            bucket: bucket,
            key: key,
            configuration: configuration
        )

        try Task.checkCancellation()

        let (responseBody, response) = try await transport.send(request, body: nil)

        try Task.checkCancellation()

        let status = response.statusCode
        guard (200..<300).contains(status) else {
            // TODO: replace with BucketServiceError after #0015. HEAD
            // responses have no XML body so the typed mapping will
            // rely on status + headers.
            throw RemoveError.badStatus(status: status, body: responseBody)
        }

        let metadata = Self.makeObjectMetadata(key: key, response: response)
        Self.removeLogger.debug("headObject finish key=\(key, privacy: .public) status=\(status, privacy: .public)")
        return metadata
    }

    // MARK: - Internals

    private static let removeLogger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "client"
    )

    /// Builds the signed `URLRequest` for a `DELETE` against
    /// `bucket`/`key`.
    ///
    /// When a version ID is supplied it is added to the URL's query
    /// string before signing — `URLComponents` (and the signer that
    /// reads from it) handles canonicalization, so the parameter
    /// participates correctly in the SigV4 canonical query string.
    private static func buildSignedDeleteRequest(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        versionID: String?
    ) throws -> URLRequest {
        let url = try makeRemoveObjectURL(
            bucket: bucket,
            key: key,
            configuration: configuration,
            versionID: versionID
        )

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "DELETE",
                url: url,
                headers: [:],
                payloadHash: CanonicalRequest.emptyPayloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
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

    /// Builds the signed `URLRequest` for a `HEAD` against
    /// `bucket`/`key`.
    private static func buildSignedHeadRequest(
        bucket: String,
        key: String,
        configuration: BucketConfiguration
    ) throws -> URLRequest {
        let url = try makeRemoveObjectURL(
            bucket: bucket,
            key: key,
            configuration: configuration,
            versionID: nil
        )

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "HEAD",
                url: url,
                headers: [:],
                payloadHash: CanonicalRequest.emptyPayloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        for (name, value) in signed.headers {
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Constructs the absolute URL for a remove/head operation,
    /// picking virtual-hosted vs path-style addressing from the
    /// configuration and SigV4-encoding the key one segment at a
    /// time.
    ///
    /// Duplicated from ``Upload`` and ``Download`` for now — the
    /// builders are nearly identical, but factoring a shared helper
    /// risks subtle changes to the signing path. The builders can be
    /// unified once the operation surface settles.
    private static func makeRemoveObjectURL(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        versionID: String?
    ) throws -> URL {
        let endpoint = configuration.endpoint
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw RemoveError.invalidEndpoint(endpoint)
        }

        // Encode the key as a sequence of `/`-separated segments so
        // each segment is RFC-3986 percent-encoded (matching the
        // canonical-URI rules in CanonicalRequest), but the slashes
        // between segments are preserved as path separators.
        let encodedKey = key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { sigv4PercentEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")

        var components = URLComponents()
        components.scheme = scheme
        components.port = endpoint.port
        if configuration.usePathStyle {
            components.host = host
            // Endpoint may carry a base path (rare, but allowed for
            // custom gateways); preserve it in front of bucket/key.
            let basePath = endpoint.path.hasSuffix("/")
                ? String(endpoint.path.dropLast())
                : endpoint.path
            components.percentEncodedPath = "\(basePath)/\(bucket)/\(encodedKey)"
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/\(encodedKey)"
        }

        if let versionID {
            // Use `queryItems` (rather than `percentEncodedQueryItems`)
            // so URLComponents handles encoding for us. The signer
            // re-encodes under SigV4 rules anyway, so we just need
            // round-trippable items here.
            components.queryItems = [URLQueryItem(name: "versionId", value: versionID)]
        }

        guard let url = components.url else {
            throw RemoveError.invalidEndpoint(endpoint)
        }
        return url
    }

    /// Parses the headers of a successful `HEAD` response into an
    /// ``ObjectMetadata`` value. Missing or unparseable optional
    /// headers fall back to `nil` (or `Date.distantPast` for
    /// `Last-Modified`); we never throw out of header parsing.
    private static func makeObjectMetadata(
        key: String,
        response: HTTPURLResponse
    ) -> ObjectMetadata {
        let size: Int64 = {
            guard let raw = response.value(forHTTPHeaderField: "Content-Length"),
                  let value = Int64(raw) else { return 0 }
            return value
        }()

        let eTag: String = {
            let raw = response.value(forHTTPHeaderField: "ETag")
                ?? response.value(forHTTPHeaderField: "Etag")
                ?? ""
            var v = raw
            if v.hasPrefix("\"") { v.removeFirst() }
            if v.hasSuffix("\"") { v.removeLast() }
            return v
        }()

        let lastModified: Date = {
            guard let raw = response.value(forHTTPHeaderField: "Last-Modified"),
                  let parsed = httpDateFormatter.date(from: raw) else {
                return Date.distantPast
            }
            return parsed
        }()

        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let cacheControl = response.value(forHTTPHeaderField: "Cache-Control")

        // Walk every response header looking for `x-amz-meta-*`.
        // `allHeaderFields` keys are technically `AnyHashable`; we
        // tolerate non-String keys by skipping them.
        var userMetadata: [String: String] = [:]
        let metaPrefix = "x-amz-meta-"
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String,
                  let value = rawValue as? String else { continue }
            let lower = name.lowercased()
            if lower.hasPrefix(metaPrefix) {
                let stripped = String(lower.dropFirst(metaPrefix.count))
                userMetadata[stripped] = value
            }
        }

        let storageClass: StorageClass? = {
            guard let raw = response.value(forHTTPHeaderField: "x-amz-storage-class") else {
                return nil
            }
            return StorageClass(rawValue: raw)
        }()

        let versionID = response.value(forHTTPHeaderField: "x-amz-version-id")

        return ObjectMetadata(
            key: key,
            size: size,
            eTag: eTag,
            lastModified: lastModified,
            contentType: contentType,
            cacheControl: cacheControl,
            metadata: userMetadata,
            storageClass: storageClass,
            versionID: versionID
        )
    }

    /// Cached RFC 7231 / RFC 1123 parser for `Last-Modified`. Pinned
    /// to `en_US_POSIX` and UTC so locale-dependent month/day names
    /// and timezone abbreviations resolve consistently.
    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}

// TODO: replace with BucketServiceError after #0015.
fileprivate struct RemoveError: Error {
    let status: Int
    let body: Data

    static func badStatus(status: Int, body: Data) -> RemoveError {
        RemoveError(status: status, body: body)
    }

    static func invalidEndpoint(_ url: URL) -> RemoveError {
        RemoveError(status: -1, body: Data(url.absoluteString.utf8))
    }
}

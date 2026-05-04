import Foundation
import CryptoKit
import os

// MARK: - MultipartUpload actor

/// In-progress S3 multipart upload.
///
/// Construct one via
/// ``BucketClient/multipartUpload(bucket:path:options:)``; this issues
/// `CreateMultipartUpload` against the service and returns the actor
/// already bound to the resulting `UploadId`.
///
/// From there, callers drive parts in any order — including in
/// parallel — via ``uploadPart(_:partNumber:)`` (in-memory `Data`) or
/// ``uploadPart(fileURL:partNumber:)`` (file-backed). When all parts
/// have been uploaded, calling ``complete()`` issues
/// `CompleteMultipartUpload` with the accumulated part list and
/// returns an ``UploadResult``. Callers that want to throw away the
/// in-progress upload call ``abort()``.
///
/// **Cancellation:** structured task cancellation around an awaiting
/// part upload aborts that one HTTP request, but it does **not** call
/// ``abort()`` automatically. The actor's lifecycle is the caller's
/// responsibility — typical patterns wrap the whole upload in a
/// `do/catch` and call ``abort()`` from the failure path. The
/// auto-switching path inside
/// ``BucketClient/uploadFile(bucket:path:local:options:)`` does this
/// for you.
///
/// **Part-size floor:** S3 rejects any non-final part smaller than 5
/// MiB. The explicit `MultipartUpload` actor does **not** enforce
/// this on each call to `uploadPart` because at upload time we cannot
/// know which part will be the last; it is the caller's
/// responsibility. The auto-switching path in `uploadFile` enforces
/// the floor itself when slicing the file into parts.
public actor MultipartUpload {

    private static let logger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "multipart"
    )

    /// Bucket the upload targets.
    public nonisolated let bucket: String

    /// Resolved object key the upload targets.
    public nonisolated let key: String

    /// `UploadId` returned by `CreateMultipartUpload`. Treat this as
    /// opaque — never log it at `.info` and do not surface it in URLs
    /// or user-facing strings.
    public nonisolated let uploadID: String

    /// Configuration captured at construction so the actor can sign
    /// its own requests without hopping back to the parent client.
    private let configuration: BucketConfiguration

    /// Transport seam captured at construction.
    private let transport: any HTTPTransport

    /// Header bag derived from ``UploadDataOptions`` and applied only
    /// to the InitiateMultipartUpload request — UploadPart requests
    /// carry just `Content-Length` (and the per-part SHA-256 hash via
    /// the signer).
    private let initiateOptions: UploadDataOptions

    /// Parts the actor has observed completing so far. Order is
    /// arbitrary; ``complete()`` sorts by ``UploadedPart/partNumber``
    /// before serializing the request body.
    private var parts: [UploadedPart] = []

    /// Internal initializer — callers go through
    /// ``BucketClient/multipartUpload(bucket:path:options:)`` so the
    /// `CreateMultipartUpload` round-trip happens before we hand back
    /// a usable actor.
    init(
        configuration: BucketConfiguration,
        transport: any HTTPTransport,
        bucket: String,
        key: String,
        uploadID: String,
        options: UploadDataOptions
    ) {
        self.configuration = configuration
        self.transport = transport
        self.bucket = bucket
        self.key = key
        self.uploadID = uploadID
        self.initiateOptions = options
    }

    // MARK: - Uploading parts

    /// Uploads `data` as the part identified by `partNumber`.
    ///
    /// `partNumber` must be in `1...10_000`. The 5 MiB floor that S3
    /// enforces on every part except the last is **not** validated
    /// here — see the type-level note on
    /// ``MultipartUpload``. The part bytes are SHA-256 hashed to feed
    /// SigV4 payload signing and uploaded synchronously; on success
    /// the returned ``UploadedPart`` is also stored internally so a
    /// later ``complete()`` can assemble the final request without
    /// the caller having to thread it through.
    public func uploadPart(_ data: Data, partNumber: Int) async throws -> UploadedPart {
        try Self.validatePartNumber(partNumber)

        let payloadHash = CanonicalRequest.sha256Hex(data)
        let request = try Self.buildSignedUploadPartRequest(
            bucket: bucket,
            key: key,
            uploadID: uploadID,
            partNumber: partNumber,
            payloadHash: payloadHash,
            contentLength: data.count,
            configuration: configuration
        )

        let (responseBody, response) = try await transport.send(request, body: .data(data))
        let part = try Self.makeUploadedPart(
            partNumber: partNumber,
            response: response,
            body: responseBody
        )
        parts.append(part)
        Self.logger.debug(
            "uploadPart-completed key=\(self.key, privacy: .public) partNumber=\(partNumber, privacy: .public) status=\(response.statusCode, privacy: .public)"
        )
        return part
    }

    /// Uploads the contents of `fileURL` as the part identified by
    /// `partNumber`.
    ///
    /// Streams from disk via `HTTPTransport.upload(_:fromFile:)` so
    /// the part bytes are not materialized in memory. Because the
    /// stream means we cannot pre-hash the body, the request is
    /// signed with `UNSIGNED-PAYLOAD` — exactly the same trade-off
    /// the single-part `uploadFile` path makes.
    public func uploadPart(fileURL: URL, partNumber: Int) async throws -> UploadedPart {
        try Self.validatePartNumber(partNumber)

        let contentLength: Int? = {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            return size
        }()

        let request = try Self.buildSignedUploadPartRequest(
            bucket: bucket,
            key: key,
            uploadID: uploadID,
            partNumber: partNumber,
            payloadHash: CanonicalRequest.unsignedPayload,
            contentLength: contentLength,
            configuration: configuration
        )

        let (responseBody, response) = try await transport.upload(request, fromFile: fileURL)
        let part = try Self.makeUploadedPart(
            partNumber: partNumber,
            response: response,
            body: responseBody
        )
        parts.append(part)
        Self.logger.debug(
            "uploadPart-completed key=\(self.key, privacy: .public) partNumber=\(partNumber, privacy: .public) status=\(response.statusCode, privacy: .public)"
        )
        return part
    }

    // MARK: - Lifecycle

    /// Issues `CompleteMultipartUpload` and returns the final
    /// ``UploadResult``.
    ///
    /// Parts are sorted by ``UploadedPart/partNumber`` before being
    /// serialized into the request body. The body itself is small
    /// XML hashed in-line for SigV4 signing.
    public func complete() async throws -> UploadResult {
        let sorted = parts.sorted { $0.partNumber < $1.partNumber }
        let body = Self.makeCompleteMultipartBody(parts: sorted)

        let request = try Self.buildSignedCompleteRequest(
            bucket: bucket,
            key: key,
            uploadID: uploadID,
            body: body,
            configuration: configuration
        )

        let (responseBody, response) = try await transport.send(request, body: .data(body))
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw BucketServiceError.decode(httpStatus: status, body: responseBody)
        }

        let decoded: CompleteMultipartUploadResult
        do {
            decoded = try XMLDecoder.decode(CompleteMultipartUploadResult.self, from: responseBody)
        } catch {
            throw BucketClientError.decodingFailed(String(describing: error))
        }

        // Strip the surrounding quotes S3 wraps around the ETag in
        // its XML response so the public ``UploadResult`` matches
        // the convention used elsewhere in the package.
        let trimmed: String = {
            var v = decoded.eTag
            if v.hasPrefix("\"") { v.removeFirst() }
            if v.hasSuffix("\"") { v.removeLast() }
            return v
        }()

        Self.logger.debug(
            "complete key=\(self.key, privacy: .public) status=\(status, privacy: .public) parts=\(sorted.count, privacy: .public)"
        )

        return UploadResult(
            key: decoded.key,
            eTag: trimmed,
            versionID: decoded.versionID
        )
    }

    /// Issues `AbortMultipartUpload`. Best effort — any error from
    /// the network or the service is logged and **not** propagated.
    /// Idempotent in practice: aborting an already-aborted upload
    /// returns 404 from S3 and is treated as success.
    public func abort() async throws {
        do {
            let request = try Self.buildSignedAbortRequest(
                bucket: bucket,
                key: key,
                uploadID: uploadID,
                configuration: configuration
            )
            let (_, response) = try await transport.send(request, body: nil)
            Self.logger.debug(
                "abort key=\(self.key, privacy: .public) status=\(response.statusCode, privacy: .public)"
            )
        } catch {
            // Best effort: cleanup failures are common (already
            // aborted, network gone, etc.). Log and swallow so
            // callers chaining `try? await abort()` after another
            // failure don't lose the original error.
            Self.logger.debug(
                "abort failed key=\(self.key, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Internal helpers (request building)

    /// Reads the per-part `ETag` header from `response` and builds an
    /// ``UploadedPart``. Throws a ``BucketServiceError`` on non-2xx.
    fileprivate static func makeUploadedPart(
        partNumber: Int,
        response: HTTPURLResponse,
        body: Data
    ) throws -> UploadedPart {
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw BucketServiceError.decode(httpStatus: status, body: body)
        }
        let raw = response.value(forHTTPHeaderField: "ETag")
            ?? response.value(forHTTPHeaderField: "Etag")
            ?? ""
        var trimmed = raw
        if trimmed.hasPrefix("\"") { trimmed.removeFirst() }
        if trimmed.hasSuffix("\"") { trimmed.removeLast() }
        return UploadedPart(partNumber: partNumber, eTag: trimmed)
    }

    fileprivate static func validatePartNumber(_ partNumber: Int) throws {
        guard (1...10_000).contains(partNumber) else {
            throw BucketClientError.multipartPartTooSmall(
                partNumber: partNumber,
                size: 0
            )
        }
    }

    /// Renders the `CompleteMultipartUpload` request body. ETags are
    /// re-quoted because S3 expects them quoted in this document
    /// even though we strip quotes when storing them on
    /// ``UploadedPart``.
    fileprivate static func makeCompleteMultipartBody(parts: [UploadedPart]) -> Data {
        var xml = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for part in parts {
            xml += "<Part><ETag>\"\(part.eTag)\"</ETag><PartNumber>\(part.partNumber)</PartNumber></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    fileprivate static func buildSignedUploadPartRequest(
        bucket: String,
        key: String,
        uploadID: String,
        partNumber: Int,
        payloadHash: String,
        contentLength: Int?,
        configuration: BucketConfiguration
    ) throws -> URLRequest {
        let url = try MultipartURL.objectURL(
            bucket: bucket,
            key: key,
            configuration: configuration,
            queryItems: [
                URLQueryItem(name: "partNumber", value: String(partNumber)),
                URLQueryItem(name: "uploadId", value: uploadID),
            ]
        )

        var headers: [String: String] = [:]
        if let contentLength {
            headers["Content-Length"] = String(contentLength)
        }

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "PUT",
                url: url,
                headers: headers,
                payloadHash: payloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (name, value) in signed.headers {
            // `Host` is set by URLSession; the signer still includes
            // it in the signed-headers list so its value participates
            // in the signature, but we do not re-set it on the
            // outgoing request.
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    fileprivate static func buildSignedCompleteRequest(
        bucket: String,
        key: String,
        uploadID: String,
        body: Data,
        configuration: BucketConfiguration
    ) throws -> URLRequest {
        let url = try MultipartURL.objectURL(
            bucket: bucket,
            key: key,
            configuration: configuration,
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)]
        )

        var headers: [String: String] = [:]
        headers["Content-Type"] = "application/xml"
        headers["Content-Length"] = String(body.count)

        let payloadHash = CanonicalRequest.sha256Hex(body)
        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "POST",
                url: url,
                headers: headers,
                payloadHash: payloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in signed.headers {
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    fileprivate static func buildSignedAbortRequest(
        bucket: String,
        key: String,
        uploadID: String,
        configuration: BucketConfiguration
    ) throws -> URLRequest {
        let url = try MultipartURL.objectURL(
            bucket: bucket,
            key: key,
            configuration: configuration,
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)]
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
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

// MARK: - Initiate helper (shared with Upload.swift auto path)

/// Internal helpers shared between `BucketClient.multipartUpload(...)`
/// and the auto-switching path in
/// `BucketClient.uploadFile(...)`. Both need to issue the same
/// `CreateMultipartUpload` request and parse the same response.
enum MultipartInitiator {

    private static let logger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "multipart"
    )

    /// Issues `POST /<key>?uploads`, decodes the response, and returns
    /// the `UploadId`.
    static func initiate(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        transport: any HTTPTransport,
        options: UploadDataOptions
    ) async throws -> String {
        let request = try buildSignedInitiateRequest(
            bucket: bucket,
            key: key,
            configuration: configuration,
            options: options
        )

        let (responseBody, response) = try await transport.send(request, body: nil)
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw BucketServiceError.decode(httpStatus: status, body: responseBody)
        }

        let decoded: InitiateMultipartUploadResult
        do {
            decoded = try XMLDecoder.decode(InitiateMultipartUploadResult.self, from: responseBody)
        } catch {
            throw BucketClientError.decodingFailed(String(describing: error))
        }

        Self.logger.debug(
            "initiate key=\(key, privacy: .public) status=\(status, privacy: .public)"
        )
        return decoded.uploadID
    }

    /// Builds the signed `URLRequest` for `POST /<key>?uploads`. The
    /// body is empty (signed with the empty payload hash); the
    /// optional headers from ``UploadDataOptions`` apply here exactly
    /// the way they would on a regular PUT — the part requests
    /// themselves carry no metadata headers.
    private static func buildSignedInitiateRequest(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        options: UploadDataOptions
    ) throws -> URLRequest {
        let url = try MultipartURL.objectURL(
            bucket: bucket,
            key: key,
            configuration: configuration,
            queryItems: [URLQueryItem(name: "uploads", value: nil)]
        )

        var headers: [String: String] = [:]
        headers["Content-Type"] = options.contentType ?? "application/octet-stream"
        if let cacheControl = options.cacheControl {
            headers["Cache-Control"] = cacheControl
        }
        for (rawName, value) in options.metadata {
            // Lowercased on the wire so the canonical request
            // matches regardless of caller capitalization.
            headers["x-amz-meta-\(rawName.lowercased())"] = value
        }
        if let acl = options.acl {
            headers["x-amz-acl"] = acl.rawValue
        }
        if let storageClass = options.storageClass {
            headers["x-amz-storage-class"] = storageClass.rawValue
        }
        if let ifNoneMatch = options.ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        // ServerSideEncryption header translation lands with #0020;
        // initiate requests will pick it up automatically once the
        // helper exists.
        _ = options.serverSideEncryption

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "POST",
                url: url,
                headers: headers,
                payloadHash: CanonicalRequest.emptyPayloadHash
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Ensure POST body is empty even if URLSession would otherwise
        // try to populate one from a stale field.
        request.httpBody = nil
        for (name, value) in signed.headers {
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

// MARK: - URL builder shared by every multipart request

/// URL building for the four multipart wire calls. Mirrors
/// `Upload.makeObjectURL(...)` but accepts arbitrary query items so
/// callers can add `?uploads`, `?partNumber=N&uploadId=ID`, or
/// `?uploadId=ID` without re-implementing the addressing logic.
enum MultipartURL {

    static func objectURL(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let endpoint = configuration.endpoint
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw BucketClientError.invalidConfiguration(
                "endpoint missing scheme or host: \(endpoint.absoluteString)"
            )
        }

        // Encode the key as a sequence of `/`-separated segments so
        // each segment is RFC-3986 percent-encoded but the slashes
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
            let basePath = endpoint.path.hasSuffix("/")
                ? String(endpoint.path.dropLast())
                : endpoint.path
            components.percentEncodedPath = "\(basePath)/\(bucket)/\(encodedKey)"
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/\(encodedKey)"
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw BucketClientError.invalidConfiguration(
                "could not build object URL from endpoint: \(endpoint.absoluteString)"
            )
        }
        return url
    }
}

// MARK: - BucketClient surface

extension BucketClient {

    /// Begins an explicit multipart upload.
    ///
    /// Issues `CreateMultipartUpload` against the resolved key,
    /// returning a ``MultipartUpload`` actor already bound to the
    /// resulting `UploadId`. Headers from ``UploadDataOptions`` (MIME
    /// type, cache control, metadata, ACL, storage class,
    /// `If-None-Match`) apply to the underlying object — the part
    /// requests themselves do not carry metadata.
    ///
    /// Cancellation of the actor's lifecycle is the caller's
    /// responsibility — see ``MultipartUpload`` for the rationale.
    /// For automatic multipart with progress + best-effort abort on
    /// cancellation, use
    /// ``BucketClient/uploadFile(bucket:path:local:options:)``
    /// instead.
    public func multipartUpload(
        bucket: String,
        path: any BucketPath,
        options: UploadDataOptions = .init()
    ) async throws -> MultipartUpload {
        let key = path.resolve()
        let uploadID = try await MultipartInitiator.initiate(
            bucket: bucket,
            key: key,
            configuration: configuration,
            transport: transport,
            options: options
        )
        return MultipartUpload(
            configuration: configuration,
            transport: transport,
            bucket: bucket,
            key: key,
            uploadID: uploadID,
            options: options
        )
    }
}

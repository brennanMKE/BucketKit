import Foundation
import CryptoKit
import os

extension BucketClient {
    /// Uploads an in-memory `Data` payload to `bucket` at the key the
    /// supplied path resolves to.
    ///
    /// Returns a ``BucketUploadDataTask`` immediately; the actual PUT
    /// runs on a child `Task`. Callers can either `await task.value`
    /// for the final ``UploadResult`` or iterate
    /// ``BucketUploadDataTask/progress`` for byte-count snapshots.
    /// Today progress is coarse (start, finish) — byte-level updates
    /// require a `URLSessionTaskDelegate` we haven't wired yet.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name. Combined with the configuration's
    ///     endpoint and `usePathStyle` flag to form the request URL.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - data: Bytes to upload. Hashed with SHA-256 for SigV4
    ///     payload signing.
    ///   - options: Optional metadata, cache control, ACL, storage
    ///     class, conditional headers, etc. See
    ///     ``UploadDataOptions``.
    public func uploadData(
        bucket: String,
        path: any BucketPath,
        data: Data,
        options: UploadDataOptions = .init()
    ) -> BucketUploadDataTask {
        let (task, state) = BucketUploadDataTask.make()

        let configuration = self.configuration
        let transport = self.transport
        let key = path.resolve()
        let totalBytes = Int64(data.count)

        // Run the upload on a child Task so the public API stays
        // synchronous (returns the task value immediately) while the
        // actual network work runs in the background.
        let work = Task {
            do {
                try Task.checkCancellation()

                Self.logger.debug("uploadData start key=\(key, privacy: .public) bytes=\(totalBytes, privacy: .public)")
                await state.yieldProgress(
                    TransferProgress(totalBytes: totalBytes, bytesTransferred: 0)
                )

                let payloadHash = CanonicalRequest.sha256Hex(data)
                let request = try Self.buildSignedPutRequest(
                    bucket: bucket,
                    key: key,
                    configuration: configuration,
                    payloadHash: payloadHash,
                    contentLength: data.count,
                    contentType: options.contentType,
                    cacheControl: options.cacheControl,
                    metadata: options.metadata,
                    acl: options.acl,
                    storageClass: options.storageClass,
                    serverSideEncryption: options.serverSideEncryption,
                    ifNoneMatch: options.ifNoneMatch
                )

                try Task.checkCancellation()

                // TODO: byte-level progress via URLSessionTaskDelegate.
                let (responseBody, response) = try await transport.send(request, body: .data(data))

                try Task.checkCancellation()

                let result = try Self.makeUploadResult(
                    key: key,
                    response: response,
                    body: responseBody
                )

                await state.yieldProgress(
                    TransferProgress(totalBytes: totalBytes, bytesTransferred: totalBytes)
                )
                await state.finish(with: result)
                Self.logger.debug("uploadData finish key=\(key, privacy: .public) status=\(response.statusCode, privacy: .public)")
            } catch is CancellationError {
                await state.cancel()
            } catch {
                await state.fail(with: error)
            }
        }

        // Wire structured cancellation: if the parent task is
        // cancelled, propagate to the work task so its
        // `Task.checkCancellation()` calls fire and the operation
        // tears down cleanly.
        Task {
            await withTaskCancellationHandler {
                _ = await work.value
            } onCancel: {
                work.cancel()
            }
        }

        return task
    }

    /// Uploads the contents of a local file to `bucket` at the key
    /// the supplied path resolves to.
    ///
    /// Today this always uses a single-part PUT with
    /// `x-amz-content-sha256: UNSIGNED-PAYLOAD` so the file does not
    /// have to be read twice (once to hash, once to upload).
    /// Automatic multipart switching for large files arrives in
    /// #0019.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - local: File on disk to upload. Must be readable by the
    ///     process. Streamed via `URLSession.upload(for:fromFile:)`.
    ///   - options: Optional metadata, cache control, ACL, etc. See
    ///     ``UploadFileOptions``.
    public func uploadFile(
        bucket: String,
        path: any BucketPath,
        local: URL,
        options: UploadFileOptions = .init()
    ) -> BucketUploadFileTask {
        // TODO: switch to multipart above options.partSize / 100 MiB threshold (#0019)
        let (task, state) = BucketUploadFileTask.make()

        let configuration = self.configuration
        let transport = self.transport
        let key = path.resolve()

        let work = Task {
            do {
                try Task.checkCancellation()

                let totalBytes = Self.fileSize(at: local)

                Self.logger.debug("uploadFile start key=\(key, privacy: .public) bytes=\(totalBytes ?? -1, privacy: .public)")
                await state.yieldProgress(
                    TransferProgress(totalBytes: totalBytes, bytesTransferred: 0)
                )

                let request = try Self.buildSignedPutRequest(
                    bucket: bucket,
                    key: key,
                    configuration: configuration,
                    payloadHash: CanonicalRequest.unsignedPayload,
                    contentLength: totalBytes.map(Int.init),
                    contentType: options.contentType,
                    cacheControl: options.cacheControl,
                    metadata: options.metadata,
                    acl: options.acl,
                    storageClass: options.storageClass,
                    serverSideEncryption: options.serverSideEncryption,
                    ifNoneMatch: options.ifNoneMatch
                )

                try Task.checkCancellation()

                // TODO: byte-level progress via URLSessionTaskDelegate.
                let (responseBody, response) = try await transport.upload(request, fromFile: local)

                try Task.checkCancellation()

                let result = try Self.makeUploadResult(
                    key: key,
                    response: response,
                    body: responseBody
                )

                await state.yieldProgress(
                    TransferProgress(
                        totalBytes: totalBytes,
                        bytesTransferred: totalBytes ?? 0
                    )
                )
                await state.finish(with: result)
                Self.logger.debug("uploadFile finish key=\(key, privacy: .public) status=\(response.statusCode, privacy: .public)")
            } catch is CancellationError {
                await state.cancel()
            } catch {
                await state.fail(with: error)
            }
        }

        Task {
            await withTaskCancellationHandler {
                _ = await work.value
            } onCancel: {
                work.cancel()
            }
        }

        return task
    }

    // MARK: - Internals

    private static let logger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "client"
    )

    /// Builds the signed `URLRequest` for a `PUT` against `bucket`/`key`.
    ///
    /// Handles URL construction (virtual-hosted vs path-style),
    /// SigV4-correct path encoding (per-segment), header translation
    /// from the options struct, and SigV4 signing. Returns a request
    /// whose `httpBody` is `nil` — callers attach the body separately
    /// via the transport (`.data` or `fromFile:`) so the same builder
    /// works for both data and file uploads.
    private static func buildSignedPutRequest(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        payloadHash: String,
        contentLength: Int?,
        contentType: String?,
        cacheControl: String?,
        metadata: [String: String],
        acl: ObjectACL?,
        storageClass: StorageClass?,
        serverSideEncryption: ServerSideEncryption?,
        ifNoneMatch: String?
    ) throws -> URLRequest {
        let url = try makeObjectURL(
            bucket: bucket,
            key: key,
            configuration: configuration
        )

        var headers: [String: String] = [:]
        headers["Content-Type"] = contentType ?? "application/octet-stream"
        if let contentLength {
            headers["Content-Length"] = String(contentLength)
        }
        if let cacheControl {
            headers["Cache-Control"] = cacheControl
        }
        for (rawName, value) in metadata {
            // S3 user-metadata header names are case-insensitive on
            // the wire; lowercasing makes the canonical request
            // deterministic regardless of caller capitalization.
            headers["x-amz-meta-\(rawName.lowercased())"] = value
        }
        if let acl {
            headers["x-amz-acl"] = acl.rawValue
        }
        if let storageClass {
            headers["x-amz-storage-class"] = storageClass.rawValue
        }
        if let ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        if serverSideEncryption != nil {
            // TODO: translate ServerSideEncryption into
            // x-amz-server-side-encryption* headers in #0020.
            _ = serverSideEncryption
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
            // `Host` is set by URLSession itself from the URL; the
            // signer still includes it in the signed-headers list, so
            // omitting it here keeps URLSession from sending a
            // duplicate while leaving the signature valid.
            if name.lowercased() == "host" { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Constructs the absolute URL for an object operation, picking
    /// virtual-hosted vs path-style addressing from the configuration
    /// and SigV4-encoding the key one segment at a time.
    private static func makeObjectURL(
        bucket: String,
        key: String,
        configuration: BucketConfiguration
    ) throws -> URL {
        let endpoint = configuration.endpoint
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw UploadError.invalidEndpoint(endpoint)
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

        guard let url = components.url else {
            throw UploadError.invalidEndpoint(endpoint)
        }
        return url
    }

    /// Builds the public ``UploadResult`` from a successful HTTP
    /// response. Throws ``UploadError/badStatus`` on non-2xx.
    private static func makeUploadResult(
        key: String,
        response: HTTPURLResponse,
        body: Data
    ) throws -> UploadResult {
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            // TODO: replace with BucketServiceError after #0015.
            throw UploadError.badStatus(status: status, body: body)
        }
        let rawETag = (response.value(forHTTPHeaderField: "ETag")
            ?? response.value(forHTTPHeaderField: "Etag")
            ?? "")
        let trimmed: String = {
            var v = rawETag
            if v.hasPrefix("\"") { v.removeFirst() }
            if v.hasSuffix("\"") { v.removeLast() }
            return v
        }()
        let versionID = response.value(forHTTPHeaderField: "x-amz-version-id")
        return UploadResult(key: key, eTag: trimmed, versionID: versionID)
    }

    /// Best-effort byte size lookup for a local file, used purely for
    /// progress reporting. Returns `nil` if the size can't be read,
    /// which surfaces as `totalBytes == nil` on the progress event.
    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }
}

// TODO: replace with BucketServiceError after #0015.
fileprivate struct UploadError: Error {
    let status: Int
    let body: Data

    static func badStatus(status: Int, body: Data) -> UploadError {
        UploadError(status: status, body: body)
    }

    static func invalidEndpoint(_ url: URL) -> UploadError {
        UploadError(status: -1, body: Data(url.absoluteString.utf8))
    }
}

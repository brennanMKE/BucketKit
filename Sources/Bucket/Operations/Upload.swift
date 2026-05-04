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
        let retryPolicy = self.retryPolicy
        let key = path.resolve()
        let totalBytes = Int64(data.count)
        let capturedOptions = options

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

                // S3 PUT is idempotent at the bucket/key level even
                // though HTTP semantics say otherwise, so retrying a
                // duplicate PUT is safe — it produces the same final
                // object. Re-sign on every attempt.
                let result = try await RetryRunner.run(
                    policy: retryPolicy,
                    logger: Self.logger
                ) { _ -> UploadResult in
                    try Task.checkCancellation()

                    let request = try Self.buildSignedPutRequest(
                        bucket: bucket,
                        key: key,
                        configuration: configuration,
                        payloadHash: payloadHash,
                        contentLength: data.count,
                        contentType: capturedOptions.contentType,
                        cacheControl: capturedOptions.cacheControl,
                        metadata: capturedOptions.metadata,
                        acl: capturedOptions.acl,
                        storageClass: capturedOptions.storageClass,
                        serverSideEncryption: capturedOptions.serverSideEncryption,
                        ifNoneMatch: capturedOptions.ifNoneMatch
                    )

                    try Task.checkCancellation()

                    // TODO: byte-level progress via URLSessionTaskDelegate.
                    let (responseBody, response) = try await transport.send(request, body: .data(data))

                    try Task.checkCancellation()

                    let built = try Self.makeUploadResult(
                        key: key,
                        response: response,
                        body: responseBody
                    )
                    Self.logger.debug("uploadData finish key=\(key, privacy: .public) status=\(response.statusCode, privacy: .public)")
                    return built
                }

                await state.yieldProgress(
                    TransferProgress(totalBytes: totalBytes, bytesTransferred: totalBytes)
                )
                await state.finish(with: result)
            } catch is CancellationError {
                await state.cancel()
            } catch let urlError as URLError {
                await state.fail(with: BucketClientError.transport(urlError))
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
    /// For files at or above the multipart threshold (default 100 MiB,
    /// overridable via ``UploadFileOptions/partSize``), this
    /// transparently switches to S3 multipart with parallel parts —
    /// part size is computed to satisfy S3's 5 MiB-per-non-final-part
    /// floor and 10,000-parts ceiling, and concurrency comes from
    /// ``UploadFileOptions/concurrency`` (default 4). On any failure
    /// — including structured task cancellation — the multipart path
    /// issues a best-effort `AbortMultipartUpload`.
    ///
    /// For smaller files (or when the size cannot be determined), the
    /// single-part PUT path uses `x-amz-content-sha256:
    /// UNSIGNED-PAYLOAD` so the file is read once, streamed to the
    /// transport.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - local: File on disk to upload. Must be readable by the
    ///     process. Streamed via `URLSession.upload(for:fromFile:)`.
    ///   - options: Optional metadata, cache control, ACL, multipart
    ///     part size and concurrency hints, etc. See
    ///     ``UploadFileOptions``.
    public func uploadFile(
        bucket: String,
        path: any BucketPath,
        local: URL,
        options: UploadFileOptions = .init()
    ) -> BucketUploadFileTask {
        let (task, state) = BucketUploadFileTask.make()

        let configuration = self.configuration
        let transport = self.transport
        let retryPolicy = self.retryPolicy
        let key = path.resolve()

        let work = Task {
            do {
                try Task.checkCancellation()

                let totalBytes = Self.fileSize(at: local)
                let threshold = Int64(options.partSize ?? Self.defaultMultipartThreshold)

                if let total = totalBytes, total >= threshold {
                    try await Self.runMultipartFileUpload(
                        bucket: bucket,
                        key: key,
                        local: local,
                        fileSize: total,
                        options: options,
                        configuration: configuration,
                        transport: transport,
                        retryPolicy: retryPolicy,
                        state: state
                    )
                } else {
                    try await Self.runSinglePartFileUpload(
                        bucket: bucket,
                        key: key,
                        local: local,
                        totalBytes: totalBytes,
                        options: options,
                        configuration: configuration,
                        transport: transport,
                        retryPolicy: retryPolicy,
                        state: state
                    )
                }
            } catch is CancellationError {
                await state.cancel()
            } catch let urlError as URLError {
                await state.fail(with: BucketClientError.transport(urlError))
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

    // MARK: - uploadFile dispatch helpers

    /// Single-part PUT path used for files below the multipart
    /// threshold (or for files whose size could not be read).
    private static func runSinglePartFileUpload(
        bucket: String,
        key: String,
        local: URL,
        totalBytes: Int64?,
        options: UploadFileOptions,
        configuration: BucketConfiguration,
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy,
        state: TransferTaskState<UploadResult>
    ) async throws {
        try Task.checkCancellation()

        Self.logger.debug("uploadFile start key=\(key, privacy: .public) bytes=\(totalBytes ?? -1, privacy: .public)")
        await state.yieldProgress(
            TransferProgress(totalBytes: totalBytes, bytesTransferred: 0)
        )

        // S3 single-part PUT is idempotent at the bucket/key level —
        // a duplicate PUT produces the same final object — so retry
        // the dispatch on transient failures even though HTTP
        // semantics consider PUT non-idempotent.
        let result = try await RetryRunner.run(
            policy: retryPolicy,
            logger: Self.logger
        ) { _ -> UploadResult in
            try Task.checkCancellation()

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

            let built = try Self.makeUploadResult(
                key: key,
                response: response,
                body: responseBody
            )
            Self.logger.debug("uploadFile finish key=\(key, privacy: .public) status=\(response.statusCode, privacy: .public)")
            return built
        }

        await state.yieldProgress(
            TransferProgress(
                totalBytes: totalBytes,
                bytesTransferred: totalBytes ?? 0
            )
        )
        await state.finish(with: result)
    }

    /// Multipart auto-switching path. Initiates the upload, slices
    /// the file into parts that satisfy S3's 5 MiB floor / 10,000
    /// part ceiling, dispatches them in parallel through a
    /// `TaskGroup` capped by `options.concurrency ?? 4`, and on
    /// success completes the upload. On any error — including
    /// structured cancellation — issues a best-effort
    /// `AbortMultipartUpload` and rethrows (or converts to
    /// `BucketClientError.cancelled`).
    private static func runMultipartFileUpload(
        bucket: String,
        key: String,
        local: URL,
        fileSize: Int64,
        options: UploadFileOptions,
        configuration: BucketConfiguration,
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy,
        state: TransferTaskState<UploadResult>
    ) async throws {
        try Task.checkCancellation()

        let partSize = computeMultipartPartSize(fileSize: fileSize)
        let totalParts = Int((fileSize + Int64(partSize) - 1) / Int64(partSize))
        let concurrency = max(1, options.concurrency ?? defaultMultipartConcurrency)

        Self.multipartLogger.debug(
            "uploadFile-multipart start key=\(key, privacy: .public) bytes=\(fileSize, privacy: .public) parts=\(totalParts, privacy: .public) partSize=\(partSize, privacy: .public) concurrency=\(concurrency, privacy: .public)"
        )

        await state.yieldProgress(
            TransferProgress(totalBytes: fileSize, bytesTransferred: 0)
        )

        let initiateOptions = makeUploadDataOptions(from: options)
        // Each multipart wire call (Initiate, UploadPart, Complete,
        // Abort) is retried independently — a transient blip on part
        // 47 should not restart the upload from part 1.
        let uploadID = try await MultipartInitiator.initiate(
            bucket: bucket,
            key: key,
            configuration: configuration,
            transport: transport,
            retryPolicy: retryPolicy,
            options: initiateOptions
        )

        let upload = MultipartUpload(
            configuration: configuration,
            transport: transport,
            bucket: bucket,
            key: key,
            uploadID: uploadID,
            options: initiateOptions,
            retryPolicy: retryPolicy
        )

        do {
            // Read parts from disk on this task and farm them out to
            // a TaskGroup capped at `concurrency`. The reader is
            // sequential (one FileHandle, one read at a time) so we
            // do not need extra serialization beyond the actor that
            // owns the handle.
            let reader = try MultipartFileReader(fileURL: local, partSize: partSize)
            defer { reader.close() }

            try await withThrowingTaskGroup(
                of: (UploadedPart, Int).self
            ) { group in
                var nextPartNumber = 1
                var inFlight = 0
                var bytesTransferred: Int64 = 0

                while nextPartNumber <= totalParts {
                    if inFlight >= concurrency {
                        let (_, partBytes) = try await group.next()!
                        inFlight -= 1
                        bytesTransferred += Int64(partBytes)
                        await state.yieldProgress(
                            TransferProgress(
                                totalBytes: fileSize,
                                bytesTransferred: bytesTransferred
                            )
                        )
                    }

                    try Task.checkCancellation()

                    let partNumber = nextPartNumber
                    nextPartNumber += 1
                    let chunk = try reader.readNext()
                    let partBytes = chunk.count

                    group.addTask {
                        let part = try await upload.uploadPart(chunk, partNumber: partNumber)
                        return (part, partBytes)
                    }
                    inFlight += 1
                }

                // Drain remaining results.
                while inFlight > 0 {
                    let (_, partBytes) = try await group.next()!
                    inFlight -= 1
                    bytesTransferred += Int64(partBytes)
                    await state.yieldProgress(
                        TransferProgress(
                            totalBytes: fileSize,
                            bytesTransferred: bytesTransferred
                        )
                    )
                }
            }

            try Task.checkCancellation()

            let result = try await upload.complete()
            await state.yieldProgress(
                TransferProgress(totalBytes: fileSize, bytesTransferred: fileSize)
            )
            await state.finish(with: result)
            Self.multipartLogger.debug(
                "uploadFile-multipart finish key=\(key, privacy: .public) parts=\(totalParts, privacy: .public)"
            )
        } catch is CancellationError {
            try? await upload.abort()
            throw BucketClientError.cancelled
        } catch {
            try? await upload.abort()
            throw error
        }
    }

    /// Computes the per-part size for the auto-switching path.
    ///
    /// Default is 8 MiB, but when the file is larger than `8 MiB *
    /// 10,000` we scale the part size up so we stay under S3's
    /// 10,000-part ceiling. The result is clamped to
    /// `[5 MiB, 5 GiB]`.
    fileprivate static func computeMultipartPartSize(fileSize: Int64) -> Int {
        let fiveMiB = 5 * 1024 * 1024
        let eightMiB = 8 * 1024 * 1024
        let fiveGiB: Int64 = 5 * 1024 * 1024 * 1024
        let maxParts: Int64 = 10_000

        let minimumForCount = (fileSize + maxParts - 1) / maxParts
        var partSize: Int64 = max(Int64(eightMiB), minimumForCount)
        partSize = max(Int64(fiveMiB), partSize)
        partSize = min(fiveGiB, partSize)
        return Int(partSize)
    }

    /// Default multipart trigger threshold (100 MiB).
    fileprivate static let defaultMultipartThreshold: Int = 100 * 1024 * 1024

    /// Default multipart parallelism.
    fileprivate static let defaultMultipartConcurrency: Int = 4

    /// Adapts an ``UploadFileOptions`` into the
    /// ``UploadDataOptions`` shape the multipart helpers consume.
    /// The two structs are intentionally field-identical (see
    /// ``UploadFileOptions``); this is just a copy.
    fileprivate static func makeUploadDataOptions(
        from options: UploadFileOptions
    ) -> UploadDataOptions {
        UploadDataOptions(
            contentType: options.contentType,
            cacheControl: options.cacheControl,
            metadata: options.metadata,
            acl: options.acl,
            storageClass: options.storageClass,
            serverSideEncryption: options.serverSideEncryption,
            ifNoneMatch: options.ifNoneMatch,
            partSize: options.partSize,
            concurrency: options.concurrency
        )
    }

    // MARK: - Internals

    private static let logger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "client"
    )

    private static let multipartLogger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "multipart"
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
        if let serverSideEncryption {
            // Operation-driven SSE headers — translated centrally in
            // ``ServerSideEncryption/headers``. They are merged into
            // the request before signing so they participate in the
            // SigV4 canonical headers block.
            for (name, value) in serverSideEncryption.headers {
                headers[name] = value
            }
        }

        // Configuration-level escape hatch (e.g.
        // `x-amz-bucket-key-enabled`). Layered in last so the
        // operation's own headers always win on conflict.
        configuration.mergeBaseHeaders(into: &headers)

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
            throw BucketClientError.invalidConfiguration(
                "endpoint missing scheme or host: \(endpoint.absoluteString)"
            )
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
            throw BucketClientError.invalidConfiguration(
                "could not build object URL from endpoint: \(endpoint.absoluteString)"
            )
        }
        return url
    }

    /// Builds the public ``UploadResult`` from a successful HTTP
    /// response. Throws a decoded ``BucketServiceError`` on non-2xx.
    private static func makeUploadResult(
        key: String,
        response: HTTPURLResponse,
        body: Data
    ) throws -> UploadResult {
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw BucketServiceError.decode(httpStatus: status, body: body)
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

    /// Best-effort byte size lookup for a local file, used both for
    /// progress reporting and for the multipart auto-switching
    /// threshold. Returns `nil` if the size can't be read, which
    /// surfaces as `totalBytes == nil` on the progress event and
    /// keeps `uploadFile` on the single-part path.
    static func fileSize(at url: URL) -> Int64? {
        // Prefer `FileManager.attributesOfItem(atPath:)` because it
        // returns a 64-bit `NSNumber` directly; `URLResourceValues`
        // falls back to `Int` (32-bit on some target architectures
        // historically) which would silently truncate large files.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            return size.int64Value
        }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return Int64(size)
        }
        return nil
    }
}

// MARK: - MultipartFileReader

/// Sequential file reader used by the multipart auto-switching path.
///
/// Reads `partSize` bytes per call, returning a `Data` whose count is
/// `partSize` for every part except the last (which may be shorter).
/// Errors from `FileHandle` propagate as `BucketClientError` so the
/// surrounding `do/catch` can convert them uniformly.
final class MultipartFileReader: @unchecked Sendable {
    private let handle: FileHandle
    private let partSize: Int

    init(fileURL: URL, partSize: Int) throws {
        do {
            self.handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw BucketClientError.invalidConfiguration(
                "could not open file for multipart upload: \(error.localizedDescription)"
            )
        }
        self.partSize = partSize
    }

    /// Reads up to `partSize` bytes from the current offset.
    /// Returns `Data()` (empty) when the file is exhausted.
    func readNext() throws -> Data {
        do {
            // `read(upToCount:)` is the modern non-throwing-on-EOF
            // variant. On Apple platforms it is available since 13.4
            // / 16.4, which is below our minimum deployment target.
            let chunk = try handle.read(upToCount: partSize) ?? Data()
            return chunk
        } catch {
            throw BucketClientError.invalidConfiguration(
                "failed to read part from file: \(error.localizedDescription)"
            )
        }
    }

    func close() {
        try? handle.close()
    }
}


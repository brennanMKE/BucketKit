import Foundation
import CryptoKit
import os

extension BucketClient {
    /// Downloads an object's bytes into memory.
    ///
    /// Returns a ``BucketDownloadDataTask`` immediately; the actual
    /// GET runs on a child `Task`. Callers can either `await
    /// task.value` for the final `Data` or iterate
    /// ``BucketDownloadDataTask/progress`` for byte-count snapshots.
    /// Today progress is coarse (start, finish) — byte-level updates
    /// require a `URLSessionTaskDelegate` we haven't wired yet.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name. Combined with the configuration's
    ///     endpoint and `usePathStyle` flag to form the request URL.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - options: Optional range and conditional headers. See
    ///     ``DownloadDataOptions``.
    public func downloadData(
        bucket: String,
        path: any BucketPath,
        options: DownloadDataOptions = .init()
    ) -> BucketDownloadDataTask {
        let (task, state) = BucketDownloadDataTask.make()

        let configuration = self.configuration
        let transport = self.transport
        let key = path.resolve()

        // Run the download on a child Task so the public API stays
        // synchronous (returns the task value immediately) while the
        // actual network work runs in the background.
        let work = Task {
            do {
                try Task.checkCancellation()

                Self.downloadLogger.debug("downloadData start key=\(key, privacy: .public)")
                await state.yieldProgress(
                    TransferProgress(totalBytes: nil, bytesTransferred: 0)
                )

                let request = try Self.buildSignedGetRequest(
                    bucket: bucket,
                    key: key,
                    configuration: configuration,
                    range: options.range,
                    ifNoneMatch: options.ifNoneMatch,
                    ifMatch: options.ifMatch
                )

                try Task.checkCancellation()

                // TODO: byte-level progress via URLSessionTaskDelegate.
                let (responseBody, response) = try await transport.send(request, body: nil)

                try Task.checkCancellation()

                let data = try Self.makeDownloadData(
                    response: response,
                    body: responseBody
                )

                let totalBytes = Self.contentLength(from: response)
                await state.yieldProgress(
                    TransferProgress(
                        totalBytes: totalBytes,
                        bytesTransferred: totalBytes ?? Int64(data.count)
                    )
                )
                await state.finish(with: data)
                Self.downloadLogger.debug("downloadData finish key=\(key, privacy: .public) status=\(response.statusCode, privacy: .public)")
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

    /// Downloads an object's bytes to a local file.
    ///
    /// The transport streams the response body to disk so large
    /// objects don't buffer in memory; on success the bytes are
    /// atomically moved to `local`, overwriting any existing file
    /// there.
    ///
    /// Returns a ``BucketDownloadFileTask`` immediately; the actual
    /// GET runs on a child `Task`. On success the task's `value`
    /// resolves to `local` (the URL the caller supplied).
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Object key, supplied as a ``BucketPath``.
    ///   - local: Destination on disk. The transport writes through
    ///     a temporary file and atomically replaces this URL on
    ///     completion.
    ///   - options: Optional range and conditional headers. See
    ///     ``DownloadFileOptions``.
    public func downloadFile(
        bucket: String,
        path: any BucketPath,
        local: URL,
        options: DownloadFileOptions = .init()
    ) -> BucketDownloadFileTask {
        let (task, state) = BucketDownloadFileTask.make()

        let configuration = self.configuration
        let transport = self.transport
        let key = path.resolve()

        let work = Task {
            do {
                try Task.checkCancellation()

                Self.downloadLogger.debug("downloadFile start key=\(key, privacy: .public)")
                await state.yieldProgress(
                    TransferProgress(totalBytes: nil, bytesTransferred: 0)
                )

                let request = try Self.buildSignedGetRequest(
                    bucket: bucket,
                    key: key,
                    configuration: configuration,
                    range: options.range,
                    ifNoneMatch: options.ifNoneMatch,
                    ifMatch: options.ifMatch
                )

                try Task.checkCancellation()

                // TODO: byte-level progress via URLSessionTaskDelegate.
                let response = try await transport.download(request, to: local)

                try Task.checkCancellation()

                try Self.checkDownloadStatus(response: response)

                let totalBytes = Self.contentLength(from: response)
                await state.yieldProgress(
                    TransferProgress(
                        totalBytes: totalBytes,
                        bytesTransferred: totalBytes ?? 0
                    )
                )
                await state.finish(with: local)
                Self.downloadLogger.debug("downloadFile finish key=\(key, privacy: .public) status=\(response.statusCode, privacy: .public)")
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

    // MARK: - Internals

    private static let downloadLogger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "client"
    )

    /// Builds the signed `URLRequest` for a `GET` against `bucket`/`key`.
    ///
    /// Handles URL construction (virtual-hosted vs path-style),
    /// SigV4-correct path encoding (per-segment), header translation
    /// from the options struct, and SigV4 signing. Returns a request
    /// with no body — GET has none, and the payload hash is fixed at
    /// the empty-payload constant.
    private static func buildSignedGetRequest(
        bucket: String,
        key: String,
        configuration: BucketConfiguration,
        range: Range<Int64>?,
        ifNoneMatch: String?,
        ifMatch: String?
    ) throws -> URLRequest {
        let url = try makeDownloadObjectURL(
            bucket: bucket,
            key: key,
            configuration: configuration
        )

        var headers: [String: String] = [:]
        if let range {
            // Swift `Range` is half-open (lower inclusive, upper
            // exclusive). HTTP byte ranges are inclusive on both ends,
            // so subtract one from the upper bound when serialising.
            headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
        }
        if let ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        if let ifMatch {
            headers["If-Match"] = ifMatch
        }

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

    /// Constructs the absolute URL for a download, picking
    /// virtual-hosted vs path-style addressing from the configuration
    /// and SigV4-encoding the key one segment at a time.
    ///
    /// Duplicated from ``Upload`` for now — the two builders are
    /// identical, but factoring a shared helper risks subtle changes
    /// to #0011's signing path. The builders can be unified once the
    /// upload surface settles.
    private static func makeDownloadObjectURL(
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

    /// Validates the response status for an in-memory download and
    /// returns the body on success. 200 (full body) and 206 (partial
    /// body for ranged requests) are both treated as success; any
    /// other status surfaces as a ``BucketServiceError`` decoded
    /// from the response body.
    private static func makeDownloadData(
        response: HTTPURLResponse,
        body: Data
    ) throws -> Data {
        let status = response.statusCode
        guard status == 200 || status == 206 else {
            // 304 Not Modified (If-None-Match) and 412 Precondition
            // Failed (If-Match) surface here as
            // `BucketServiceError`s; callers disambiguate by
            // inspecting `httpStatus`.
            throw BucketServiceError.decode(httpStatus: status, body: body)
        }
        return body
    }

    /// Shared status-code validation for the file-streaming path,
    /// where the body has already been written to disk and isn't
    /// available for XML decoding. Falls back to the empty-body
    /// path of ``BucketServiceError/decode(httpStatus:body:)``.
    private static func checkDownloadStatus(response: HTTPURLResponse) throws {
        let status = response.statusCode
        guard status == 200 || status == 206 else {
            throw BucketServiceError.decode(httpStatus: status, body: Data())
        }
    }

    /// Reads the `Content-Length` header into an `Int64`, returning
    /// `nil` if the header is missing or unparseable. Used for
    /// progress reporting.
    private static func contentLength(from response: HTTPURLResponse) -> Int64? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length"),
              let value = Int64(raw) else {
            return nil
        }
        return value
    }
}


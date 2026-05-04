import Foundation
import os

extension BucketClient {
    /// Lists objects in `bucket` using `ListObjectsV2`.
    ///
    /// Issues a `GET /?list-type=2` against `bucket`, optionally filtered
    /// by ``ListOptions/prefix`` and ``ListOptions/delimiter`` and paged
    /// via ``ListOptions/maxKeys`` and
    /// ``ListOptions/continuationToken``. When ``ListOptions/prefix`` is
    /// `nil` and a non-`nil` `path` is supplied, the path's resolved key
    /// is used as the prefix — a small convenience for callers that
    /// want "list everything under this folder".
    ///
    /// On success the response body is decoded as ``ListBucketResultV2``
    /// and mapped to a ``BucketListResult``. On any non-2xx a typed
    /// ``BucketServiceError`` decoded from the response body is thrown.
    ///
    /// When ``ListOptions/listAll`` is `true` the call transparently
    /// follows continuation tokens and returns a single
    /// ``BucketListResult`` aggregating every page's items and common
    /// prefixes. The aggregated result has ``BucketListResult/isTruncated``
    /// set to `false` and ``BucketListResult/nextContinuationToken``
    /// set to `nil`. For very large buckets prefer
    /// ``listAll(bucket:path:options:)`` which streams rather than
    /// buffers.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Optional ``BucketPath``. When supplied and
    ///     ``ListOptions/prefix`` is `nil`, the resolved key is used as
    ///     the listing prefix.
    ///   - options: Filter, paging, and auto-pagination options. See
    ///     ``ListOptions``.
    /// - Returns: One page of results, or every result aggregated when
    ///   ``ListOptions/listAll`` is `true`.
    public func list(
        bucket: String,
        path: (any BucketPath)? = nil,
        options: ListOptions = .init()
    ) async throws -> BucketListResult {
        // When `listAll == true`, drain the streaming variant into a
        // single aggregated result so the page-at-a-time API can also
        // serve callers who just want everything in one place. We
        // forward a copy of `options` with `listAll = false` to the
        // page fetcher so it does the per-page work without recursing.
        if options.listAll {
            var perPage = options
            perPage.listAll = false
            var items: [BucketObject] = []
            var commonPrefixes: [String] = []
            for try await object in listAll(bucket: bucket, path: path, options: perPage) {
                items.append(object)
            }
            // The streaming form yields objects only — to also surface
            // common prefixes in the aggregated result we drain pages
            // directly here for the prefixes, reusing the same
            // pagination loop shape.
            commonPrefixes = try await aggregateCommonPrefixes(
                bucket: bucket,
                path: path,
                options: perPage
            )
            return BucketListResult(
                items: items,
                commonPrefixes: commonPrefixes,
                isTruncated: false,
                nextContinuationToken: nil
            )
        }

        return try await fetchPage(bucket: bucket, path: path, options: options)
    }

    /// Streams every object matching `options` across every page,
    /// transparently following continuation tokens.
    ///
    /// The returned ``AsyncThrowingStream`` yields each
    /// ``BucketObject`` exactly once and finishes when the server
    /// reports a non-truncated page. Errors thrown by the underlying
    /// page fetch terminate the stream with that error.
    ///
    /// Cancellation: the stream's onTermination handler cancels the
    /// underlying pagination task, which propagates structured task
    /// cancellation through to any in-flight HTTP request.
    ///
    /// Common prefixes are not surfaced through this stream because
    /// the type is `<BucketObject>`. Callers who need both the items
    /// and the common prefixes from a delimited listing should use
    /// ``list(bucket:path:options:)`` page-by-page instead.
    ///
    /// - Parameters:
    ///   - bucket: Bucket name.
    ///   - path: Optional ``BucketPath``. When supplied and
    ///     ``ListOptions/prefix`` is `nil`, the resolved key is used as
    ///     the listing prefix.
    ///   - options: Filter and paging options. ``ListOptions/listAll``
    ///     is ignored here — this method always paginates.
    /// - Returns: An `AsyncThrowingStream` of every matching object.
    public nonisolated func listAll(
        bucket: String,
        path: (any BucketPath)? = nil,
        options: ListOptions = .init()
    ) -> AsyncThrowingStream<BucketObject, Error> {
        AsyncThrowingStream<BucketObject, Error> { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var current = options
                current.listAll = false
                do {
                    while true {
                        try Task.checkCancellation()
                        let page = try await self.fetchPage(
                            bucket: bucket,
                            path: path,
                            options: current
                        )
                        for item in page.items {
                            continuation.yield(item)
                        }
                        if page.isTruncated, let token = page.nextContinuationToken {
                            current.continuationToken = token
                            continue
                        }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Internals

    private static let listLogger = Logger(
        subsystem: "dev.brennanmke.bucket",
        category: "client"
    )

    /// Fetches one page of `ListObjectsV2` results, mapping the
    /// decoded XML to a ``BucketListResult``.
    ///
    /// Wraps `URLError` in ``BucketClientError/transport(_:)`` and
    /// `CancellationError` in ``BucketClientError/cancelled`` so the
    /// public boundary always sees one of BucketKit's two error types.
    fileprivate func fetchPage(
        bucket: String,
        path: (any BucketPath)?,
        options: ListOptions
    ) async throws -> BucketListResult {
        do {
            try Task.checkCancellation()

            let effectivePrefix = options.prefix ?? path?.resolve()
            Self.listLogger.debug(
                "list page bucket=\(bucket, privacy: .public) prefix=\(effectivePrefix ?? "-", privacy: .public) delimiter=\(options.delimiter ?? "-", privacy: .public) continuation=\(options.continuationToken != nil ? "yes" : "no", privacy: .public)"
            )

            let request = try Self.buildSignedListRequest(
                bucket: bucket,
                configuration: configuration,
                prefix: effectivePrefix,
                delimiter: options.delimiter,
                maxKeys: options.maxKeys,
                continuationToken: options.continuationToken
            )

            try Task.checkCancellation()

            let (responseBody, response) = try await transport.send(request, body: nil)

            try Task.checkCancellation()

            let status = response.statusCode
            guard (200..<300).contains(status) else {
                throw BucketServiceError.decode(httpStatus: status, body: responseBody)
            }

            let decoded: ListBucketResultV2
            do {
                decoded = try XMLDecoder.decode(ListBucketResultV2.self, from: responseBody)
            } catch {
                throw BucketClientError.decodingFailed(String(describing: error))
            }

            let items = decoded.contents.map { entry in
                BucketObject(
                    key: entry.key,
                    size: entry.size,
                    lastModified: entry.lastModified,
                    eTag: entry.eTag,
                    storageClass: entry.storageClass.flatMap(StorageClass.init(rawValue:))
                )
            }
            let commonPrefixes = decoded.commonPrefixes.map { $0.prefix }

            return BucketListResult(
                items: items,
                commonPrefixes: commonPrefixes,
                isTruncated: decoded.isTruncated,
                nextContinuationToken: decoded.nextContinuationToken
            )
        } catch is CancellationError {
            throw BucketClientError.cancelled
        } catch let urlError as URLError {
            throw BucketClientError.transport(urlError)
        }
    }

    /// Walks every page (like ``listAll(bucket:path:options:)``) but
    /// collects each page's common prefixes instead of yielding
    /// objects. Used by the `listAll == true` aggregation path on
    /// ``list(bucket:path:options:)`` so the aggregated result still
    /// surfaces common prefixes.
    fileprivate func aggregateCommonPrefixes(
        bucket: String,
        path: (any BucketPath)?,
        options: ListOptions
    ) async throws -> [String] {
        var current = options
        current.listAll = false
        var seen: Set<String> = []
        var ordered: [String] = []
        while true {
            let page = try await fetchPage(
                bucket: bucket,
                path: path,
                options: current
            )
            for prefix in page.commonPrefixes where seen.insert(prefix).inserted {
                ordered.append(prefix)
            }
            if page.isTruncated, let token = page.nextContinuationToken {
                current.continuationToken = token
                continue
            }
            return ordered
        }
    }

    /// Builds the signed `URLRequest` for a `GET /?list-type=2`
    /// against `bucket`.
    ///
    /// All listing parameters are added to ``URLComponents/queryItems``
    /// before signing — `URLComponents` round-trips them and the
    /// signer reads `percentEncodedQueryItems` out of the URL, so
    /// every parameter participates in the SigV4 canonical query
    /// string without further plumbing.
    private static func buildSignedListRequest(
        bucket: String,
        configuration: BucketConfiguration,
        prefix: String?,
        delimiter: String?,
        maxKeys: Int?,
        continuationToken: String?
    ) throws -> URLRequest {
        let url = try makeListURL(
            bucket: bucket,
            configuration: configuration,
            prefix: prefix,
            delimiter: delimiter,
            maxKeys: maxKeys,
            continuationToken: continuationToken
        )

        let signer = SigV4Signer(configuration: configuration)
        let signed = signer.sign(
            SigV4Signer.Request(
                method: "GET",
                url: url,
                headers: [:],
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

    /// Constructs the absolute URL for a `ListObjectsV2` operation,
    /// picking virtual-hosted vs path-style addressing from the
    /// configuration. Unlike the per-object operations the URL is
    /// bucket-rooted (no key segment).
    private static func makeListURL(
        bucket: String,
        configuration: BucketConfiguration,
        prefix: String?,
        delimiter: String?,
        maxKeys: Int?,
        continuationToken: String?
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
            // Trailing `/` keeps the request rooted at the bucket
            // resource; S3 accepts both forms but the canonical-URI
            // rules treat `/bucket` and `/bucket/` differently, and
            // path-style listing wants the bucket-as-collection form.
            components.percentEncodedPath = "\(basePath)/\(bucket)/"
        } else {
            components.host = "\(bucket).\(host)"
            components.percentEncodedPath = "/"
        }

        // Use `queryItems` (rather than `percentEncodedQueryItems`) so
        // URLComponents handles encoding for us. The signer
        // re-encodes under SigV4 rules anyway, so we just need
        // round-trippable items here.
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "list-type", value: "2")
        ]
        if let prefix {
            queryItems.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let delimiter {
            queryItems.append(URLQueryItem(name: "delimiter", value: delimiter))
        }
        if let maxKeys {
            queryItems.append(URLQueryItem(name: "max-keys", value: String(maxKeys)))
        }
        if let continuationToken {
            queryItems.append(URLQueryItem(name: "continuation-token", value: continuationToken))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw BucketClientError.invalidConfiguration(
                "could not build list URL from endpoint: \(endpoint.absoluteString)"
            )
        }
        return url
    }
}

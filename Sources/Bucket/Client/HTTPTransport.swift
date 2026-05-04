import Foundation

/// Body payload for an `HTTPTransport.send` call.
///
/// Modeled as a small `Sendable` value type so the transport seam stays
/// minimal but can grow without source-breaking changes. The two cases
/// covered today are the only ones BucketKit currently produces:
///
/// - `.data(_:)` — an in-memory `Data` payload, used for small uploads
///   and signed request bodies.
/// - `.fileURL(_:)` — a file on disk; used so large uploads can stream
///   without materialising the whole payload in memory.
///
/// Future cases (for example a `.stream` variant backed by an
/// `AsyncSequence<Data>`) can be added without breaking existing
/// callers, since the type is an `enum` we own.
public enum TransportBody: Sendable {
    /// In-memory payload.
    case data(Data)
    /// On-disk payload. The transport must not delete or move the file.
    case fileURL(URL)
}

/// Networking seam for `BucketClient`.
///
/// `HTTPTransport` is intentionally tiny: three async methods, all
/// surfaced as `(Data, HTTPURLResponse)` or `HTTPURLResponse` tuples
/// with no callbacks, Combine publishers, or Dispatch queues. This is
/// the single place where BucketKit talks to the network — tests swap
/// in a fake transport, and the production implementation
/// (`URLSessionTransport`) wraps `URLSession`'s async API.
///
/// Conformances must be `Sendable`; the protocol is invoked from
/// `BucketClient`, an `actor`.
public protocol HTTPTransport: Sendable {
    /// Send a request whose body (if any) is small enough to live in
    /// memory or come from a local file. Returns the response body and
    /// metadata. Non-2xx responses are *not* errors at this layer — the
    /// caller decides how to interpret HTTP status.
    func send(
        _ request: URLRequest,
        body: TransportBody?
    ) async throws -> (Data, HTTPURLResponse)

    /// Upload the contents of `fileURL` as the request body. Used for
    /// large `PUT`/multipart-part uploads where streaming from disk
    /// avoids loading the entire payload into memory.
    func upload(
        _ request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, HTTPURLResponse)

    /// Download the response body to `destination`. The response body
    /// is streamed to disk; only the `HTTPURLResponse` is returned.
    /// Implementations are expected to move the downloaded payload to
    /// `destination` atomically and overwrite any existing file there.
    func download(
        _ request: URLRequest,
        to destination: URL
    ) async throws -> HTTPURLResponse
}

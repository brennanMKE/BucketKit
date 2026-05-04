import Foundation

/// Default `HTTPTransport` backed by `URLSession`.
///
/// Uses `URLSession`'s async API exclusively — no completion handlers,
/// no Combine, no Dispatch queues. The wrapped session defaults to
/// `URLSession.shared`; callers may inject a custom session (for
/// example one configured with a different `URLSessionConfiguration`)
/// without subclassing.
public struct URLSessionTransport: HTTPTransport {
    /// Underlying session. `URLSession` is `Sendable` on Apple
    /// platforms, so this struct is trivially `Sendable`.
    public let session: URLSession

    /// Creates a transport that delegates to `session`.
    /// - Parameter session: The session to use. Defaults to
    ///   `URLSession.shared`.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Convenience instance backed by `URLSession.shared`.
    public static let shared = URLSessionTransport()

    public func send(
        _ request: URLRequest,
        body: TransportBody?
    ) async throws -> (Data, HTTPURLResponse) {
        switch body {
        case .none:
            let (data, response) = try await session.data(for: request)
            return (data, Self.httpResponse(response))
        case .data(let data):
            // Attach the in-memory body via `httpBody`. We don't use
            // `uploadTask(with:from:)` here because the request may be
            // signed against this exact `httpBody` already.
            var request = request
            request.httpBody = data
            let (responseData, response) = try await session.data(for: request)
            return (responseData, Self.httpResponse(response))
        case .fileURL(let fileURL):
            let (data, response) = try await session.upload(for: request, fromFile: fileURL)
            return (data, Self.httpResponse(response))
        }
    }

    public func upload(
        _ request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return (data, Self.httpResponse(response))
    }

    public func download(
        _ request: URLRequest,
        to destination: URL
    ) async throws -> HTTPURLResponse {
        let (temporaryURL, response) = try await session.download(for: request)
        // `URLSession.download(for:)` writes the body to a temporary
        // file we are responsible for moving or deleting before this
        // function returns. Move it into place atomically; if the
        // destination already exists, overwrite it.
        //
        // Filesystem failures here are surfaced as the underlying
        // `CocoaError`/`NSError` for now. Once issue #0015 introduces
        // `BucketClientError.transport(...)`, these should be wrapped.
        let fileManager = FileManager.default
        do {
            // `replaceItemAt` performs an atomic replace when the
            // destination exists, falling back to a move otherwise.
            // Using it unconditionally handles both cases without a
            // TOCTOU race between an `exists` check and the move.
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                // Ensure the parent directory exists so the move can
                // succeed when callers pass a fresh path.
                let parent = destination.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                }
                try fileManager.moveItem(at: temporaryURL, to: destination)
            }
        } catch {
            // Best-effort cleanup of the temp file if the move failed
            // partway. Ignore secondary errors — we want to surface
            // the original failure.
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return Self.httpResponse(response)
    }

    /// Cast a `URLResponse` to `HTTPURLResponse`. Every request in
    /// BucketKit targets HTTPS, so a non-HTTP response indicates a
    /// programming error rather than a runtime condition we should
    /// model. We surface it as a synthetic `URLError` so callers see
    /// it through the same channel as other transport failures.
    private static func httpResponse(_ response: URLResponse) -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            // This shouldn't happen for HTTPS requests; fall back to a
            // zero-status synthetic response so we never force-unwrap.
            return HTTPURLResponse(
                url: response.url ?? URL(string: "about:blank")!,
                statusCode: 0,
                httpVersion: nil,
                headerFields: nil
            )!
        }
        return http
    }
}

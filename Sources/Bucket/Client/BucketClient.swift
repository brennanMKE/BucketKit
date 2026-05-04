import Foundation

/// Hub for all S3-compatible operations.
///
/// `BucketClient` is an `actor` so that future internal mutable state
/// (retry budgets, per-request diagnostics, multipart bookkeeping) can
/// live behind a single isolation boundary without further ceremony.
/// The configuration and transport stored here are immutable and
/// `Sendable`, so they are exposed as `nonisolated let` — callers (and
/// future operations attached via extensions) can read them without
/// hopping onto the actor.
///
/// One instance per app is generally fine. The bucket name is supplied
/// per call rather than at construction so a single client can serve
/// many buckets.
///
/// This file intentionally contains only the scaffold: stored
/// properties and the initializer. Operations (`uploadData`,
/// `downloadData`, `getURL`, `list`, …) are introduced in subsequent
/// issues (#0011–#0017) as extensions.
public actor BucketClient {
    /// Endpoint, region, credentials, and addressing style for this
    /// client. Immutable after construction.
    public nonisolated let configuration: BucketConfiguration

    /// Networking seam used for every outbound request. Defaults to
    /// ``URLSessionTransport/shared`` but can be swapped for tests or
    /// for callers that need a custom `URLSession` configuration.
    public nonisolated let transport: any HTTPTransport

    /// Creates a client bound to the supplied configuration and
    /// transport.
    ///
    /// - Parameters:
    ///   - configuration: Endpoint, region, credentials, and
    ///     addressing style. See ``BucketConfiguration`` for the
    ///     provider-specific factories.
    ///   - transport: Networking seam. Defaults to
    ///     ``URLSessionTransport/shared``; tests typically inject a
    ///     fake conforming to ``HTTPTransport``.
    public init(
        configuration: BucketConfiguration,
        transport: any HTTPTransport = URLSessionTransport.shared
    ) {
        self.configuration = configuration
        self.transport = transport
    }
}

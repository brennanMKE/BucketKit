import Foundation

/// Retry policy applied uniformly to every HTTP dispatch BucketKit
/// performs, configurable on ``BucketClient``.
///
/// Per PRD §9 the defaults retry on HTTP 5xx and on the S3 error codes
/// `RequestTimeout`, `SlowDown`, and `InternalError`, plus a small set
/// of transient `URLError` codes. Backoff is full-jitter exponential
/// (`min(maxDelay, baseDelay * 2^(attempt - 1))` then a uniform random
/// in `[0, capped]`) with a default cap of 5 attempts total — matching
/// the AWS SDK's default behaviour.
///
/// **Idempotency note:** S3 PUT/POST requests are retried even though
/// HTTP semantics generally consider them non-idempotent. At the
/// bucket/key level S3 is idempotent — a duplicate PUT produces the
/// same final object, and `CompleteMultipartUpload` is safe to retry
/// as long as the part list hasn't changed. The auto-multipart path
/// retries individual `Initiate`/`UploadPart`/`Complete`/`Abort` calls
/// rather than the whole file so a single transient blip on part 47
/// doesn't restart the upload from part 1.
public struct RetryPolicy: Sendable, Hashable {
    /// Maximum number of attempts including the first. `1` disables
    /// retries entirely (see ``RetryPolicy/none``).
    public var maxAttempts: Int

    /// Exponential-backoff base delay. The cap for the random draw on
    /// attempt `n` is `min(maxDelay, baseDelay * 2^(n - 1))`.
    public var baseDelay: Duration

    /// Upper bound on the cap supplied to the full-jitter draw. Past
    /// the attempt where `baseDelay * 2^(n - 1)` exceeds this value the
    /// random range plateaus.
    public var maxDelay: Duration

    /// HTTP status codes that should trigger a retry when surfaced as
    /// a ``BucketServiceError``.
    public var retryableStatuses: Set<Int>

    /// S3 error codes that should trigger a retry (in addition to the
    /// status-based check). Default covers `RequestTimeout`,
    /// `SlowDown`, and `InternalError`.
    public var retryableServiceCodes: Set<String>

    /// Whether transient `URLError`s wrapped in
    /// ``BucketClientError/transport(_:)`` should be retried. The
    /// runner whitelists the specific transient codes it considers
    /// retryable; it never retries `.cancelled`.
    public var retryNetworkErrors: Bool

    public init(
        maxAttempts: Int = 5,
        baseDelay: Duration = .milliseconds(100),
        maxDelay: Duration = .seconds(20),
        retryableStatuses: Set<Int> = [500, 502, 503, 504],
        retryableServiceCodes: Set<String> = ["RequestTimeout", "SlowDown", "InternalError"],
        retryNetworkErrors: Bool = true
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatuses = retryableStatuses
        self.retryableServiceCodes = retryableServiceCodes
        self.retryNetworkErrors = retryNetworkErrors
    }

    /// Default policy: 5 attempts, 100 ms base, 20 s cap, the AWS SDK
    /// retryable status set, and transient network errors enabled.
    public static let `default` = RetryPolicy()

    /// Policy that disables retries entirely. Useful in tests and for
    /// callers that want to handle all retry logic themselves.
    public static let none = RetryPolicy(maxAttempts: 1)
}

extension RetryPolicy {
    /// Decides whether the runner should retry `error` after the
    /// specified `attempt` (1-based: `attempt == 1` is the first try).
    ///
    /// Returns `false` immediately when `attempt >= maxAttempts` so
    /// the caller never has to remember the bound. Otherwise classifies
    /// the error:
    ///
    /// - ``BucketServiceError``: retried when the HTTP status is in
    ///   ``retryableStatuses`` or the service code is in
    ///   ``retryableServiceCodes``.
    /// - ``BucketClientError/transport(_:)``: retried when
    ///   ``retryNetworkErrors`` is `true` and the wrapped `URLError`
    ///   is one of the transient codes the runner whitelists. Notably
    ///   `.cancelled` is never retried — the caller meant to cancel.
    /// - ``BucketClientError/cancelled``: never retried.
    /// - Anything else (signing failure, decoding failure, multipart
    ///   misuse, programmer errors): never retried — these are not
    ///   the kind of failure another attempt can fix.
    internal func shouldRetry(error: Error, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }

        if let serviceError = error as? BucketServiceError {
            if retryableStatuses.contains(serviceError.httpStatus) {
                return true
            }
            if retryableServiceCodes.contains(serviceError.code) {
                return true
            }
            return false
        }

        if let clientError = error as? BucketClientError {
            switch clientError {
            case .cancelled:
                return false
            case .transport(let urlError):
                guard retryNetworkErrors else { return false }
                return Self.transientURLErrorCodes.contains(urlError.code)
            case .invalidConfiguration, .signingFailed, .decodingFailed,
                 .multipartPartTooSmall:
                return false
            }
        }

        // Bare `URLError`s slip through here for callers/tests that
        // throw them directly without going through the public
        // wrapping. Treat them the same as `.transport`.
        if let urlError = error as? URLError {
            guard retryNetworkErrors else { return false }
            return Self.transientURLErrorCodes.contains(urlError.code)
        }

        return false
    }

    /// Computes the backoff for the upcoming attempt. `attempt` is
    /// 1-based and refers to the attempt that just failed — so the
    /// first retry waits using `delay(forAttempt: 1)`. The result is
    /// a uniform random draw in `[0, capped]` (full jitter, per the
    /// AWS architecture blog) where `capped` is `min(maxDelay,
    /// baseDelay * 2^(attempt - 1))`.
    internal func delay(forAttempt attempt: Int) -> Duration {
        let baseNanos = Self.nanoseconds(of: baseDelay)
        let maxNanos = Self.nanoseconds(of: maxDelay)
        guard baseNanos > 0 else { return .zero }

        // Cap the shift so we never overflow the multiplication. Once
        // `2^shift * base` exceeds the cap the result clamps anyway,
        // so any further growth is irrelevant.
        let safeShift = min(max(0, attempt - 1), 62)
        let multiplier: Int64 = 1 << safeShift
        let scaled = baseNanos.multipliedReportingOverflow(by: multiplier)
        let capInput = scaled.overflow ? maxNanos : min(maxNanos, scaled.partialValue)
        let cap = max(0, capInput)
        guard cap > 0 else { return .zero }

        let drawn = Int64.random(in: 0...cap)
        return .nanoseconds(drawn)
    }

    /// `URLError` codes that the runner considers transient. Picked to
    /// match the AWS SDK's retryable network-error list — DNS, TCP,
    /// and idle-timeout failures the next attempt has a real chance
    /// of clearing.
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .cannotFindHost,
        .cannotConnectToHost,
        .resourceUnavailable,
    ]

    /// Collapses a `Duration` to nanoseconds in an `Int64`. At the
    /// policy ceiling (20 s by default) `2 * 10^10` fits with massive
    /// headroom. Negative or wildly oversized durations clamp to a
    /// safe upper bound rather than overflowing.
    private static func nanoseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        // Clamp seconds so the multiplication below stays in range.
        // `Int64.max / 1_000_000_000` is ~9.22 * 10^9 seconds; far
        // beyond any real retry policy.
        let maxSafeSeconds = Int64.max / 1_000_000_000
        let clampedSeconds = max(0, min(seconds, maxSafeSeconds))
        let secondsNanos = clampedSeconds &* 1_000_000_000
        // `attoseconds / 10^9` converts attoseconds → nanoseconds.
        let attoNanos = attoseconds / 1_000_000_000
        let sum = secondsNanos.addingReportingOverflow(attoNanos)
        return sum.overflow ? Int64.max : sum.partialValue
    }
}

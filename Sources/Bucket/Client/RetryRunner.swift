import Foundation
import os

/// Wraps a retryable HTTP dispatch in a uniform attempt loop.
///
/// Operations call ``run(policy:logger:_:)`` with the closure that
/// builds the signed request, sends it through the transport, and
/// converts the HTTP response into a typed result. On a retryable
/// failure (per ``RetryPolicy/shouldRetry(error:attempt:)``) the
/// runner sleeps for ``RetryPolicy/delay(forAttempt:)`` and re-invokes
/// the closure with the next 1-based attempt number. The closure is
/// responsible for re-signing each attempt — `X-Amz-Date` differs per
/// signature so re-signing is mandatory.
///
/// **Cancellation:** The runner honours structured task cancellation
/// at three points:
///
/// 1. Before the first attempt.
/// 2. After a retryable failure, before computing the delay.
/// 3. During `Task.sleep`. A cancellation that fires while we are
///    sleeping converts the original retryable failure to
///    ``BucketClientError/cancelled`` — the user pulled the plug
///    rather than waiting for the next attempt.
///
/// Cancellation thrown out of the closure itself surfaces unchanged
/// (it is the closure's job to translate `CancellationError` into
/// ``BucketClientError/cancelled`` if it wishes).
internal enum RetryRunner {

    /// Runs `operation` under `policy`. The closure is invoked with a
    /// 1-based `attempt` counter so callers can include the attempt
    /// number in their per-request logging if they wish — the runner
    /// itself does not log per-attempt context other than the retry
    /// decision.
    internal static func run<T: Sendable>(
        policy: RetryPolicy,
        logger: Logger,
        _ operation: @Sendable @escaping (_ attempt: Int) async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()

            do {
                return try await operation(attempt)
            } catch {
                // Decide whether this failure is retryable under the
                // policy. `shouldRetry` already handles the
                // `attempt >= maxAttempts` guard so we never have to
                // double-check the bound here.
                guard policy.shouldRetry(error: error, attempt: attempt) else {
                    throw error
                }

                let delay = policy.delay(forAttempt: attempt)
                logger.debug(
                    "retry attempt=\(attempt, privacy: .public) reason=\(Self.reason(for: error), privacy: .public) delayMillis=\(Self.milliseconds(of: delay), privacy: .public)"
                )

                // Cancellation during the sleep is the most common
                // place a long-running op gets cancelled — surface as
                // `.cancelled` so callers can pattern-match cleanly
                // rather than seeing the original transient failure.
                do {
                    try await Task.sleep(for: delay)
                } catch is CancellationError {
                    throw BucketClientError.cancelled
                } catch {
                    // Any other error from the sleep is exotic; let it
                    // propagate so we don't paper over it.
                    throw error
                }

                attempt += 1
            }
        }
    }

    /// Builds the short, privacy-safe reason string we attach to the
    /// retry log line. Avoids the message field of
    /// ``BucketServiceError`` (which can quote bucket/key) and the
    /// full `URLError.localizedDescription` (which can include URLs).
    private static func reason(for error: Error) -> String {
        if let serviceError = error as? BucketServiceError {
            return "service code=\(serviceError.code) status=\(serviceError.httpStatus)"
        }
        if let clientError = error as? BucketClientError {
            switch clientError {
            case .transport(let urlError):
                return "transport urlErrorCode=\(urlError.code.rawValue)"
            case .cancelled:
                return "cancelled"
            case .invalidConfiguration:
                return "invalidConfiguration"
            case .signingFailed:
                return "signingFailed"
            case .decodingFailed:
                return "decodingFailed"
            case .multipartPartTooSmall:
                return "multipartPartTooSmall"
            }
        }
        if let urlError = error as? URLError {
            return "urlError code=\(urlError.code.rawValue)"
        }
        return "other"
    }

    /// Renders a `Duration` as an integer millisecond count for
    /// logging. We deliberately collapse to milliseconds because the
    /// per-attempt jitter can be sub-second and the standard
    /// `Duration` description includes attoseconds, which is noise.
    private static func milliseconds(of duration: Duration) -> Int64 {
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = components.attoseconds
        let secondsMillis = seconds.multipliedReportingOverflow(by: 1_000)
        let base = secondsMillis.overflow ? Int64.max : secondsMillis.partialValue
        // attoseconds → milliseconds: divide by 10^15.
        let attoMillis = attoseconds / 1_000_000_000_000_000
        let sum = base.addingReportingOverflow(attoMillis)
        return sum.overflow ? Int64.max : sum.partialValue
    }
}

import Foundation

extension BucketConfiguration {
    /// Folds the configuration's ``extraHeaders`` into `headers` ahead
    /// of the operation's own headers.
    ///
    /// Configuration headers go in **first**, then the operation
    /// applies its own values; on key conflict the operation's value
    /// wins. This matches the documented contract on ``extraHeaders``:
    /// it is an escape hatch that should never quietly override the
    /// header an operation sets intentionally.
    ///
    /// The merge happens before SigV4 signing, so every extra header
    /// participates in the canonical request and is therefore signed.
    internal func mergeBaseHeaders(into headers: inout [String: String]) {
        guard !extraHeaders.isEmpty else { return }
        for (name, value) in extraHeaders where headers[name] == nil {
            headers[name] = value
        }
    }
}

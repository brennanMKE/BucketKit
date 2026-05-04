import Foundation

/// Cloudflare R2 jurisdictional placement.
///
/// R2 lets accounts pin a bucket to a specific jurisdiction so that data
/// is stored in infrastructure that satisfies a regulatory boundary.
/// The jurisdiction is encoded into the endpoint hostname rather than the
/// SigV4 region (which remains the literal `auto`).
public enum R2Jurisdiction: Sendable, Hashable {
    /// No jurisdictional pinning — the default global R2 endpoint.
    case `default`
    /// European Union jurisdiction.
    case eu
    /// FedRAMP jurisdiction.
    case fedramp

    /// Hostname infix inserted between the account ID and `r2.cloudflarestorage.com`.
    ///
    /// Examples:
    /// - `.default`  → `""`         → `{accountID}.r2.cloudflarestorage.com`
    /// - `.eu`       → `"eu."`      → `{accountID}.eu.r2.cloudflarestorage.com`
    /// - `.fedramp`  → `"fedramp."` → `{accountID}.fedramp.r2.cloudflarestorage.com`
    var hostnameInfix: String {
        switch self {
        case .default: return ""
        case .eu: return "eu."
        case .fedramp: return "fedramp."
        }
    }
}

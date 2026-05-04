import Foundation

/// S3 object storage class.
///
/// Used as both an upload option (`x-amz-storage-class` header) and
/// the per-object value reported by `ListObjectsV2`. Provider support
/// varies — AWS exposes the full ladder, R2 has effectively one tier
/// plus `INFREQUENT_ACCESS` on supported plans, Spaces exposes a
/// single class. Setting an unsupported class typically yields
/// `InvalidStorageClass` (HTTP 400).
///
/// Raw values are the literal strings S3 emits and accepts.
// TODO: full implementation in #0017/#0019/#0020.
public enum StorageClass: String, Sendable, Hashable {
    case standard = "STANDARD"
    case reducedRedundancy = "REDUCED_REDUNDANCY"
    case standardIA = "STANDARD_IA"
    case oneZoneIA = "ONEZONE_IA"
    case intelligentTiering = "INTELLIGENT_TIERING"
    case glacier = "GLACIER"
    case glacierIR = "GLACIER_IR"
    case deepArchive = "DEEP_ARCHIVE"
}

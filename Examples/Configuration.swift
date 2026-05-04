// Examples/Configuration.swift
//
// Building a `BucketConfiguration` for each first-class provider plus
// MinIO via `custom`. Credentials come from environment variables —
// never commit real keys.
//
// Drop into a Swift file or script that links `Bucket`.

import Foundation
import Bucket

/// AWS S3 — endpoint shape `https://s3.{region}.amazonaws.com`,
/// virtual-hosted addressing, real region in the SigV4 scope.
public func sampleAWSConfiguration() -> BucketConfiguration {
    let env = ProcessInfo.processInfo.environment
    return .aws(
        region: env["AWS_REGION"] ?? "us-east-1",
        accessKeyID: env["AWS_ACCESS_KEY_ID"] ?? "",
        secretAccessKey: env["AWS_SECRET_ACCESS_KEY"] ?? ""
    )
}

/// Cloudflare R2 (default jurisdiction). The SigV4 region is the
/// literal `auto` — set automatically by the factory.
public func sampleR2Configuration() -> BucketConfiguration {
    let env = ProcessInfo.processInfo.environment
    return .r2(
        accountID: env["R2_ACCOUNT_ID"] ?? "",
        accessKeyID: env["R2_ACCESS_KEY_ID"] ?? "",
        secretAccessKey: env["R2_SECRET_ACCESS_KEY"] ?? ""
    )
}

/// Cloudflare R2 with EU jurisdictional placement. Endpoint becomes
/// `{accountID}.eu.r2.cloudflarestorage.com`; SigV4 region stays `auto`.
public func sampleR2EUConfiguration() -> BucketConfiguration {
    let env = ProcessInfo.processInfo.environment
    return .r2(
        accountID: env["R2_ACCOUNT_ID"] ?? "",
        accessKeyID: env["R2_ACCESS_KEY_ID"] ?? "",
        secretAccessKey: env["R2_SECRET_ACCESS_KEY"] ?? "",
        jurisdiction: .eu
    )
}

/// DigitalOcean Spaces — endpoint shape `{region}.digitaloceanspaces.com`,
/// SigV4 region is forced to the literal `us-east-1` regardless of the
/// geographic region you pass in (Spaces requires this).
public func sampleSpacesConfiguration() -> BucketConfiguration {
    let env = ProcessInfo.processInfo.environment
    return .digitalOceanSpaces(
        region: env["DO_SPACES_REGION"] ?? "nyc3",
        accessKeyID: env["DO_SPACES_KEY"] ?? "",
        secretAccessKey: env["DO_SPACES_SECRET"] ?? ""
    )
}

/// MinIO (or any S3-compatible gateway). Uses path-style addressing by
/// default — most self-hosted gateways do not implement virtual-hosted
/// bucket subdomains.
public func sampleMinIOConfiguration() -> BucketConfiguration {
    let env = ProcessInfo.processInfo.environment
    let endpoint = URL(string: env["MINIO_ENDPOINT"] ?? "http://localhost:9000")!
    return .custom(
        endpoint: endpoint,
        region: "us-east-1",
        accessKeyID: env["MINIO_ACCESS_KEY"] ?? "minioadmin",
        secretAccessKey: env["MINIO_SECRET_KEY"] ?? "minioadmin",
        usePathStyle: true
    )
}

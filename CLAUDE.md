# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

BucketKit (package name `Bucket`) — a Swift 6 package for S3-compatible object storage (AWS S3, Cloudflare R2, DigitalOcean Spaces, MinIO). Apple platforms only; Foundation + CryptoKit + OSLog, zero third-party dependencies. Currently scaffolded only — `Sources/Bucket/Bucket.swift` is empty.

## Read these first

- **[PRD.md](PRD.md)** — product requirements, public API surface, package layout, milestones. The source of truth for what to build.
- **[Concepts.md](Concepts.md)** — S3 vocabulary the API assumes (keys vs paths, SigV4, multipart, presigning, ETags, provider quirks). Read before designing or reviewing any S3-touching code.
- **[issues/Issues.md](issues/Issues.md)** — local guide for the `issues/NNNN.md` tracking system. Includes the **critical rule that issues must never be closed without explicit user confirmation** (subagents may set `resolved`, never `closed`).

## Build & test

```bash
swift build
swift test
swift test --filter BucketTests.<TestName>   # single test
```

Toolchain pinned by `Package.swift`: `swift-tools-version: 6.3`, language mode `.v6`, strict concurrency. All public types must be `Sendable`.

## Architectural constraints (non-obvious, from PRD)

- **Swift Concurrency only.** No DispatchQueue, no Combine, no completion handlers anywhere in the public API.
- **`BucketClient` is an `actor`.** Uploads/downloads return `Sendable` task value types (`BucketUploadDataTask`, etc.) that vend `AsyncStream<TransferProgress>` and a `value` — not plain `async throws`. This is deliberate (progress + pause/resume + cancellation parity with Amplify).
- **`bucket:` is a per-call argument**, not configuration. One client serves many buckets.
- **SigV4 signer is in-package** (CryptoKit). Must pass official AWS SigV4 test vectors. Provider quirks: R2 uses literal region `auto`, Spaces uses literal `us-east-1`, virtual-hosted vs path-style affects the `Host` header and therefore the signature.
- **XML parsing is a custom internal SAX layer** over `XMLParser` (`Sources/Bucket/XML/`). Reused for streaming list pagination — don't pull in a third-party XML library.
- **Logging via `os.Logger` only**, subsystem `dev.brennanmke.bucket`. Never log credentials, `Authorization` headers, or full presigned URLs.
- **Multipart auto-triggers** above 100 MiB (hard floor 5 MiB per non-final part, max 10,000 parts). Cancellation must best-effort `AbortMultipartUpload`.

## Reference implementations

`references/amplify-swift` and `references/soto-s3-file-transfer` are vendored for API-shape reference (Amplify) and S3 wire-protocol reference (Soto). Don't depend on or copy from them — they're reading material.

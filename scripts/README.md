# scripts/

Helper scripts for working with BucketKit locally.

## MinIO integration test fixture

The `BucketIntegrationTests` target runs against a MinIO server on
`http://localhost:9000` with default credentials `minioadmin`/`minioadmin`.
These scripts wrap the minimum Docker invocation needed to bring that server
up and tear it down.

### Bring MinIO up

```sh
bash scripts/minio-up.sh
```

- Starts a container named `bucketkit-minio` on ports `9000` (S3 API) and
  `9001` (web console).
- Waits up to ~30s for the health endpoint
  (`http://localhost:9000/minio/health/ready`) before exiting.
- Idempotent: if `bucketkit-minio` is already running, the script is a no-op.

### Run the integration tests

```sh
swift test --filter BucketIntegrationTests
```

The tests skip themselves with a `[skip]` log line when MinIO is not
reachable, so this command is safe to run unconditionally.

To override the endpoint or credentials:

```sh
BUCKETKIT_MINIO_ENDPOINT=http://localhost:9000 \
BUCKETKIT_MINIO_ACCESS_KEY=minioadmin \
BUCKETKIT_MINIO_SECRET_KEY=minioadmin \
swift test --filter BucketIntegrationTests
```

### Bring MinIO down

```sh
bash scripts/minio-down.sh
```

Stops and removes the `bucketkit-minio` container. Idempotent.

## Real-provider smoke tests

The `BucketIntegrationTests` target also contains a small smoke-test
suite per supported provider:

| Suite | File | Gate env var |
|---|---|---|
| AWS S3 | `Tests/BucketIntegrationTests/AWSSmokeTests.swift` | `BUCKETKIT_AWS_TEST=1` |
| Cloudflare R2 | `Tests/BucketIntegrationTests/R2SmokeTests.swift` | `BUCKETKIT_R2_TEST=1` |
| DigitalOcean Spaces | `Tests/BucketIntegrationTests/DOSpacesSmokeTests.swift` | `BUCKETKIT_DO_TEST=1` |

Each suite covers the same three scenarios: creating and deleting a
bucket, putting and getting an object, and fetching a presigned `GET`
URL with plain `URLSession`. Bucket names are `bucketkit-smoke-<uuid>`
so reruns never collide.

> **Warning — these create and delete real buckets.** Running any of
> these suites will provision a throwaway bucket on a real cloud
> account, upload a few bytes, and tear it down. That counts against
> your storage / request quotas and **may incur (small) charges** even
> for short runs. Make sure you actually want this before exporting
> the gate var.

When the gate env var is unset (or any required credential is missing)
every test in the suite logs a `[skip]` line and returns — `swift
test` therefore stays green on any developer machine.

### Env-var matrix

| Provider | Required | Optional |
|---|---|---|
| AWS S3 | `BUCKETKIT_AWS_TEST=1`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `AWS_REGION` (default `us-east-1`) |
| Cloudflare R2 | `BUCKETKIT_R2_TEST=1`, `BUCKETKIT_R2_ACCOUNT_ID`, `BUCKETKIT_R2_ACCESS_KEY_ID`, `BUCKETKIT_R2_SECRET_ACCESS_KEY` | `BUCKETKIT_R2_JURISDICTION` (`default`/`eu`/`fedramp`, default `default`) |
| DigitalOcean Spaces | `BUCKETKIT_DO_TEST=1`, `BUCKETKIT_DO_REGION` (e.g. `nyc3`, `sfo3`), `BUCKETKIT_DO_ACCESS_KEY_ID`, `BUCKETKIT_DO_SECRET_ACCESS_KEY` | — |

Credentials are sourced from the environment only — never hard-coded in
the test files and never written to disk by these scripts.

### Example — AWS S3

```bash
export BUCKETKIT_AWS_TEST=1
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
swift test --filter AWSSmokeTests
```

### Example — Cloudflare R2

```bash
export BUCKETKIT_R2_TEST=1
export BUCKETKIT_R2_ACCOUNT_ID=...
export BUCKETKIT_R2_ACCESS_KEY_ID=...
export BUCKETKIT_R2_SECRET_ACCESS_KEY=...
# Optional — pin to a jurisdictional R2 endpoint:
# export BUCKETKIT_R2_JURISDICTION=eu
swift test --filter R2SmokeTests
```

### Example — DigitalOcean Spaces

```bash
export BUCKETKIT_DO_TEST=1
export BUCKETKIT_DO_REGION=nyc3
export BUCKETKIT_DO_ACCESS_KEY_ID=...
export BUCKETKIT_DO_SECRET_ACCESS_KEY=...
swift test --filter DOSpacesSmokeTests
```

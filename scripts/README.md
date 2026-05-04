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

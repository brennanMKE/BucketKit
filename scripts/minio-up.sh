#!/bin/sh
# minio-up.sh — bring up a local MinIO container for BucketKit integration tests.
#
# Idempotent: if a container named `bucketkit-minio` is already running, this
# script exits 0 without recreating it. Otherwise it runs MinIO on ports
# 9000 (S3 API) and 9001 (web console) with default credentials
# `minioadmin`/`minioadmin`, then polls /minio/health/ready until the server
# responds (up to ~30s) before exiting.
#
# Usage:
#   bash scripts/minio-up.sh
#
# Tear down with `scripts/minio-down.sh`.

set -eu

CONTAINER_NAME="bucketkit-minio"
IMAGE="minio/minio:latest"
HEALTH_URL="http://localhost:9000/minio/health/ready"
WAIT_SECONDS=30

if ! command -v docker >/dev/null 2>&1; then
    echo "[minio-up] docker not found on PATH" >&2
    exit 1
fi

# If a container with this name exists, treat the script as a no-op.
existing="$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Status}}')"
if [ -n "${existing}" ]; then
    case "${existing}" in
        Up*)
            echo "[minio-up] ${CONTAINER_NAME} already running"
            ;;
        *)
            echo "[minio-up] starting existing container ${CONTAINER_NAME}"
            docker start "${CONTAINER_NAME}" >/dev/null
            ;;
    esac
else
    echo "[minio-up] launching ${CONTAINER_NAME} from ${IMAGE}"
    docker run -d \
        --name "${CONTAINER_NAME}" \
        -p 9000:9000 \
        -p 9001:9001 \
        -e MINIO_ROOT_USER=minioadmin \
        -e MINIO_ROOT_PASSWORD=minioadmin \
        "${IMAGE}" \
        server /data --console-address ":9001" \
        >/dev/null
fi

# Poll the health endpoint until it returns 200 or we time out.
echo "[minio-up] waiting for ${HEALTH_URL}"
i=0
while [ "${i}" -lt "${WAIT_SECONDS}" ]; do
    if curl -fsS -m 2 "${HEALTH_URL}" >/dev/null 2>&1; then
        echo "[minio-up] ready after ${i}s"
        exit 0
    fi
    i=$((i + 1))
    sleep 1
done

echo "[minio-up] MinIO did not become ready within ${WAIT_SECONDS}s" >&2
docker logs --tail 50 "${CONTAINER_NAME}" >&2 || true
exit 1

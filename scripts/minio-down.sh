#!/bin/sh
# minio-down.sh — stop and remove the BucketKit MinIO container.
#
# Idempotent: succeeds even if the container does not exist.
#
# Usage:
#   bash scripts/minio-down.sh

set -eu

CONTAINER_NAME="bucketkit-minio"

if ! command -v docker >/dev/null 2>&1; then
    echo "[minio-down] docker not found on PATH" >&2
    exit 1
fi

existing="$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.ID}}')"
if [ -z "${existing}" ]; then
    echo "[minio-down] ${CONTAINER_NAME} not present"
    exit 0
fi

echo "[minio-down] removing ${CONTAINER_NAME}"
docker rm -f "${CONTAINER_NAME}" >/dev/null
echo "[minio-down] done"

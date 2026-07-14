#!/bin/bash
set -euo pipefail

IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.31.2-arm64:v1}
BASE_IMAGE=${BASE_IMAGE:-registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest}
NGINX_VERSION=${NGINX_VERSION:-1.30.3}
REDIS_VERSION=${REDIS_VERSION:-7.4.9}
USE_BUNDLED_DEPS=${USE_BUNDLED_DEPS:-0}
OUTPUT_DIR=${OUTPUT_DIR:-artifacts}

host_arch=$(uname -m)
if [ "$host_arch" != "aarch64" ] && [ "$host_arch" != "arm64" ] && [ "${ALLOW_NON_ARM64_BUILD:-0}" != "1" ]; then
    echo "This build is intended for a native ARM64 runner. Host architecture: $host_arch" >&2
    echo "Set ALLOW_NON_ARM64_BUILD=1 only for explicit emulated builds." >&2
    exit 1
fi

command -v docker >/dev/null 2>&1 || {
    echo "docker is required" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"

pull_image() {
    local image=$1
    local attempts=${PULL_RETRIES:-3}
    local delay=${PULL_RETRY_DELAY_SECONDS:-20}
    local attempt

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        echo "Pulling base image (${attempt}/${attempts}): ${image}"
        if docker pull "$image"; then
            return 0
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            sleep "$delay"
        fi
    done

    echo "Failed to pull base image after ${attempts} attempts: ${image}" >&2
    return 1
}

mkdir -p cache
echo "Downloading nginx ${NGINX_VERSION} source on host..."
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o "cache/nginx-${NGINX_VERSION}.tar.gz" || {
    echo "Failed to download nginx source" >&2
    exit 1
}

pull_image "$BASE_IMAGE"
docker build \
    --platform linux/arm64 \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg NGINX_VERSION="$NGINX_VERSION" \
    --build-arg REDIS_VERSION="$REDIS_VERSION" \
    --build-arg USE_BUNDLED_DEPS="$USE_BUNDLED_DEPS" \
    -t "$IMAGE" \
    .

IMAGE="$IMAGE" NGINX_VERSION="$NGINX_VERSION" REDIS_VERSION="$REDIS_VERSION" ./scripts/verify.sh

container_id=$(docker create "$IMAGE")
cleanup() {
    docker rm -f "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$OUTPUT_DIR/rootfs-export"
mkdir -p "$OUTPUT_DIR/rootfs-export" "$OUTPUT_DIR/dependency-audit"
docker cp "$container_id:/usr/local/nginx" "$OUTPUT_DIR/rootfs-export/nginx"
docker cp "$container_id:/opt/redis" "$OUTPUT_DIR/rootfs-export/redis"
docker cp "$container_id:/opt/java/openjdk" "$OUTPUT_DIR/rootfs-export/jdk21"
docker cp "$container_id:/opt/build-audit/." "$OUTPUT_DIR/dependency-audit/"

tar -C "$OUTPUT_DIR/rootfs-export" -czf "$OUTPUT_DIR/nginx-${NGINX_VERSION}-arm64.tar.gz" nginx
tar -C "$OUTPUT_DIR/rootfs-export" -czf "$OUTPUT_DIR/redis-${REDIS_VERSION}-arm64.tar.gz" redis
tar -C "$OUTPUT_DIR/rootfs-export" -czf "$OUTPUT_DIR/jdk21-arm64.tar.gz" jdk21
docker save "$IMAGE" | gzip > "$OUTPUT_DIR/uos1070u1-java21-redis7-nginx${NGINX_VERSION}-arm64-v1.tar.gz"

rm -rf "$OUTPUT_DIR/rootfs-export"

echo "Build complete: $IMAGE"
echo "Artifacts written to: $OUTPUT_DIR"

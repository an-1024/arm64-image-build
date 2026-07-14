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
echo "Downloading source archives on host..."
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" \
    -o "cache/nginx-${NGINX_VERSION}.tar.gz" || {
    echo "Failed to download nginx source" >&2
    exit 1
}
OPENSSL_VERSION=${OPENSSL_VERSION:-3.0.16}
PCRE_VERSION=${PCRE_VERSION:-8.45}
ZLIB_VERSION=${ZLIB_VERSION:-1.3.2}
if [ "${USE_BUNDLED_DEPS:-0}" = "1" ]; then
    curl -fsSL "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
        -o "cache/openssl-${OPENSSL_VERSION}.tar.gz" || {
        echo "Failed to download openssl source" >&2
        exit 1
    }
    curl -fsSL "https://downloads.sourceforge.net/project/pcre/pcre/${PCRE_VERSION}/pcre-${PCRE_VERSION}.tar.gz" \
        -o "cache/pcre-${PCRE_VERSION}.tar.gz" || {
        echo "Failed to download pcre source" >&2
        exit 1
    }
    curl -fsSL "https://github.com/madler/zlib/archive/refs/tags/v${ZLIB_VERSION}.tar.gz" \
        -o "cache/zlib-${ZLIB_VERSION}.tar.gz" || {
        echo "Failed to download zlib source" >&2
        exit 1
    }
fi

# Download RPMs for UOS builder (openEuler 20.03 repo)
echo "Downloading RPM packages for builder..."
RPM_BASE_URL="https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages"
RPM_DIR="cache/rpms"
mkdir -p "$RPM_DIR"
RPM_LIST=(
    binutils-2.33.1-5.oe1.aarch64.rpm
    cpp-7.3.0-20190804.h31.oe1.aarch64.rpm
    gcc-7.3.0-20190804.h31.oe1.aarch64.rpm
    gcc-c++-7.3.0-20190804.h31.oe1.aarch64.rpm
    glibc-devel-2.28-36.oe1.aarch64.rpm
    libmpc-1.1.0-3.oe1.aarch64.rpm
    make-4.2.1-15.oe1.aarch64.rpm
    tar-1.30-11.oe1.aarch64.rpm
)
for rpm in "${RPM_LIST[@]}"; do
    [ -f "$RPM_DIR/$rpm" ] && continue
    echo "  Downloading $rpm..."
    curl -fsSL "$RPM_BASE_URL/$rpm" -o "$RPM_DIR/$rpm" || {
        echo "Failed to download $rpm" >&2
        exit 1
    }
done

pull_image "$BASE_IMAGE"

pull_image "$BASE_IMAGE"
docker build \
    --platform linux/arm64 \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg NGINX_VERSION="$NGINX_VERSION" \
    --build-arg REDIS_VERSION="$REDIS_VERSION" \
    --build-arg USE_BUNDLED_DEPS="$USE_BUNDLED_DEPS" \
    --build-arg ZLIB_VERSION="$ZLIB_VERSION" \
    --build-arg OPENSSL_VERSION="$OPENSSL_VERSION" \
    --build-arg PCRE_VERSION="$PCRE_VERSION" \
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

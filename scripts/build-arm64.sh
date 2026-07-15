53cb4c6a38ad2359324bb32f2f2e19fafe8d3175
#!/bin/bash
set -euo pipefail

IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.26.2-arm64:v1}
BASE_IMAGE=${BASE_IMAGE:-ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest}
NGINX_VERSION=${NGINX_VERSION:-1.26.2}
REDIS_VERSION=${REDIS_VERSION:-7.4.0}
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

# ===== Download packages if not present locally =====
if [ ! -d packages ] || [ -z "$(ls -A packages 2>/dev/null)" ]; then
    echo "Downloading pre-built packages from GitHub Release..."
    if command -v gh >/dev/null 2>&1; then
        gh release download v1-packages --pattern "packages-arm64.tar.gz" --dir . 2>/dev/null || true
    fi
    if [ ! -f packages-arm64.tar.gz ]; then
        echo "gh failed, trying curl..."
        curl -fsSL -L "https://github.com/an-1024/arm64-image-build/releases/download/v1-packages/packages-arm64.tar.gz" \
            -o packages-arm64.tar.gz || true
    fi
    if [ ! -f packages-arm64.tar.gz ]; then
        echo "No packages found, creating empty dirs"
        mkdir -p packages tools
    fi
    if [ -f packages-arm64.tar.gz ]; then
        echo "Extracting packages..."
        tar -xzf packages-arm64.tar.gz
        rm -f packages-arm64.tar.gz
        [ -d packages-arm64 ] && mv packages-arm64 packages
        [ -d x11-deps-arm64 ] && mv x11-deps-arm64 x11-deps
    fi
fi

# Download JDK21 on the host (GitHub runner has network access)
if [ ! -f jdk21.tar.gz ]; then
    echo "Downloading JDK21..."
    curl -fsSL -L -o jdk21.tar.gz \
        "https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse?project=jdk" || {
        echo "JDK download failed, will try inside container"
    }
fi
ls -lh jdk21.tar.gz 2>/dev/null || echo "no jdk21.tar.gz (will download in container)"

# If still no packages, create empty dirs so Docker COPY doesn't fail
mkdir -p packages x11-deps

pull_image "$BASE_IMAGE"

docker build \
    --platform linux/arm64 \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg NGINX_VERSION="$NGINX_VERSION" \
    --build-arg REDIS_VERSION="$REDIS_VERSION" \
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

# Export components
docker cp "$container_id:/usr/sbin/nginx" "$OUTPUT_DIR/rootfs-export/nginx" 2>/dev/null || true
docker cp "$container_id:/usr/bin/redis-server" "$OUTPUT_DIR/rootfs-export/redis-server" 2>/dev/null || true
docker cp "$container_id:/opt/java/jdk21" "$OUTPUT_DIR/rootfs-export/jdk21" 2>/dev/null || true
docker cp "$container_id:/opt/build-audit/." "$OUTPUT_DIR/dependency-audit/" 2>/dev/null || true

# Version logs
mkdir -p "$OUTPUT_DIR/dependency-audit"
docker run --rm "$IMAGE" sh -c 'nginx -v 2>&1; redis-server --version 2>&1; java -version 2>&1; libreoffice --version 2>&1' \
    > "$OUTPUT_DIR/dependency-audit/versions.log" 2>&1 || true

# Package tarballs
tar -C "$OUTPUT_DIR/rootfs-export" -czf "$OUTPUT_DIR/nginx-${NGINX_VERSION}-arm64.tar.gz" nginx 2>/dev/null || true
tar -C "$OUTPUT_DIR/rootfs-export" -czf "$OUTPUT_DIR/jdk21-arm64.tar.gz" jdk21 2>/dev/null || true
docker save "$IMAGE" | gzip > "$OUTPUT_DIR/uos1070u1-java21-redis7-nginx${NGINX_VERSION}-arm64-v1.tar.gz"

rm -rf "$OUTPUT_DIR/rootfs-export"

echo ""
echo "Build complete: $IMAGE"
echo "Artifacts:"
ls -lh "$OUTPUT_DIR/"*.tar.gz 2>/dev/null || echo "  (no tar.gz artifacts)"
echo ""
echo "Main image archive: $OUTPUT_DIR/uos1070u1-java21-redis7-nginx${NGINX_VERSION}-arm64-v1.tar.gz"

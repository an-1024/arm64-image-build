#!/bin/bash
# =============================================================
# build-arm64.sh
# 主构建环境: Ubuntu x86_64 (10.211.55.4) + buildx + QEMU
# 构建: linux/arm64 镜像
#
# 前置条件:
#   1. 已安装 docker + buildx 插件
#   2. 已注册 QEMU (本脚本会自动注册)
#   3. 能访问 registry.uniontech.com (拉取 nginx 源镜像)
#   4. 能访问 ghcr.io (拉取 uos-20 base 镜像)
#   5. 能访问 adoptium.net (下载 JDK21)
#   6. 能访问 download.redis.io (下载 redis 源码)
#
# 可选前置:
#   - 跑过 prepare-packages.sh (仅诊断用途, 非构建必需)
#   - x11-deps/ 和 libreoffice-rpms/ 已就绪
#
# 产物:
#   artifacts/uos1070u1-runtime-arm64-v1.3.tar.gz
# =============================================================
set -euo pipefail

IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.26.2-arm64:v1.3}
BASE_IMAGE=${BASE_IMAGE:-ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest}
NGINX_SRC_IMAGE=${NGINX_SRC_IMAGE:-registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2}
REDIS_VERSION=${REDIS_VERSION:-7.4.7}
IMAGE_VERSION=${IMAGE_VERSION:-1.3}
OUTPUT_DIR=${OUTPUT_DIR:-artifacts}

echo "============================================"
echo "Build ARM64 Runtime Image v${IMAGE_VERSION}"
echo "============================================"
echo "Image:          ${IMAGE}"
echo "Base image:     ${BASE_IMAGE}"
echo "nginx source:   ${NGINX_SRC_IMAGE}"
echo "redis version:  ${REDIS_VERSION}"
echo "Output dir:     ${OUTPUT_DIR}"
echo ""

mkdir -p "$OUTPUT_DIR"

# ===== 0. 环境检查 =====
echo "[0/5] Environment check..."

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker is required" >&2
    exit 1
}
echo "  -> docker: $(docker --version)"

command -v docker buildx >/dev/null 2>&1 || {
    echo "ERROR: docker buildx is required (install: https://github.com/docker/buildx/releases)" >&2
    exit 1
}
echo "  -> buildx: $(docker buildx version)"

# 注册 QEMU (支持 x86_64 主机上运行 arm64 容器)
echo "  -> Registering QEMU for cross-platform build..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || {
    echo "ERROR: Failed to register QEMU. Try:" >&2
    echo "  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes" >&2
    exit 1
}
echo "  -> QEMU registered"

# 检查 buildx builder 是否支持 linux/arm64
if ! docker buildx inspect default 2>/dev/null | grep -q "linux/arm64"; then
    echo "  -> Creating buildx builder with arm64 support..."
    docker buildx create --name arm64builder --driver docker-container --use 2>/dev/null || true
    docker buildx inspect arm64builder --bootstrap >/dev/null 2>&1 || true
fi
echo ""

# ===== 1. 下载 JDK21 + redis 源码 =====
echo "[1/5] Downloading dependencies..."

if [ ! -f jdk21.tar.gz ]; then
    echo "  -> Downloading JDK 21 (Adoptium Temurin, aarch64)..."
    curl -fsSL -L -o jdk21.tar.gz \
        "https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse?project=jdk" \
        || { echo "ERROR: JDK download failed" >&2; exit 1; }
else
    echo "  -> jdk21.tar.gz already exists, skip"
fi
ls -lh jdk21.tar.gz

if [ ! -f "redis-${REDIS_VERSION}.tar.gz" ]; then
    echo "  -> Downloading redis ${REDIS_VERSION} source..."
    curl -fsSL -L -o "redis-${REDIS_VERSION}.tar.gz" \
        "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" \
        || { echo "ERROR: redis source download failed" >&2; exit 1; }
else
    echo "  -> redis-${REDIS_VERSION}.tar.gz already exists, skip"
fi
ls -lh "redis-${REDIS_VERSION}.tar.gz"
echo ""

# ===== 2. 检查本地依赖目录 =====
echo "[2/5] Checking local dependency directories..."

mkdir -p x11-deps libreoffice-rpms

if ls x11-deps/*.rpm >/dev/null 2>&1; then
    echo "  -> x11-deps/: $(ls x11-deps/*.rpm 2>/dev/null | wc -l) rpm files"
else
    echo "  -> WARNING: x11-deps/ is empty (LibreOffice may fail to start)"
fi

lo_rpm_count=$(find libreoffice-rpms -name "*.rpm" -type f 2>/dev/null | wc -l)
if [ "$lo_rpm_count" -gt 0 ]; then
    echo "  -> libreoffice-rpms/: ${lo_rpm_count} rpm files"
else
    echo "  -> WARNING: libreoffice-rpms/ is empty (LibreOffice will not be installed)"
fi
echo ""

# ===== 3. 拉取基础镜像和 nginx 源镜像 =====
echo "[3/5] Pulling base images..."

pull_image() {
    local image=$1
    local label=$2
    local attempts=3
    local delay=10
    local attempt

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        echo "  -> Pulling ${label} (${attempt}/${attempts}): ${image}"
        if docker pull --platform linux/arm64 "$image" 2>/dev/null || docker pull "$image"; then
            return 0
        fi
        [ "$attempt" -lt "$attempts" ] && sleep "$delay"
    done

    echo "ERROR: Failed to pull ${label} after ${attempts} attempts: ${image}" >&2
    return 1
}

pull_image "$BASE_IMAGE" "UOS base image"
pull_image "$NGINX_SRC_IMAGE" "nginx source image"
echo ""

# ===== 4. 构建镜像 =====
echo "[4/5] Building ARM64 image..."

chmod +x entrypoint.sh scripts/*.sh 2>/dev/null || true

docker buildx build \
    --platform linux/arm64 \
    --load \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg NGINX_SRC_IMAGE="$NGINX_SRC_IMAGE" \
    --build-arg REDIS_VERSION="$REDIS_VERSION" \
    --build-arg IMAGE_VERSION="$IMAGE_VERSION" \
    -t "$IMAGE" \
    .

echo "  -> Image built: $IMAGE"
echo ""

# ===== 5. 验证 + 导出 =====
echo "[5/5] Verifying and exporting..."

# 验证
IMAGE="$IMAGE" REDIS_VERSION="$REDIS_VERSION" ./scripts/verify.sh

# 导出 tarball
echo "  -> Exporting image tarball..."
TARBALL_NAME="uos1070u1-runtime-arm64-v${IMAGE_VERSION}"
docker save "$IMAGE" | gzip > "$OUTPUT_DIR/${TARBALL_NAME}.tar.gz"

echo ""
echo "============================================"
echo "Build complete: $IMAGE"
echo ""
echo "Artifacts:"
ls -lh "$OUTPUT_DIR/"*.tar.gz 2>/dev/null | sed 's/^/  /'
echo ""
echo "Main image archive:"
echo "  $OUTPUT_DIR/${TARBALL_NAME}.tar.gz"
echo ""
echo "To load on target ARM64 server:"
echo "  gzip -dc ${TARBALL_NAME}.tar.gz | docker load"
echo "============================================"

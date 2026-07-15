#!/bin/bash
# =============================================================
# prepare-packages.sh
# 在你 Mac 上运行一次，从统信 docker 镜像提取 nginx + redis
# 并下载 LibreOffice 所需的 X11 依赖包
# 最终产出: packages/ 和 x11-deps/ 目录
# 上传到 GitHub Release 后，build-arm64.sh 会下载使用
# =============================================================
set -euo pipefail

echo "============================================"
echo "Prepare Packages for ARM64 Image Build"
echo "============================================"

# ===== 1. 提取 nginx 1.26.2 =====
echo ""
echo "[1/4] Extracting nginx 1.26.2 from UnionTech image..."
docker pull registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2
cid=$(docker create registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2)

mkdir -p packages/usr/sbin packages/usr/lib64 packages/usr/share packages/etc

docker cp "$cid:/usr/sbin/nginx" packages/usr/sbin/nginx
if docker cp "$cid:/usr/lib64/nginx" packages/usr/lib64/nginx 2>/dev/null; then
    echo "  Copied nginx modules"
fi
docker cp "$cid:/etc/nginx" packages/etc/nginx 2>/dev/null || \
    mkdir -p packages/etc/nginx
docker cp "$cid:/usr/share/nginx" packages/usr/share/nginx 2>/dev/null || true

docker rm "$cid" >/dev/null
echo "  Done"

# ===== 2. 提取 redis 7.4.0 =====
echo ""
echo "[2/4] Extracting redis 7.4.0 from UnionTech image..."
docker pull registry.uniontech.com/uos-app/uos-server-25-redis:7.4.0
cid=$(docker create registry.uniontech.com/uos-app/uos-server-25-redis:7.4.0)

mkdir -p packages/usr/bin packages/etc

docker cp "$cid:/usr/bin/redis-server" packages/usr/bin/redis-server
docker cp "$cid:/usr/bin/redis-cli" packages/usr/bin/redis-cli
docker cp "$cid:/usr/bin/redis-sentinel" packages/usr/bin/redis-sentinel 2>/dev/null || true
docker cp "$cid:/etc/redis" packages/etc/redis 2>/dev/null || \
    mkdir -p packages/etc/redis

docker rm "$cid" >/dev/null
echo "  Done"

# Show what we have
echo ""
echo "[3/4] Package structure:"
find packages -type f | sort

# ===== 3. Download LibreOffice X11 deps =====
echo ""
echo "[4/4] Downloading LibreOffice X11 dependencies from openEuler 20.03 repo..."
mkdir -p x11-deps
RPM_REPO="https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages"

X11_DEPS=(
    "libXinerama-1.1.4-1.oe1.aarch64.rpm"
    "libX11-1.6.9-5.oe1.aarch64.rpm"
    "libX11-devel-1.6.9-5.oe1.aarch64.rpm"
    "libXext-1.3.4-1.oe1.aarch64.rpm"
    "libXrender-0.9.10-1.oe1.aarch64.rpm"
    "libXt-1.2.0-1.oe1.aarch64.rpm"
    "libXau-1.0.9-1.oe1.aarch64.rpm"
    "libxcb-1.13.1-1.oe1.aarch64.rpm"
)

for rpm in "${X11_DEPS[@]}"; do
    [ -f "x11-deps/$rpm" ] && echo "  Already cached: $rpm" && continue
    echo "  Downloading $rpm..."
    curl -fsSL "$RPM_REPO/$rpm" -o "x11-deps/$rpm" || {
        echo "  WARNING: Failed to download $rpm (non-fatal)"
        rm -f "x11-deps/$rpm"
    }
done

echo ""
echo "============================================"
echo "All packages prepared!"
echo ""
echo "Files to upload to GitHub Release:"
echo "  - packages/   (nginx + redis binaries)"
echo "  - x11-deps/   (X11 libraries for LibreOffice)"
echo ""
echo "Run:"
echo "  tar -czf packages-arm64.tar.gz packages/ x11-deps/"
echo ""
echo "Then create a Release and upload packages-arm64.tar.gz"
echo "============================================"

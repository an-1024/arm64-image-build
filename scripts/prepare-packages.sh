#!/bin/bash
# =============================================================
# prepare-packages.sh
# 在 Ubuntu (x86_64, 可访问外网) 上运行一次, 用于:
#   1. 从 registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2
#      提取 nginx 二进制 + 全部 ldd 依赖 .so
#   2. 检查 x11-deps/ (libXinerama 等) 是否就绪
#   3. 检查 libreoffice-rpms/ 是否就绪
#
# 产出目录结构 (供 build-arm64.sh 在 buildx 阶段使用):
#   packages/
#     nginx/usr/sbin/nginx         (二进制)
#     nginx-libs/                  (ldd 列出的全部 .so 依赖)
#     nginx-deps-manifest.txt      (依赖清单)
#     nginx/etc/nginx/             (默认配置, 作为参考)
#     nginx/usr/share/nginx/       (mime.types 等)
#   x11-deps/                      (用户已就绪, 不再下载)
#   libreoffice-rpms/              (用户已就绪, 不再下载)
#
# 注意: 本脚本只需 docker create + docker cp, 不需要 QEMU.
#       nginx 二进制是 aarch64, 但 docker cp 只是文件复制, 与主机架构无关.
# =============================================================
set -euo pipefail

NGINX_SRC_IMAGE=${NGINX_SRC_IMAGE:-registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2}

echo "============================================"
echo "Prepare Packages for ARM64 Image Build (v1.3)"
echo "============================================"
echo "nginx source image: ${NGINX_SRC_IMAGE}"
echo ""

# ===== 1. 提取 nginx 1.26.2 + 全部依赖 .so =====
echo "[1/3] Extracting nginx 1.26.2 + dependencies from UnionTech image..."
# 必须指定 --platform linux/arm64, 否则在 x86_64 主机上会拉取 x86_64 镜像
docker pull --platform linux/arm64 "${NGINX_SRC_IMAGE}"
cid=$(docker create --platform linux/arm64 "${NGINX_SRC_IMAGE}")

# 清理旧目录
rm -rf packages
mkdir -p packages/nginx/usr/sbin packages/nginx-libs packages/nginx/etc packages/nginx/usr/share

# 1.1 复制 nginx 二进制
echo "  -> Copying /usr/sbin/nginx ..."
docker cp "${cid}:/usr/sbin/nginx" packages/nginx/usr/sbin/nginx
echo "  -> nginx binary copied"

# 1.2 复制默认配置 (作为参考, Dockerfile 会用项目内的 nginx.conf 覆盖)
echo "  -> Copying /etc/nginx/ ..."
docker cp "${cid}:/etc/nginx/." packages/nginx/etc/nginx/ 2>/dev/null || \
    echo "  -> (no /etc/nginx in source image)"

# 1.3 复制 /usr/share/nginx (mime.types 等)
echo "  -> Copying /usr/share/nginx/ ..."
docker cp "${cid}:/usr/share/nginx/." packages/nginx/usr/share/nginx/ 2>/dev/null || \
    echo "  -> (no /usr/share/nginx in source image)"

# 1.4 复制 /usr/lib64 全部内容 (aarch64 系统库目录)
# 说明: uos-25 与 uos-20 的 glibc/openssl 版本可能不同,
#       必须把 nginx 运行时依赖的 .so 全部带过去, 否则跨 base 会 "not found".
#       Dockerfile runtime 阶段会把 packages/nginx-libs/*.so* cp 到 /usr/lib64/
echo "  -> Copying /usr/lib64/ (for nginx .so dependencies) ..."
docker cp "${cid}:/usr/lib64/." packages/nginx-libs/ 2>/dev/null || \
    echo "  -> (no /usr/lib64 in source image)"

docker rm "${cid}" >/dev/null
echo "  -> Done"
echo ""

# 1.5 生成依赖清单 (在 x86_64 主机上无法 ldd aarch64 二进制,
#     所以只记录 packages/nginx-libs/ 下与 nginx 相关的 .so 清单)
echo "  -> Generating dependency manifest ..."
{
    echo "# nginx dependency manifest"
    echo "# Source image: ${NGINX_SRC_IMAGE}"
    echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    echo "## nginx binary"
    ls -lh packages/nginx/usr/sbin/nginx 2>/dev/null
    echo ""
    echo "## All .so files from /usr/lib64 of source image"
    echo "## (these will be merged into runtime /usr/lib64/ and ldconfig)"
    find packages/nginx-libs -maxdepth 1 -name "*.so*" -printf "%f\n" 2>/dev/null | sort
} > packages/nginx-deps-manifest.txt
echo "  -> Manifest: packages/nginx-deps-manifest.txt"
echo ""

# ===== 2. 检查 x11-deps/ =====
echo "[2/3] Checking x11-deps/ (libXinerama etc.) ..."
if [ -d x11-deps ] && ls x11-deps/*.rpm >/dev/null 2>&1; then
    rpm_count=$(ls x11-deps/*.rpm 2>/dev/null | wc -l)
    echo "  -> OK: ${rpm_count} rpm files found"
    ls -1 x11-deps/*.rpm 2>/dev/null | sed 's/^/    /'
else
    echo "  -> WARNING: x11-deps/ is empty or missing"
    echo "     LibreOffice will fail to start with:"
    echo "       libXinerama.so.1: cannot open shared object file"
    echo "     Please download from openEuler 20.03 aarch64:"
    echo "       https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages/"
    echo "     Required: libXinerama, libX11, libXext, libXrender, libXt, libXau, libxcb"
fi
echo ""

# ===== 3. 检查 libreoffice-rpms/ =====
echo "[3/3] Checking libreoffice-rpms/ ..."
lo_rpm_count=$(find libreoffice-rpms -name "*.rpm" -type f 2>/dev/null | wc -l)
if [ "$lo_rpm_count" -gt 0 ]; then
    echo "  -> OK: ${lo_rpm_count} rpm files found"
    find libreoffice-rpms -name "*.rpm" -type f 2>/dev/null | sort | sed 's/^/    /'
else
    echo "  -> WARNING: libreoffice-rpms/ is empty or missing"
    echo "     Please download LibreOffice 26.2.x aarch64 rpm from:"
    echo "       https://zh-cn.libreoffice.org/download/libreoffice/"
    echo "     Select: Linux Aarch64 (rpm)"
    echo "     Then extract all *.rpm to libreoffice-rpms/"
fi
echo ""

# ===== 汇总 =====
echo "============================================"
echo "Packages prepared!"
echo ""
echo "Directory structure:"
find packages -maxdepth 3 -type d 2>/dev/null | sort | sed 's/^/  /'
echo ""
echo "Key files:"
echo "  - packages/nginx/usr/sbin/nginx        (nginx 1.26.2 binary, aarch64)"
echo "  - packages/nginx-libs/                 (nginx runtime .so dependencies)"
echo "  - packages/nginx-deps-manifest.txt    (dependency manifest)"
echo "  - packages/nginx/etc/nginx/            (default config, reference only)"
echo "  - packages/nginx/usr/share/nginx/      (mime.types etc.)"
echo ""
echo "Next steps:"
echo "  1. Ensure x11-deps/ and libreoffice-rpms/ are populated (if warnings above)"
echo "  2. Run: ./scripts/build-arm64.sh"
echo "============================================"

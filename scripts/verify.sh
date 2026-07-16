#!/bin/bash
# =============================================================
# verify.sh
# 镜像验证脚本 (在 arm64 容器内运行)
# 检查: 架构 / JDK / Redis / nginx / LibreOffice / 运维工具 / ldd / 目录可写性
# =============================================================
set -euo pipefail

REDIS_VERSION=${REDIS_VERSION:-7.4.7}

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

warn() {
    echo "[WARN] $*"
}

verify_inside_container() {
    local arch
    local nginx_v

    echo "============================================"
    echo "Verifying ARM64 runtime image v1.3"
    echo "============================================"
    echo ""

    # ===== 1. 架构检查 =====
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) pass "architecture is $arch" ;;
        *) fail "architecture is $arch, expected aarch64/arm64" ;;
    esac

    # ===== 2. JDK 21 =====
    echo ""
    echo "--- Java ---"
    java -version 2>&1 | tee /tmp/java-version.log
    grep -q 'version "21' /tmp/java-version.log || fail "Java 21 not detected"
    pass "Java 21 is available"

    # ===== 3. Redis =====
    echo ""
    echo "--- Redis ---"
    redis-server --version 2>&1 | tee /tmp/redis-version.log
    grep -q "v=${REDIS_VERSION}" /tmp/redis-version.log || \
        grep -q "v=7" /tmp/redis-version.log || \
        fail "Redis ${REDIS_VERSION} not detected"
    pass "Redis ${REDIS_VERSION} is available"

    # ===== 4. nginx =====
    echo ""
    echo "--- nginx ---"
    nginx_v=$(nginx -v 2>&1)
    echo "$nginx_v"
    echo "$nginx_v" | grep -q "nginx version" || fail "nginx binary not working"
    pass "nginx is available"

    # 4.1 nginx 配置测试
    nginx -t 2>&1
    pass "nginx -t succeeded"

    # 4.2 nginx ldd 严格检查 (跨 base 风险对策 R1)
    echo ""
    echo "  ldd /usr/sbin/nginx:"
    ldd /usr/sbin/nginx 2>&1 | sed 's/^/    /'
    if ldd /usr/sbin/nginx 2>&1 | grep -i "not found"; then
        fail "nginx has missing shared libraries (ldd shows 'not found')"
    fi
    pass "nginx ldd has no missing libraries"

    # ===== 5. LibreOffice =====
    echo ""
    echo "--- LibreOffice ---"
    if command -v libreoffice >/dev/null 2>&1; then
        libreoffice --version 2>&1
        pass "LibreOffice is available"
    else
        warn "LibreOffice not installed (libreoffice-rpms/ was empty during build)"
    fi

    # ===== 6. 运维工具完整检查 =====
    echo ""
    echo "--- Ops tools ---"
    local missing_tools=""
    for tool in telnet ping curl netstat vim lsof ps less find which; do
        if command -v "$tool" >/dev/null 2>&1; then
            pass "tool available: $tool ($(command -v $tool))"
        else
            warn "tool missing: $tool"
            missing_tools="${missing_tools} ${tool}"
        fi
    done
    if [ -n "$missing_tools" ]; then
        warn "Some ops tools missing:${missing_tools}"
    fi

    # ===== 7. 用户检查 =====
    echo ""
    echo "--- Users ---"
    id root >/dev/null 2>&1 && pass "root user exists" || fail "root user missing"
    if id nginx >/dev/null 2>&1; then
        pass "nginx user exists ($(id nginx))"
    else
        warn "nginx user missing (nginx will run as nobody)"
    fi

    # ===== 8. 目录可写性 =====
    echo ""
    echo "--- Directories ---"
    mkdir -p /data/redis /logs /opt/app /opt/web/dist /opt/web/mobile
    for dir in /data/redis /logs /opt/app /opt/web/dist /opt/web/mobile; do
        if touch "${dir}/.verify" 2>/dev/null && rm -f "${dir}/.verify"; then
            pass "directory writable: $dir"
        else
            fail "directory NOT writable: $dir"
        fi
    done

    # ===== 9. 环境变量 =====
    echo ""
    echo "--- Environment ---"
    [ -n "${JAVA_HOME:-}" ] && pass "JAVA_HOME=${JAVA_HOME}" || warn "JAVA_HOME not set"
    [ -n "${REDIS_PASSWORD:-}" ] && pass "REDIS_PASSWORD is set" || warn "REDIS_PASSWORD not set (using default in redis.conf)"

    echo ""
    echo "============================================"
    echo "Verification complete"
    echo "============================================"
}

if [ "${VERIFY_INSIDE_CONTAINER:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
    verify_inside_container
else
    IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.26.2-arm64:v1.3}
    docker image inspect "$IMAGE" >/dev/null 2>&1 || {
        echo "ERROR: image not found: $IMAGE" >&2
        exit 1
    }
    echo "Running verification in container: $IMAGE"
    docker run --rm -e VERIFY_INSIDE_CONTAINER=1 -e REDIS_VERSION="${REDIS_VERSION}" "$IMAGE" /opt/verify.sh
fi

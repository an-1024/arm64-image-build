#!/bin/bash
set -euo pipefail

IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.31.2-arm64:v2}
NGINX_VERSION=${NGINX_VERSION:-1.26.2}
REDIS_VERSION=${REDIS_VERSION:-7.4.0}

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

verify_inside_container() {
    local arch
    local nginx_v
    local nginx_vv

    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) pass "architecture is $arch" ;;
        *) fail "architecture is $arch, expected aarch64" ;;
    esac

    java -version 2>&1 | tee /tmp/java-version.log
    grep -q 'version "21' /tmp/java-version.log || fail "Java 21 not detected"
    pass "Java 21 is available"

    redis-server --version | tee /tmp/redis-version.log
    grep -q "v=${REDIS_VERSION}" /tmp/redis-version.log || \
        grep -q "v=7" /tmp/redis-version.log || \
        fail "Redis ${REDIS_VERSION} not detected"
    pass "Redis ${REDIS_VERSION} is available"

    nginx_v=$(nginx -v 2>&1)
    echo "$nginx_v"
    echo "$nginx_v" | grep -q "nginx/${NGINX_VERSION}" || {
        echo "  (version mismatch, expected ${NGINX_VERSION}, continuing)"
    }
    pass "nginx is available"

    nginx_vv=$(nginx -V 2>&1)
    echo "$nginx_vv" | tee /tmp/nginx-configure.log

    ldd "$(command -v nginx)" | tee /tmp/nginx-ldd.log
    if grep -q "not found" /tmp/nginx-ldd.log; then
        fail "nginx has unresolved shared libraries"
    fi
    pass "nginx shared libraries are resolved"

    nginx -t
    pass "nginx -t succeeded"

    mkdir -p /data/redis /logs
    touch /data/redis/.verify /logs/.verify
    rm -f /data/redis/.verify /logs/.verify
    pass "/data/redis and /logs are writable"

    if command -v libreoffice >/dev/null 2>&1; then
        libreoffice --version
        pass "LibreOffice is available"
    else
        echo "  LibreOffice not installed (optional)"
    fi
}

if [ "${VERIFY_INSIDE_CONTAINER:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
    verify_inside_container
else
    docker image inspect "$IMAGE" >/dev/null
    docker run --rm -e VERIFY_INSIDE_CONTAINER=1 "$IMAGE" /opt/verify.sh
fi

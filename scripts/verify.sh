#!/bin/bash
set -euo pipefail

IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.26.2-arm64:1.2}
NGINX_VERSION=${NGINX_VERSION:-1.26.2}
REDIS_VERSION=${REDIS_VERSION:-7.4.7}

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
    pass "nginx is available"

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

    if command -v netstat >/dev/null 2>&1; then
        pass "netstat is available"
    else
        echo "  netstat not installed"
    fi
    if command -v vim >/dev/null 2>&1; then
        pass "vim is available"
    else
        echo "  vim not installed"
    fi
    if command -v lsof >/dev/null 2>&1; then
        pass "lsof is available"
    else
        echo "  lsof not installed"
    fi
    if command -v ps >/dev/null 2>&1; then
        pass "procps (ps) is available"
    else
        echo "  procps not installed"
    fi
}

if [ "${VERIFY_INSIDE_CONTAINER:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
    verify_inside_container
else
    docker image inspect "$IMAGE" >/dev/null
    docker run --rm -e VERIFY_INSIDE_CONTAINER=1 "$IMAGE" /opt/verify.sh
fi

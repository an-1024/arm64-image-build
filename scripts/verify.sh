#!/bin/bash
set -euo pipefail

IMAGE=${IMAGE:-uos1070u1-java21-redis7-nginx1.31.2-arm64:v1}
NGINX_VERSION=${NGINX_VERSION:-1.30.3}
REDIS_VERSION=${REDIS_VERSION:-7.4.9}

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
    grep -q "v=${REDIS_VERSION}" /tmp/redis-version.log || fail "Redis ${REDIS_VERSION} not detected"
    pass "Redis ${REDIS_VERSION} is available"

    nginx_v=$(nginx -v 2>&1)
    echo "$nginx_v"
    echo "$nginx_v" | grep -q "nginx/${NGINX_VERSION}" || fail "nginx ${NGINX_VERSION} not detected"
    pass "nginx ${NGINX_VERSION} is available"

    nginx_vv=$(nginx -V 2>&1)
    echo "$nginx_vv" | tee /tmp/nginx-configure.log
    for required in --with-http_ssl_module --with-http_v2_module --with-pcre-jit --with-threads; do
        grep -q -- "$required" /tmp/nginx-configure.log || fail "nginx missing $required"
    done
    if grep -Eq -- '--with-http_v3_module|--with-mail' /tmp/nginx-configure.log; then
        fail "nginx contains forbidden HTTP/3 or mail modules"
    fi
    pass "nginx module set is correct"

    ldd /usr/local/nginx/sbin/nginx | tee /tmp/nginx-ldd.log
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
}

verify_entrypoint() {
    local name
    name="uos-verify-$(date +%s)"

    docker run -d --rm --name "$name" "$IMAGE" >/tmp/uos-verify-container-id
    sleep 5
    docker exec "$name" pgrep redis-server >/dev/null
    docker exec "$name" pgrep nginx >/dev/null
    docker exec "$name" redis-cli -a gaojing_5211 ping | grep -q PONG
    docker exec "$name" test -w /data/redis
    docker exec "$name" test -w /logs
    docker rm -f "$name" >/dev/null
    pass "entrypoint starts Redis and nginx and writable paths are available"
}

if [ "${VERIFY_INSIDE_CONTAINER:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
    verify_inside_container
else
    docker image inspect "$IMAGE" >/dev/null
    docker run --rm -e VERIFY_INSIDE_CONTAINER=1 "$IMAGE" /opt/verify.sh
    verify_entrypoint
fi

#!/bin/bash
set -euo pipefail

NGINX_VERSION=${NGINX_VERSION:-1.30.3}
USE_BUNDLED_DEPS=${USE_BUNDLED_DEPS:-0}
OPENSSL_VERSION=${OPENSSL_VERSION:-3.0.16}
PCRE_VERSION=${PCRE_VERSION:-8.45}
ZLIB_VERSION=${ZLIB_VERSION:-1.3.1}

BUILD_ROOT=${BUILD_ROOT:-/build}
LOG_DIR=${LOG_DIR:-/build-artifacts}
PREFIX=${PREFIX:-/usr/local/nginx}
NGINX_SRC_DIR="${BUILD_ROOT}/nginx-${NGINX_VERSION}"

mkdir -p "$BUILD_ROOT" "$LOG_DIR"

log_file="$LOG_DIR/nginx-build-audit.log"
exec > >(tee "$log_file") 2>&1

download() {
    local url=$1
    local output=$2
    local attempts=${3:-3}
    local delay=10
    local i
    for ((i = 1; i <= attempts; i++)); do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL "$url" -o "$output"; then return 0; fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q "$url" -O "$output"; then return 0; fi
        else
            echo "curl or wget is required" >&2
            exit 1
        fi
        echo "Download failed (attempt $i/$attempts), retrying in ${delay}s..." >&2
        [ "$i" -lt "$attempts" ] && sleep "$delay"
    done
    echo "Failed to download $url after $attempts attempts" >&2
    return 1
}

package_version() {
    local apt_name=$1
    local rpm_name=$2
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Version}\n' "$apt_name" 2>/dev/null || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -q "$rpm_name" 2>/dev/null || true
    fi
}

probe_environment() {
    echo "=== UOS dependency compatibility probe ==="
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "uname: $(uname -a)"
    echo "machine: $(uname -m)"
    echo

    echo "=== glibc ==="
    ldd --version || true
    echo

    echo "=== OpenSSL ==="
    openssl version -a || true
    echo "openssl package: $(package_version libssl-dev openssl-devel)"
    echo

    echo "=== PCRE / PCRE2 ==="
    pcre-config --version 2>/dev/null || true
    pcre2-config --version 2>/dev/null || true
    echo "pcre package: $(package_version libpcre3-dev pcre-devel)"
    echo "pcre2 package: $(package_version libpcre2-dev pcre2-devel)"
    echo

    echo "=== zlib ==="
    echo "zlib package: $(package_version zlib1g-dev zlib-devel)"
    grep -E '^#define ZLIB_VERSION ' /usr/include/zlib.h 2>/dev/null || true
    echo

    echo "=== compiler and binutils ==="
    gcc --version || true
    ld --version || true
    as --version || true
    echo
}

fetch_nginx() {
    cd "$BUILD_ROOT"
    download "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "nginx-${NGINX_VERSION}.tar.gz"
    tar -xzf "nginx-${NGINX_VERSION}.tar.gz"
}

fetch_bundled_deps() {
    cd "$BUILD_ROOT"
    download "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}.tar.gz"
    tar -xzf "openssl-${OPENSSL_VERSION}.tar.gz"

    download "https://downloads.sourceforge.net/project/pcre/pcre/${PCRE_VERSION}/pcre-${PCRE_VERSION}.tar.gz" "pcre-${PCRE_VERSION}.tar.gz"
    tar -xzf "pcre-${PCRE_VERSION}.tar.gz"

    download "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}.tar.gz"
    tar -xzf "zlib-${ZLIB_VERSION}.tar.gz"
}

configure_and_build() {
    local configure_args=(
        "--prefix=${PREFIX}"
        "--sbin-path=${PREFIX}/sbin/nginx"
        "--conf-path=/etc/nginx/nginx.conf"
        "--pid-path=/run/nginx.pid"
        "--lock-path=/run/nginx.lock"
        "--http-log-path=/logs/nginx.access.log"
        "--error-log-path=/logs/nginx.error.log"
        "--with-http_ssl_module"
        "--with-http_v2_module"
        "--with-pcre-jit"
        "--with-threads"
    )

    if [ "$USE_BUNDLED_DEPS" = "1" ]; then
        fetch_bundled_deps
        configure_args+=(
            "--with-openssl=${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
            "--with-pcre=${BUILD_ROOT}/pcre-${PCRE_VERSION}"
            "--with-zlib=${BUILD_ROOT}/zlib-${ZLIB_VERSION}"
        )
    fi

    cd "$NGINX_SRC_DIR"
    echo "=== nginx configure ==="
    ./configure "${configure_args[@]}"

    echo "=== nginx build ==="
    make -j"$(nproc)"
    make install
}

verify_nginx_binary() {
    local nginx_bin="${PREFIX}/sbin/nginx"
    local version_output
    local configure_output

    echo "=== nginx binary architecture ==="
    file "$nginx_bin" | tee "$LOG_DIR/nginx-file.log"
    if ! file "$nginx_bin" | grep -Eq 'aarch64|ARM aarch64|ARM64'; then
        echo "nginx binary is not aarch64" >&2
        exit 1
    fi

    echo "=== nginx -v ==="
    version_output=$("$nginx_bin" -v 2>&1)
    echo "$version_output" | tee "$LOG_DIR/nginx-version.log"
    if ! echo "$version_output" | grep -q "nginx/${NGINX_VERSION}"; then
        echo "expected nginx/${NGINX_VERSION}" >&2
        exit 1
    fi

    echo "=== nginx -V ==="
    configure_output=$("$nginx_bin" -V 2>&1)
    echo "$configure_output" | tee "$LOG_DIR/nginx-configure.log"
    for required in --with-http_ssl_module --with-http_v2_module --with-pcre-jit --with-threads; do
        if ! echo "$configure_output" | grep -q -- "$required"; then
            echo "missing nginx configure flag: $required" >&2
            exit 1
        fi
    done
    if echo "$configure_output" | grep -Eq -- '--with-http_v3_module|--with-mail'; then
        echo "nginx was built with a forbidden module" >&2
        exit 1
    fi

    echo "=== ldd nginx ==="
    ldd "$nginx_bin" | tee "$LOG_DIR/nginx-ldd.log"
    if grep -q "not found" "$LOG_DIR/nginx-ldd.log"; then
        echo "nginx has unresolved shared libraries" >&2
        exit 1
    fi

    echo "=== readelf -d nginx ==="
    readelf -d "$nginx_bin" | tee "$LOG_DIR/nginx-readelf-dynamic.log"
}

probe_environment
fetch_nginx
configure_and_build
verify_nginx_binary

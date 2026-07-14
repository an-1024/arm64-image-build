#!/bin/bash
set -euo pipefail

NGINX_VERSION=${NGINX_VERSION:-1.30.3}
USE_BUNDLED_DEPS=${USE_BUNDLED_DEPS:-0}
OPENSSL_VERSION=${OPENSSL_VERSION:-3.0.16}
PCRE_VERSION=${PCRE_VERSION:-8.45}
ZLIB_VERSION=${ZLIB_VERSION:-1.3.2}

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
    if [ -f "nginx-${NGINX_VERSION}.tar.gz" ]; then
        echo "Using pre-downloaded nginx source..."
    else
        download "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "nginx-${NGINX_VERSION}.tar.gz"
    fi
    tar -xzf "nginx-${NGINX_VERSION}.tar.gz"
}

fetch_bundled_deps() {
    cd "$BUILD_ROOT"
    if [ -f "openssl-${OPENSSL_VERSION}.tar.gz" ]; then
        echo "Using pre-downloaded openssl..."
    else
        download "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}.tar.gz"
    fi
    tar -xzf "openssl-${OPENSSL_VERSION}.tar.gz"

    if [ -f "pcre-${PCRE_VERSION}.tar.gz" ]; then
        echo "Using pre-downloaded pcre..."
    else
        download "https://downloads.sourceforge.net/project/pcre/pcre/${PCRE_VERSION}/pcre-${PCRE_VERSION}.tar.gz" "pcre-${PCRE_VERSION}.tar.gz"
    fi
    tar -xzf "pcre-${PCRE_VERSION}.tar.gz"

    if [ -f "zlib-${ZLIB_VERSION}.tar.gz" ]; then
        echo "Using pre-downloaded zlib..."
    else
        download "https://github.com/madler/zlib/archive/refs/tags/v${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}.tar.gz"
    fi
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
        "--with-cc=gcc"
    )

    if [ "$USE_BUNDLED_DEPS" = "1" ]; then
        fetch_bundled_deps
        configure_args+=(
            "--with-openssl=${BUILD_ROOT}/openssl-${OPENSSL_VERSION}"
            "--with-openssl-opt=no-apps no-tests"
            "--with-pcre=${BUILD_ROOT}/pcre-${PCRE_VERSION}"
            "--with-zlib=${BUILD_ROOT}/zlib-${ZLIB_VERSION}"
        )
    fi

    # Fix missing kernel headers in UOS base image
    mkdir -p /usr/include/asm
    cat > /usr/include/asm/sigcontext.h << 'EOF'
#ifndef _ASM_SIGCONTEXT_H
#define _ASM_SIGCONTEXT_H
#include <asm-generic/sigcontext.h>
#endif
EOF
    cat > /usr/include/asm-generic/sigcontext.h << 'EOF'
#ifndef _ASM_GENERIC_SIGCONTEXT_H
#define _ASM_GENERIC_SIGCONTEXT_H
struct sigcontext {
    unsigned long fault_address;
    unsigned long regs[31];
    unsigned long sp;
    unsigned long pc;
    unsigned long pstate;
};
#endif
EOF

    # Patch zlib 1.3.2: gzread.c missing errno.h
    if [ -f "${BUILD_ROOT}/zlib-${ZLIB_VERSION}/gzread.c" ]; then
        sed -i '1i #include <errno.h>' "${BUILD_ROOT}/zlib-${ZLIB_VERSION}/gzread.c"
    fi

    # Set CXX to gcc for PCRE configure (no g++ installed)
    export CXX=gcc

    cd "$NGINX_SRC_DIR"
    echo "=== nginx configure ==="
    # Cross-build: replace auto/types/sizeof with hardcoded aarch64 values.
    # Under QEMU the test binary cannot execute, so configure can't detect type sizes.
    cat > auto/types/sizeof << 'SIZEOFEOF'
# Copyright (C) Igor Sysoev
# Copyright (C) Nginx, Inc.

echo $ngx_n "checking for $ngx_type size ...$ngx_c"

cat << END >> $NGX_AUTOCONF_ERR
----------------------------------------
checking for $ngx_type size
END

ngx_size=
case "$ngx_type" in
    "int")          ngx_size=4 ;;
    "long")         ngx_size=8 ;;
    "long long")   ngx_size=8 ;;
    "void *")       ngx_size=8 ;;
    "sig_atomic_t") ngx_size=4 ;;
    "size_t")       ngx_size=8 ;;
    "off_t")        ngx_size=8 ;;
    "time_t")       ngx_size=8 ;;
    *)              ngx_size=4 ;;
esac
echo " $ngx_size bytes"

case $ngx_size in
    4)
        ngx_max_value=2147483647
        ngx_max_len='(sizeof("-2147483648") - 1)'
    ;;
    8)
        ngx_max_value=9223372036854775807LL
        ngx_max_len='(sizeof("-9223372036854775808") - 1)'
    ;;
esac
SIZEOFEOF
    # Cross-build: replace auto/types/typedef with hardcoded aarch64 typedefs.
    cat > auto/types/typedef << 'TYPEDEFEOF'
# Copyright (C) Igor Sysoev
# Copyright (C) Nginx, Inc.

echo $ngx_n "checking for $ngx_type ...$ngx_c"

cat << END >> $NGX_AUTOCONF_ERR
----------------------------------------
checking for $ngx_type
END

ngx_found=no

for ngx_try in $ngx_type $ngx_types
do
    echo $ngx_n " $ngx_try$ngx_c"
    if [ $ngx_try = $ngx_type ]; then
        echo " found"
        ngx_found=yes
    else
        echo ", $ngx_try used"
        ngx_found=$ngx_try
    fi
    break
done

if [ $ngx_found = no ]; then
    echo
    echo "$0: error: can not define $ngx_type"
    exit 1
fi

if [ $ngx_found != yes ]; then
    echo "typedef $ngx_found  $ngx_type;"   >> $NGX_AUTO_CONFIG_H
fi
TYPEDEFEOF
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

ARG BASE_IMAGE=ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest
ARG NGINX_VERSION=1.31.2
ARG REDIS_VERSION=7.4.9

FROM ${BASE_IMAGE} AS builder

ARG NGINX_VERSION
ARG REDIS_VERSION
ARG USE_BUNDLED_DEPS=0
ARG OPENSSL_VERSION=3.0.16
ARG PCRE_VERSION=8.45
ARG ZLIB_VERSION=1.3.2
ARG JDK_DOWNLOAD_URL=https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse?project=jdk

ENV NGINX_VERSION=${NGINX_VERSION} \
    REDIS_VERSION=${REDIS_VERSION} \
    USE_BUNDLED_DEPS=${USE_BUNDLED_DEPS} \
    OPENSSL_VERSION=${OPENSSL_VERSION} \
    PCRE_VERSION=${PCRE_VERSION} \
    ZLIB_VERSION=${ZLIB_VERSION}

RUN set -eux; \
    yum install -y openssl-devel || true; \
    dnf install -y openssl-devel || true

COPY cache/rpms/ /tmp/rpms/
RUN set -eux; \
    if ls /tmp/rpms/*.rpm >/dev/null 2>&1; then \
        rpm -ivh --nodeps --replacepkgs /tmp/rpms/*.rpm; \
        rm -rf /tmp/rpms; \
    fi; \
    if ! ls /usr/include/openssl/ssl.h >/dev/null 2>&1; then \
        curl -fsSL "https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages/openssl-devel-1.1.1d-9.oe1.aarch64.rpm" \
            -o /tmp/openssl-devel.rpm; \
        rpm -ivh --nodeps --replacepkgs /tmp/openssl-devel.rpm; \
        rm -f /tmp/openssl-devel.rpm; \
    fi; \
    if ! ls /usr/include/zlib.h >/dev/null 2>&1; then \
        curl -fsSL "https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages/zlib-devel-1.2.11-17.oe1.aarch64.rpm" \
            -o /tmp/zlib-devel.rpm; \
        rpm -ivh --nodeps --replacepkgs /tmp/zlib-devel.rpm; \
        rm -f /tmp/zlib-devel.rpm; \
    fi; \
    echo "int main(){}" | gcc -x c - -o /dev/null && echo "gcc test: OK" || echo "gcc test: FAILED"; \
    command -v cc 2>/dev/null || ln -sf "$(command -v gcc)" /usr/bin/cc

WORKDIR /build

COPY cache/*.tar.gz /build/

COPY scripts/build-nginx.sh /usr/local/bin/build-nginx.sh
RUN chmod +x /usr/local/bin/build-nginx.sh && /usr/local/bin/build-nginx.sh

RUN set -eux; \
    curl -fsSL "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" -o redis.tar.gz; \
    tar -xzf redis.tar.gz; \
    make -C "redis-${REDIS_VERSION}" -j"$(nproc)" BUILD_TLS=yes; \
    make -C "redis-${REDIS_VERSION}" PREFIX=/opt/redis install; \
    /opt/redis/bin/redis-server --version | tee /build-artifacts/redis-version.log

RUN set -eux; \
    mkdir -p /opt/java; \
    curl -fsSL -L "${JDK_DOWNLOAD_URL}" -o /tmp/jdk21-arm64.tar.gz; \
    tar -xzf /tmp/jdk21-arm64.tar.gz -C /opt/java; \
    mv /opt/java/* /opt/java/openjdk; \
    /opt/java/openjdk/bin/java -version 2>&1 | tee /build-artifacts/jdk-version.log; \
    cp /tmp/jdk21-arm64.tar.gz /build-artifacts/jdk21-arm64.tar.gz

FROM ${BASE_IMAGE} AS runtime

ARG BASE_IMAGE
ARG NGINX_VERSION
ARG REDIS_VERSION

LABEL org.opencontainers.image.title="UOS 1070U1 E ARM64 Java21 Redis7 Nginx runtime" \
      org.opencontainers.image.version="v1" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.description="UOS 1070U1 E ARM64 enterprise runtime with Java 21, Redis 7.4.9, and nginx ${NGINX_VERSION}"

RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
        rm -f /etc/apt/sources.list.d/*.list; \
        printf 'deb [trusted=yes] http://archive.debian.org/debian buster main\ndeb [trusted=yes] http://archive.debian.org/debian buster-updates main\n' \
            > /etc/apt/sources.list; \
        printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99no-check-valid-until; \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            ca-certificates bash coreutils findutils grep sed procps file; \
        rm -rf /var/lib/apt/lists/*; \
    else \
        echo "UOS base image, no package install needed"; \
    fi; \
    update-ca-certificates >/dev/null 2>&1 || true

COPY --from=builder /usr/local/nginx /usr/local/nginx
COPY --from=builder /opt/redis /opt/redis
COPY --from=builder /opt/java/openjdk /opt/java/openjdk
COPY --from=builder /build-artifacts /opt/build-audit

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY redis/redis.conf /etc/redis/redis.conf
COPY entrypoint.sh /entrypoint.sh
COPY scripts/verify.sh /opt/verify.sh

ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/java/openjdk/bin:/usr/local/nginx/sbin:/opt/redis/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_VERSION=${NGINX_VERSION} \
    REDIS_VERSION=${REDIS_VERSION}

RUN set -eux; \
    mkdir -p /opt/app /etc/nginx /etc/redis /data/redis /logs /run; \
    touch /etc/passwd /etc/group; \
    grep -q '^root:' /etc/passwd || printf 'root:x:0:0:root:/root:/bin/bash\n' >> /etc/passwd; \
    grep -q '^root:' /etc/group || printf 'root:x:0:\n' >> /etc/group; \
    mkdir -p /root; \
    cp /usr/local/nginx/conf/mime.types /etc/nginx/mime.types; \
    chmod +x /entrypoint.sh /opt/verify.sh; \
    nginx -t; \
    VERIFY_INSIDE_CONTAINER=1 /opt/verify.sh

USER 0:0
WORKDIR /opt/app
VOLUME ["/data", "/logs"]
EXPOSE 80 6379 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]

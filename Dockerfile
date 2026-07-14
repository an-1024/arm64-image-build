ARG BASE_IMAGE=registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest
ARG NGINX_VERSION=1.30.3
ARG REDIS_VERSION=7.4.9

FROM ${BASE_IMAGE} AS builder

RUN set -eu; \
    : >> /etc/passwd; \
    : >> /etc/group; \
    if ! (while IFS=: read -r name rest; do [ "$name" = "root" ] && exit 0; done < /etc/passwd; exit 1); then \
        printf 'root:x:0:0:root:/root:/bin/bash\n' >> /etc/passwd; \
    fi; \
    if ! (while IFS=: read -r name rest; do [ "$name" = "root" ] && exit 0; done < /etc/group; exit 1); then \
        printf 'root:x:0:\n' >> /etc/group; \
    fi

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
    install_apt() { \
        rm -f /etc/apt/sources.list.d/*.list; \
        printf '%s\n' \
            'deb [trusted=yes] http://archive.debian.org/debian buster main' \
            'deb [trusted=yes] http://archive.debian.org/debian buster-updates main' \
            'deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main' \
            > /etc/apt/sources.list; \
        printf '%s\n' 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            ca-certificates bash coreutils findutils grep sed curl wget tar gzip xz-utils make gcc g++ perl \
            procps file binutils libc6-dev libssl-dev zlib1g-dev \
            libpcre3-dev libpcre2-dev; \
        rm -rf /var/lib/apt/lists/*; \
    }; \
    install_yum() { \
        rm -f /etc/yum.repos.d/*.repo; \
        printf '[openeuler]\nname=openEuler 20.03 LTS\nbaseurl=https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/\nenabled=1\ngpgcheck=0\n' \
            > /etc/yum.repos.d/openeuler.repo; \
        yum install -y --allowerasing make gcc gcc-c++ binutils tar gzip; \
        yum clean all; \
    }; \
    if command -v apt-get >/dev/null 2>&1; then install_apt; \
    elif command -v dnf >/dev/null 2>&1; then yum() { dnf "$@"; }; install_yum; \
    elif command -v yum >/dev/null 2>&1; then install_yum; \
    else echo "Unsupported package manager in UOS base image" >&2; exit 1; fi; \
    update-ca-certificates >/dev/null 2>&1 || true

WORKDIR /build

# Pre-downloaded nginx source (from host before docker build)
COPY cache/ /build/

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

RUN set -eu; \
    : >> /etc/passwd; \
    : >> /etc/group; \
    if ! (while IFS=: read -r name rest; do [ "$name" = "root" ] && exit 0; done < /etc/passwd; exit 1); then \
        printf 'root:x:0:0:root:/root:/bin/bash\n' >> /etc/passwd; \
    fi; \
    if ! (while IFS=: read -r name rest; do [ "$name" = "root" ] && exit 0; done < /etc/group; exit 1); then \
        printf 'root:x:0:\n' >> /etc/group; \
    fi

ARG NGINX_VERSION
ARG REDIS_VERSION

LABEL org.opencontainers.image.title="UOS 1070U1 E ARM64 Java21 Redis7 Nginx runtime" \
      org.opencontainers.image.version="v1" \
      org.opencontainers.image.base.name="registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest" \
      org.opencontainers.image.description="UOS 1070U1 E ARM64 enterprise runtime with Java 21, Redis 7.4.9, and nginx 1.31.2"

RUN set -eux; \
    install_apt() { \
        rm -f /etc/apt/sources.list.d/*.list; \
        printf '%s\n' \
            'deb [trusted=yes] http://archive.debian.org/debian buster main' \
            'deb [trusted=yes] http://archive.debian.org/debian buster-updates main' \
            'deb [trusted=yes] http://archive.debian.org/debian-security buster/updates main' \
            > /etc/apt/sources.list; \
        printf '%s\n' 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            ca-certificates bash coreutils findutils grep sed procps file binutils openssl zlib1g libpcre3 libpcre2-8-0; \
        rm -rf /var/lib/apt/lists/*; \
    }; \
    install_yum() { \
        rm -f /etc/yum.repos.d/*.repo; \
        printf '[openeuler]\nname=openEuler 20.03 LTS\nbaseurl=https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/\nenabled=1\ngpgcheck=0\n' \
            > /etc/yum.repos.d/openeuler.repo; \
        yum install -y --allowerasing pcre pcre2; \
        yum clean all; \
    }; \
    if command -v apt-get >/dev/null 2>&1; then install_apt; \
    elif command -v dnf >/dev/null 2>&1; then yum() { dnf "$@"; }; install_yum; \
    elif command -v yum >/dev/null 2>&1; then install_yum; \
    else echo "Unsupported package manager in UOS base image" >&2; exit 1; fi; \
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

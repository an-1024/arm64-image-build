ARG BASE_IMAGE=ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest
ARG NGINX_VERSION=1.26.2
ARG REDIS_VERSION=7.4.7

FROM ${BASE_IMAGE}

ARG NGINX_VERSION
ARG REDIS_VERSION
ARG BASE_IMAGE

LABEL org.opencontainers.image.title="UOS 1070U1 E ARM64 Java21 Redis7 Nginx LibreOffice runtime" \
      org.opencontainers.image.version="1.2" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.description="UOS 1070U1 E ARM64 runtime with Java 21, Redis ${REDIS_VERSION}, nginx ${NGINX_VERSION}, LibreOffice"

# Pre-built nginx and redis from UnionTech (extracted by prepare-packages.sh)
COPY packages/ /

# X11 deps RPMs (LibreOffice)
COPY x11-deps/ /tmp/x11-deps/
RUN set -eux; \
    if ls /tmp/x11-deps/*.rpm >/dev/null 2>&1; then \
        rpm -ivh --nodeps --force /tmp/x11-deps/*.rpm; \
        rm -rf /tmp/x11-deps; \
    fi

# 运维工具 RPMs (netstat/ps/vim/lsof/ip)
COPY tools-rpms/ /tmp/tools-rpms/
RUN set -eux; \
    if ls /tmp/tools-rpms/*.rpm >/dev/null 2>&1; then \
        rpm -ivh --nodeps --force /tmp/tools-rpms/*.rpm; \
        rm -rf /tmp/tools-rpms; \
    fi

# JDK21 (pre-downloaded by build-arm64.sh)
COPY jdk21.tar.gz /tmp/jdk21.tar.gz
RUN set -eux; \
    mkdir -p /opt/java; \
    tar -xzf /tmp/jdk21.tar.gz -C /opt/java; \
    JDK_DIR=$(ls -d /opt/java/*/); \
    mv "$JDK_DIR" /opt/java/jdk21; \
    rm -f /tmp/jdk21.tar.gz

# LibreOffice: verify from base image
RUN set -eux; \
    if ! command -v libreoffice >/dev/null 2>&1; then \
        LO_DIR=$(ls -d /opt/libreoffice* 2>/dev/null || true); \
        if [ -n "$LO_DIR" ]; then \
            ln -sf "$LO_DIR/program/soffice" /usr/bin/libreoffice; \
        fi; \
    fi

# Config files
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY redis/redis.conf /etc/redis/redis.conf
COPY entrypoint.sh /entrypoint.sh
COPY scripts/verify.sh /opt/verify.sh

ENV JAVA_HOME=/opt/java/jdk21 \
    PATH=/opt/java/jdk21/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_VERSION=${NGINX_VERSION} \
    REDIS_VERSION=${REDIS_VERSION}

RUN set -eux; \
    chmod +x /entrypoint.sh /opt/verify.sh; \
    mkdir -p /opt/app /data/redis /logs /run /var/log/nginx; \
    touch /etc/passwd /etc/group; \
    grep -q '^root:' /etc/passwd || printf 'root:x:0:0:root:/root:/bin/bash\n' >> /etc/passwd; \
    grep -q '^root:' /etc/group || printf 'root:x:0:\n' >> /etc/group; \
    nginx -t 2>&1; \
    redis-server --version 2>&1; \
    java -version 2>&1; \
    libreoffice --version 2>&1 || echo "libreoffice not available"; \
    command -v netstat >/dev/null 2>&1 || echo "netstat not available"; \
    command -v vim >/dev/null 2>&1 || echo "vim not available"; \
    command -v lsof >/dev/null 2>&1 || echo "lsof not available"

USER 0:0
WORKDIR /opt/app
VOLUME ["/data", "/logs"]
EXPOSE 80 6379 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]

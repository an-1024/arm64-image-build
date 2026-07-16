ARG BASE_IMAGE=ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest
ARG NGINX_VERSION=1.26.2
ARG REDIS_VERSION=7.4.7

# ===== Builder stage: UOS 1070U1 with openEuler 20.03 repos =====
FROM ${BASE_IMAGE} AS builder

ARG NGINX_VERSION
ARG REDIS_VERSION

# Replace broken UOS repos with openEuler 20.03 public repos
RUN set -eux; \
    rm -f /etc/yum.repos.d/*.repo; \
    cat > /etc/yum.repos.d/oe2003.repo << 'REPO'
[oe2003-os]
name=openEuler 20.03 OS
baseurl=https://repo.openeuler.org/openEuler-20.03-LTS-SP2/OS/aarch64/
enabled=1
gpgcheck=0

[oe2003-epol]
name=openEuler 20.03 EPOL
baseurl=https://repo.openeuler.org/openEuler-20.03-LTS-SP2/EPOL/main/aarch64/
enabled=1
gpgcheck=0
REPO
    yum install -y gcc make pcre-devel zlib-devel openssl-devel tar gzip && yum clean all

COPY nginx-${NGINX_VERSION}.tar.gz /tmp/nginx-${NGINX_VERSION}.tar.gz
COPY redis-${REDIS_VERSION}.tar.gz /tmp/redis-${REDIS_VERSION}.tar.gz

# Compile nginx
RUN cd /tmp && tar xzf nginx-${NGINX_VERSION}.tar.gz && cd nginx-${NGINX_VERSION} && \
    ./configure --prefix=/usr/local/nginx \
        --without-http_rewrite_module \
        --with-http_ssl_module \
        --with-http_stub_status_module && \
    make -j$(nproc) && make install

# Compile redis with MALLOC=libc
RUN cd /tmp && tar xzf redis-${REDIS_VERSION}.tar.gz && cd redis-${REDIS_VERSION} && \
    make MALLOC=libc -j$(nproc) && \
    cp src/redis-server /usr/local/bin/redis-server && \
    cp src/redis-cli /usr/local/bin/redis-cli

# ===== Runtime stage: UOS 1070U1 =====
FROM ${BASE_IMAGE}

ARG NGINX_VERSION
ARG REDIS_VERSION
ARG BASE_IMAGE

LABEL org.opencontainers.image.title="UOS 1070U1 E ARM64 Java21 Redis7 Nginx LibreOffice runtime" \
      org.opencontainers.image.version="1.2" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.description="UOS 1070U1 E ARM64 runtime with Java 21, Redis ${REDIS_VERSION}, nginx ${NGINX_VERSION}, LibreOffice"

COPY --from=builder /usr/local/nginx/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/local/nginx/conf/ /etc/nginx/
COPY --from=builder /usr/local/bin/redis-server /usr/bin/redis-server
COPY --from=builder /usr/local/bin/redis-cli /usr/bin/redis-cli

COPY x11-deps/ /tmp/x11-deps/
RUN if ls /tmp/x11-deps/*.rpm >/dev/null 2>&1; then \
        rpm -ivh --nodeps --force /tmp/x11-deps/*.rpm; \
        rm -rf /tmp/x11-deps; \
    fi

COPY tools-rpms/ /tmp/tools-rpms/
RUN if ls /tmp/tools-rpms/*.rpm >/dev/null 2>&1; then \
        rpm -ivh --nodeps --force /tmp/tools-rpms/*.rpm; \
        rm -rf /tmp/tools-rpms; \
    fi

COPY jdk21.tar.gz /tmp/jdk21.tar.gz
RUN mkdir -p /opt/java && \
    tar -xzf /tmp/jdk21.tar.gz -C /opt/java && \
    JDK_DIR=$(ls -d /opt/java/*/) && \
    mv "$JDK_DIR" /opt/java/jdk21 && \
    rm -f /tmp/jdk21.tar.gz

RUN if ! command -v libreoffice >/dev/null 2>&1; then \
        LO_DIR=$(ls -d /opt/libreoffice* 2>/dev/null || true); \
        [ -n "$LO_DIR" ] && ln -sf "$LO_DIR/program/soffice" /usr/bin/libreoffice; \
    fi

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY redis/redis.conf /etc/redis/redis.conf
COPY entrypoint.sh /entrypoint.sh
COPY scripts/verify.sh /opt/verify.sh

ENV JAVA_HOME=/opt/java/jdk21 \
    PATH=/opt/java/jdk21/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NGINX_VERSION=${NGINX_VERSION} \
    REDIS_VERSION=${REDIS_VERSION}

RUN chmod +x /entrypoint.sh /opt/verify.sh && \
    mkdir -p /opt/app /data/redis /logs /run /var/log/nginx && \
    touch /etc/passwd /etc/group && \
    grep -q '^root:' /etc/passwd || printf 'root:x:0:0:root:/root:/bin/bash\n' >> /etc/passwd && \
    grep -q '^root:' /etc/group || printf 'root:x:0:\n' >> /etc/group && \
    nginx -t 2>&1 && \
    redis-server --version 2>&1 && \
    java -version 2>&1

USER 0:0
WORKDIR /opt/app
VOLUME ["/data", "/logs"]
EXPOSE 80 6379 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]

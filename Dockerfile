# syntax=docker/dockerfile:1.7
# =============================================================================
# UOS 1070U1 E ARM64 Runtime Image v1.3
# 架构: linux/arm64 (buildx + QEMU 在 x86_64 Ubuntu 上构建)
# 组件:
#   - JDK 21        (Adoptium Temurin, 下载)
#   - nginx 1.26.2  (从 uos-server-25-nginx 镜像提取二进制 + 全部依赖 .so)
#   - redis 7.4.7   (源码编译, MALLOC=libc 规避 arm64 page size 崩溃)
#   - LibreOffice   (本地 rpm, libreoffice-rpms/)
#   - X11 依赖      (本地 rpm, x11-deps/, libXinerama 等)
#   - 运维工具      (yum 安装: telnet/iputils/curl/net-tools 等)
# 运行用户: root (0:0) — 博云 PVC 挂载需要 root
# =============================================================================
ARG BASE_IMAGE=ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest
ARG NGINX_SRC_IMAGE=registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2
ARG REDIS_VERSION=7.4.7
ARG IMAGE_VERSION=1.3

# =============================================================================
# Stage 1: nginx 源 (从统信 uos-server-25-nginx:1.26.2 提取)
# 说明: 此镜像 base 是 uos-server-25, 与目标 uos-20 不一致,
#       所以必须把 ldd 列出的全部依赖 .so 一起 COPY 到 runtime 阶段.
# =============================================================================
FROM ${NGINX_SRC_IMAGE} AS nginx-src

# =============================================================================
# Stage 2: redis 编译 (在 uos-20 base 上源码编译 7.4.7)
# 说明: arm64 上 jemalloc 探测 page size 会崩溃, 用 MALLOC=libc 规避.
# =============================================================================
FROM ${BASE_IMAGE} AS redis-builder

ARG REDIS_VERSION

# 替换 UOS 损坏的 repo 为 openEuler 20.03 LTS SP2 aarch64
RUN set -eux; \
    rm -f /etc/yum.repos.d/*.repo; \
    { \
        echo '[oe2003-sp2-os]'; \
        echo 'name=openEuler 20.03 LTS SP2 OS'; \
        echo 'baseurl=https://repo.openeuler.org/openEuler-20.03-LTS-SP2/OS/aarch64/'; \
        echo 'enabled=1'; \
        echo 'gpgcheck=0'; \
        echo ''; \
        echo '[oe2003-sp2-epol]'; \
        echo 'name=openEuler 20.03 LTS SP2 EPOL'; \
        echo 'baseurl=https://repo.openeuler.org/openEuler-20.03-LTS-SP2/EPOL/main/aarch64/'; \
        echo 'enabled=1'; \
        echo 'gpgcheck=0'; \
    } > /etc/yum.repos.d/oe2003.repo; \
    yum install -y gcc make tar gzip && yum clean all

COPY redis-${REDIS_VERSION}.tar.gz /tmp/redis-${REDIS_VERSION}.tar.gz

RUN set -eux; \
    cd /tmp && tar xzf redis-${REDIS_VERSION}.tar.gz && \
    cd redis-${REDIS_VERSION} && \
    make MALLOC=libc -j$(nproc) && \
    cp src/redis-server src/redis-cli /usr/local/bin/ && \
    rm -rf /tmp/redis-${REDIS_VERSION}*

# =============================================================================
# Stage 3: runtime (最终镜像)
# =============================================================================
FROM ${BASE_IMAGE}

ARG REDIS_VERSION
ARG NGINX_SRC_IMAGE
ARG BASE_IMAGE
ARG IMAGE_VERSION

LABEL org.opencontainers.image.title="UOS 1070U1 E ARM64 Java21 Redis7 Nginx LibreOffice runtime" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.description="UOS 1070U1 E ARM64 runtime: Java 21, Redis ${REDIS_VERSION}, nginx 1.26.2, LibreOffice 26.2"

# ---------------------------------------------------------------------------
# 3.1 替换 repo + 装运维工具 (telnet/ping/curl/netstat/vim/lsof/ps 等)
#     openEuler 20.03 LTS SP2 aarch64 源与 uos-20 二进制兼容
# ---------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/*.repo; \
    { \
        echo '[oe2003-sp2-os]'; \
        echo 'name=openEuler 20.03 LTS SP2 OS'; \
        echo 'baseurl=https://repo.openeuler.org/openEuler-20.03-LTS-SP2/OS/aarch64/'; \
        echo 'enabled=1'; \
        echo 'gpgcheck=0'; \
        echo ''; \
        echo '[oe2003-sp2-epol]'; \
        echo 'name=openEuler 20.03 LTS SP2 EPOL'; \
        echo 'baseurl=https://repo.openeuler.org/openEuler-20.03-LTS-SP2/EPOL/main/aarch64/'; \
        echo 'enabled=1'; \
        echo 'gpgcheck=0'; \
    } > /etc/yum.repos.d/oe2003.repo; \
    yum install -y \
        telnet \
        iputils \
        curl \
        net-tools \
        vim \
        procps-ng \
        lsof \
        tar \
        gzip \
        findutils \
        which \
        less \
        passwd \
        cracklib-dicts \
        shadow-utils \
    && yum clean all \
    && rm -rf /var/cache/yum

# ---------------------------------------------------------------------------
# 3.2 装 X11 依赖 (libXinerama 等, LibreOffice 运行需要)
# ---------------------------------------------------------------------------
COPY x11-deps/ /tmp/x11-deps/
RUN set -eux; \
    if ls /tmp/x11-deps/*.rpm >/dev/null 2>&1; then \
        rpm -ivh --nodeps --force /tmp/x11-deps/*.rpm; \
    else \
        echo "WARNING: x11-deps/ is empty, LibreOffice may fail to start"; \
    fi; \
    rm -rf /tmp/x11-deps

# ---------------------------------------------------------------------------
# 3.3 装 LibreOffice 本体 (本地 arm rpm, 26.2.4.2)
#     目录结构兼容: libreoffice-rpms/*.rpm 或 libreoffice-rpms/RPMS/*/*.rpm
# ---------------------------------------------------------------------------
COPY libreoffice-rpms/ /tmp/libreoffice-rpms/
RUN set -eux; \
    rpm_files=$(find /tmp/libreoffice-rpms -name "*.rpm" -type f); \
    if [ -n "$rpm_files" ]; then \
        rpm -ivh --nodeps --force $rpm_files; \
        ln -sf /opt/libreoffice26.2*/program/soffice /usr/bin/libreoffice 2>/dev/null || \
        ln -sf /opt/libreoffice*/program/soffice /usr/bin/libreoffice; \
    else \
        echo "WARNING: libreoffice-rpms/ is empty, LibreOffice will not be installed"; \
    fi; \
    rm -rf /tmp/libreoffice-rpms

# ---------------------------------------------------------------------------
# 3.4 装 JDK 21 (Adoptium Temurin)
# ---------------------------------------------------------------------------
COPY jdk21.tar.gz /tmp/jdk21.tar.gz
RUN set -eux; \
    mkdir -p /opt/java && \
    tar -xzf /tmp/jdk21.tar.gz -C /opt/java && \
    JDK_DIR=$(ls -d /opt/java/jdk-21*/ 2>/dev/null | head -1) && \
    [ -n "$JDK_DIR" ] && mv "$JDK_DIR" /opt/java/jdk21 && \
    rm -f /tmp/jdk21.tar.gz

# ---------------------------------------------------------------------------
# 3.5 复制 nginx 二进制 + 全部依赖 .so (跨 base 风险对策 R1)
#     从 uos-server-25-nginx:1.26.2 整体 COPY /usr/lib64/ 过来, ldconfig 后
#     用 ldd 严格校验无 "not found"
# ---------------------------------------------------------------------------
COPY --from=nginx-src /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-src /usr/lib64/ /tmp/nginx-libs/
COPY --from=nginx-src /etc/nginx/ /etc/nginx/
COPY --from=nginx-src /usr/share/nginx/ /usr/share/nginx/

RUN set -eux; \
    # 把 nginx 运行需要的 .so 全部补到 /usr/lib64/
    find /tmp/nginx-libs -maxdepth 1 -type f \( -name "*.so*" -o -name "*.so.*" \) -exec cp -af {} /usr/lib64/ \; ; \
    find /tmp/nginx-libs -maxdepth 1 -type l -name "*.so*" -exec cp -af {} /usr/lib64/ \; ; \
    ldconfig; \
    # 严格校验: ldd 不能有 "not found"
    if ldd /usr/sbin/nginx | grep -i "not found"; then \
        echo "ERROR: nginx has missing shared libraries"; \
        ldd /usr/sbin/nginx; \
        exit 1; \
    fi; \
    rm -rf /tmp/nginx-libs

# ---------------------------------------------------------------------------
# 3.6 复制 redis 二进制 (源码编译产物)
# ---------------------------------------------------------------------------
COPY --from=redis-builder /usr/local/bin/redis-server /usr/bin/redis-server
COPY --from=redis-builder /usr/local/bin/redis-cli /usr/bin/redis-cli

# ---------------------------------------------------------------------------
# 3.7 配置文件 + 入口脚本 + 验证脚本
# ---------------------------------------------------------------------------
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY redis/redis.conf /etc/redis/redis.conf
COPY entrypoint.sh /entrypoint.sh
COPY scripts/verify.sh /opt/verify.sh

# ---------------------------------------------------------------------------
# 3.8 用户 + 目录 + 组件启动验证
# ---------------------------------------------------------------------------
RUN set -eux; \
    # 确保 root 用户存在
    touch /etc/passwd /etc/group; \
    grep -q '^root:' /etc/passwd || printf 'root:x:0:0:root:/root:/bin/bash\n' >> /etc/passwd; \
    grep -q '^root:' /etc/group || printf 'root:x:0:\n' >> /etc/group; \
    # 创建 nginx 用户 (无登录权限, 仅用于 nginx worker process)
    if ! getent group nginx >/dev/null 2>&1; then groupadd -r nginx; fi; \
    if ! id nginx >/dev/null 2>&1; then useradd -r -g nginx -s /sbin/nologin -d /var/lib/nginx nginx; fi; \
    mkdir -p /var/lib/nginx /var/log/nginx /run; \
    # 创建业务挂载点目录
    mkdir -p /opt/app /opt/web/dist /opt/web/mobile /data/redis /logs; \
    chmod +x /entrypoint.sh /opt/verify.sh; \
    # 组件启动验证
    nginx -t 2>&1; \
    redis-server --version 2>&1; \
    java -version 2>&1; \
    if command -v libreoffice >/dev/null 2>&1; then libreoffice --version 2>&1; fi

ENV JAVA_HOME=/opt/java/jdk21 \
    PATH=/opt/java/jdk21/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    REDIS_VERSION=${REDIS_VERSION} \
    NGINX_VERSION=1.26.2 \
    REDIS_PASSWORD=gaojing_5211

USER 0:0
WORKDIR /opt/app
VOLUME ["/data", "/logs", "/opt/app", "/opt/web/dist", "/opt/web/mobile"]
EXPOSE 80 6379 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]

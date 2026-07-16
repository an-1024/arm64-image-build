# UOS 1070U1 E ARM64 Runtime Image v1.3

基于统信 UOS Server 1070U1 E 最小系统构建的 ARM64 运行时镜像, 用于博云平台 k8s 部署低代码平台.

## 镜像组成

| 组件 | 版本 | 来源 |
|---|---|---|
| Base | uos-server-20-1070u1e | `ghcr.io/an-1024/uos-server-20-1070u1e-arm64:latest` |
| JDK | 21 (Eclipse Temurin) | Adoptium 下载 aarch64 tarball |
| nginx | 1.26.2 | 从 `registry.uniontech.com/uos-app/uos-server-25-nginx:1.26.2` 提取二进制 + 全部依赖 `.so` |
| Redis | 7.4.7 | 源码编译, `MALLOC=libc` (规避 arm64 page size 崩溃) |
| LibreOffice | 26.2.x | 本地 arm rpm (`libreoffice-rpms/`) |
| X11 依赖 | libXinerama 等 | 本地 arm rpm (`x11-deps/`) |
| 运维工具 | telnet/ping/curl/netstat/vim/lsof/ps | openEuler 20.03 LTS SP2 aarch64 源 yum 安装 |

## 构建环境

**主路径**: Ubuntu x86_64 虚拟机 (10.211.55.4) + Docker buildx + QEMU

```
Mac (开发)  →  Ubuntu (构建)  →  tarball  →  博云运维机 (docker load)
```

GitHub Actions 仅作为可选 CI 备份路径.

## 目录结构

```text
project/
  Dockerfile                    # 3 阶段构建: nginx-extract + redis-builder + runtime
  docker-compose.yml
  entrypoint.sh                 # 启动 redis + nginx + (可选) Java 应用
  nginx/
    nginx.conf                  # user nginx + /opt/web/dist + /mobile/ 路由
  redis/
    redis.conf                  # 密码 env 化 (REDIS_PASSWORD)
  scripts/
    prepare-packages.sh         # 诊断工具: 提取 nginx 二进制 + 依赖 .so
    build-arm64.sh              # 主构建脚本: buildx + QEMU + 验证 + 导出
    verify.sh                   # 镜像验证: ldd / 版本 / 运维工具 / 目录
  x11-deps/                     # LibreOffice X11 依赖 (libXinerama 等 rpm)
  libreoffice-rpms/             # LibreOffice 本体 arm rpm
  .github/workflows/
    build-arm64.yml             # 可选 CI
    security-scan.yml           # 可选 Trivy 扫描
```

## 构建步骤

### 1. 准备依赖 (一次性)

#### 1.1 X11 依赖 (libXinerama 等)

从 openEuler 20.03 aarch64 下载到 `x11-deps/`:
- libXinerama, libX11, libX11-devel, libXext, libXrender, libXt, libXau, libxcb

下载地址: https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages/

#### 1.2 LibreOffice arm rpm

从官网下载 26.2.x aarch64 rpm 到 `libreoffice-rpms/`:
- https://zh-cn.libreoffice.org/download/libreoffice/
- 选择: Linux Aarch64 (rpm)
- 解压后把 `RPMS/aarch64/*.rpm` 全部放入 `libreoffice-rpms/`

### 2. 构建镜像

在 Ubuntu 上执行:

```bash
chmod +x entrypoint.sh scripts/*.sh
./scripts/build-arm64.sh
```

`build-arm64.sh` 会自动:
1. 检查 Docker + buildx + QEMU
2. 注册 QEMU (支持 x86_64 构建 arm64)
3. 下载 JDK21 + redis 7.4.7 源码
4. 检查 `x11-deps/` 和 `libreoffice-rpms/` 是否就绪
5. 拉取 UOS base 镜像和 nginx 源镜像
6. `docker buildx build --platform linux/arm64 --load`
7. 运行 `verify.sh` 验证
8. `docker save | gzip` 导出 tarball

产物: `artifacts/uos1070u1-runtime-arm64-v1.3.tar.gz`

### 3. 验证

```bash
IMAGE=uos1070u1-java21-redis7-nginx1.26.2-arm64:v1.3 ./scripts/verify.sh
```

验证项:
- 架构是 aarch64/arm64
- Java 21 可用
- Redis 7.4.7 可用
- nginx 1.26.2 可用, `nginx -t` 通过
- nginx `ldd` 无 "not found" (跨 base 依赖检查)
- LibreOffice 可用 (如果 rpm 已就绪)
- 运维工具完整: telnet/ping/curl/netstat/vim/lsof/ps
- root 和 nginx 用户存在
- 挂载目录可写: /data/redis /logs /opt/app /opt/web/dist /opt/web/mobile

### 4. 诊断 (可选)

```bash
./scripts/prepare-packages.sh
```

诊断用途: 从 uniontech 镜像提取 nginx 二进制和依赖 .so, 生成清单. 非构建必需 (Dockerfile 直接 `FROM nginx-src` 阶段提取).

## 运行

### PVC 挂载清单

| 容器路径 | 用途 | 说明 |
|---|---|---|
| `/opt/app` | app.jar | Java 应用主 jar |
| `/opt/web/dist` | 前端桌面资源 | dist 静态文件 |
| `/opt/web/mobile` | 前端移动端资源 | mobile 静态文件 |
| `/data` | Redis 数据 | /data/redis 子目录 |
| `/logs` | 日志 | nginx/redis/app 日志 |

博云平台创建 PVC (storageclass + 单主机读写模式), 挂载到上述路径.

### 启动

```bash
docker run --rm -d --name runtime \
  -p 80:80 -p 6379:6379 \
  -v /path/to/app:/opt/app \
  -v /path/to/dist:/opt/web/dist \
  -v /path/to/mobile:/opt/web/mobile \
  -v runtime-data:/data \
  -v runtime-logs:/logs \
  -e REDIS_PASSWORD="your_password" \
  -e JAVA_OPTS="-XX:MaxRAMPercentage=75" \
  uos1070u1-java21-redis7-nginx1.26.2-arm64:v1.3
```

如果 `/opt/app/app.jar` 存在, entrypoint 会自动用 Java 21 启动.

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `REDIS_PASSWORD` | gaojing_5211 (redis.conf 内) | Redis 密码, 覆盖 redis.conf |
| `APP_JAR` | /opt/app/app.jar | Java 应用 jar 路径 |
| `JAVA_OPTS` | (空) | JVM 参数 |
| `APP_ARGS` | (空) | 应用启动参数 |

## 交付

构建完成后, 把 `artifacts/uos1070u1-runtime-arm64-v1.3.tar.gz` 上传到博云运维机:

```bash
gzip -dc uos1070u1-runtime-arm64-v1.3.tar.gz | docker load
```

后续博云侧发版由运维处理.

## 风险与对策

| 风险 | 对策 |
|---|---|
| nginx 从 uos-25 提取到 uos-20, glibc/openssl 不匹配 | Dockerfile 把 `/usr/lib64/` 全部 `.so` 一起 COPY, `ldconfig` 后 `ldd` 严格校验 |
| redis 7.4.0 arm64 page size 崩溃 | 用 7.4.7 源码编译 + `MALLOC=libc` |
| LibreOffice 缺 libXinerama | `x11-deps/` rpm 强装 |
| nginx CVE-2026-42530 系列 | 1.26.2 已修复; 当前 nginx.conf 用 try_files 不触发漏洞模式 |

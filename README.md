# UOS 1070U1 E ARM64 Enterprise Runtime Image

Build ARM64 Docker image with JDK 21, Redis 7.4.9, nginx 1.31.2, and LibreOffice, deployable to offline UOS ARM64 servers or K8s clusters.

## Components

| 组件 | 版本 | 安装方式 |
|------|------|----------|
| OpenJDK | 21 (Eclipse Temurin) | tarball 下载 |
| Redis | 7.4.9 | 源码编译 + TLS |
| nginx | 1.31.2 | 源码编译 (ssl, http2, pcre-jit) |
| OpenSSL | 3.0.16 | 源码编译 (供 Redis TLS 使用) |
| LibreOffice | 按需 | rpm/ 目录离线 RPM 安装 |

## 前置准备

### 1. LibreOffice RPM 离线包

从 openEuler 20.03 LTS ARM64 仓库下载 LibreOffice RPM 包，放入 `rpm/` 目录：

```bash
# 在某台有网络的 ARM64 机器（或通过 QEMU 模拟）下载
# openEuler 20.03 LTS aarch64 repo 地址：
# https://repo.openeuler.org/openEuler-20.03-LTS/OS/aarch64/Packages/
# 需要的包示例（版本号以实际仓库为准）：
#   libreoffice-*.aarch64.rpm
#   libreoffice-calc-*.aarch64.rpm
#   libreoffice-writer-*.aarch64.rpm
#   libreoffice-impress-*.aarch64.rpm
#   libreoffice-gtk3-*.aarch64.rpm
#   libwpd-*.aarch64.rpm
#   libwpg-*.aarch64.rpm

mkdir -p rpm
# 将所有 .rpm 放入 rpm/ 目录
git add rpm/*.rpm
```

> 提示：LibreOffice 依赖较多，`--nodeps` 安装可能在运行时因缺失共享库而失败。
> 建议至少包含 `libX11`、`fontconfig`、`cairo` 等基础图形库的 RPM。

### 2. 基础镜像

`registry.uniontech.com` 在 GitHub Actions runner 上不可达（已验证），需先在本地 pull 后推送到 GHCR：

```bash
# 在本地（Mac/有权限访问 UOS registry 的机器）执行
docker pull registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest
docker tag registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest ghcr.io/<你的用户名>/uos-server-20-1070u1e-arm64:latest
docker push ghcr.io/<你的用户名>/uos-server-20-1070u1e-arm64:latest
```

然后在 GitHub 仓库 Settings → Secrets and variables → Actions 中添加：
- `GHCR_USERNAME` = GitHub 用户名
- `GHCR_TOKEN` = 有 `packages:write` 权限的 Personal Access Token

## 项目结构

```
project/
  Dockerfile               # 两阶段构建 (builder + runtime)
  entrypoint.sh            # 容器进程管理 (Redis + nginx + Java)
  docker-compose.yml
  rpm/                     # LibreOffice RPM 离线包（用户放置）
  nginx/nginx.conf
  redis/redis.conf
  scripts/
    build-arm64.sh          # 构建入口（下载依赖 + docker build + 导出）
    build-nginx.sh          # nginx 编译脚本（含 QEMU cross-build 补丁）
    verify.sh               # 镜像验证
  .github/workflows/
    build-arm64.yml         # CI: 构建 + 验证 + 导出 tar artifact
    security-scan.yml       # CI: Trivy 安全扫描
```

## 构建

### GitHub Actions（推荐）

```bash
git push origin main
```

Workflow 自动触发：
1. 设置 QEMU ARM64 模拟 + Docker Buildx
2. 下载 nginx/Redis/OpenSSL 源码
3. 下载 gcc 等编译依赖 RPM（openEuler 20.03 aarch64 repo）
4. Docker buildx 构建 ARM64 镜像
5. 验证镜像完整性
6. 导出组件 tar.gz + 完整镜像 tar
7. 上传 Artifact（保留 30 天）

### 本地 ARM64 主机

```bash
chmod +x entrypoint.sh scripts/*.sh
./scripts/build-arm64.sh
```

### 本地 x86_64（QEMU 模拟）

```bash
ALLOW_NON_ARM64_BUILD=1 ./scripts/build-arm64.sh
```

## 离线部署

### 1. 从 GitHub Actions 下载产物

Workflow 运行成功后，进入 Actions 页面 → 对应运行记录 → Artifacts → 下载 `uos1070u1-runtime-arm64`

### 2. 传输到目标服务器

将 tar 包拷贝到离线 UOS 服务器（U 盘 / 内网 SCP）：

```bash
# 解压后得到完整镜像 tar
tar -xzf uos1070u1-runtime-arm64.tar.gz
ls artifacts/
```

### 3. 导入镜像

```bash
# 方法一：直接导入 gzip tar
gzip -dc artifacts/uos1070u1-java21-redis7-nginx1.31.2-arm64-v1.tar.gz | docker load

# 方法二（如果 artifacts 中包含 raw tar）
docker load -i artifacts/uos1070u1-java21-redis7-nginx1.31.2-arm64.tar

docker images | grep uos1070u1
```

### 4. 启动容器

#### Docker Run（单机）

```bash
docker run -d \
  --name uos-runtime \
  --restart unless-stopped \
  -p 80:80 \
  -p 6379:6379 \
  -p 8080:8080 \
  -v /data/uos-app:/opt/app \
  -v /data/uos-redis:/data/redis \
  -v /data/uos-logs:/logs \
  uos1070u1-java21-redis7-nginx1.31.2-arm64:v1
```

#### K8s Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uos-runtime
spec:
  replicas: 1
  selector:
    matchLabels:
      app: uos-runtime
  template:
    metadata:
      labels:
        app: uos-runtime
    spec:
      containers:
      - name: runtime
        image: uos1070u1-java21-redis7-nginx1.31.2-arm64:v1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        - containerPort: 6379
        - containerPort: 8080
        env:
        - name: JAVA_OPTS
          value: "-XX:MaxRAMPercentage=75"
        volumeMounts:
        - name: app
          mountPath: /opt/app
        - name: data
          mountPath: /data
        - name: logs
          mountPath: /logs
      volumes:
      - name: app
        persistentVolumeClaim:
          claimName: uos-app
      - name: data
        persistentVolumeClaim:
          claimName: uos-data
      - name: logs
        persistentVolumeClaim:
          claimName: uos-logs
---
apiVersion: v1
kind: Service
metadata:
  name: uos-runtime
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: redis
    port: 6379
    targetPort: 6379
  - name: java
    port: 8080
    targetPort: 8080
  selector:
    app: uos-runtime
```

> 注意：此镜像不需要 `--privileged`，不需要 systemd 支持，适用于标准 K8s 环境。

### 5. 验证

```bash
# 检查容器
docker ps | grep uos-runtime

# 检查 nginx
curl -s http://localhost/healthz

# 检查 Redis
redis-cli -h localhost -p 6379 -a gaojing_5211 ping
# 应返回 PONG

# 检查 JDK
docker exec uos-runtime java -version

# 检查 LibreOffice（如果已安装 RPM）
docker exec uos-runtime libreoffice --version
```

## 默认配置

| 项目 | 值 |
|------|----|
| nginx 监听 | 0.0.0.0:80 |
| Redis 监听 | 0.0.0.0:6379 |
| Redis 密码 | gaojing_5211（修改 redis/redis.conf） |
| Java 应用 | /opt/app/app.jar（自动检测启动） |
| 持久化数据 | /data/redis, /logs |

## 验证脚本

```bash
IMAGE=uos1070u1-java21-redis7-nginx1.31.2-arm64:v1 ./scripts/verify.sh
```

验证项：架构检测、JDK 版本、Redis 版本、nginx 版本与模块集、ldd 完整性、nginx 配置合规、目录可写、entrypoint 启动正常。

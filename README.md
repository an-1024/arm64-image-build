# UOS 1070U1 E ARM64 Enterprise Runtime Image

This project builds an ARM64 runtime image based on:

```text
registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest
```

Target image:

```text
uos1070u1-java21-redis7-nginx1.31.2-arm64:v1
```

The image contains Eclipse Temurin OpenJDK 21, Redis 7.4.9, and nginx 1.31.2. The runtime stage explicitly runs as UID/GID `0:0`, restores root entries in `/etc/passwd` and `/etc/group` when they are missing, and installs the basic Linux command packages required by the entrypoint and verification scripts. nginx is compiled inside the UOS 1070U1 E build stage so glibc, OpenSSL, PCRE/PCRE2, zlib, and linker compatibility are validated against the same OS family used at runtime.

## Layout

```text
project/
  Dockerfile
  docker-compose.yml
  entrypoint.sh
  nginx/nginx.conf
  redis/redis.conf
  scripts/build-nginx.sh
  scripts/build-arm64.sh
  scripts/verify.sh
  .github/workflows/build-arm64.yml
  .github/workflows/security-scan.yml
```

## Build

Run from `project/` on a native ARM64 host:

```bash
chmod +x entrypoint.sh scripts/*.sh
./scripts/build-arm64.sh
```

The script pulls the UOS base image, builds the final image, runs verification, and writes artifacts to `project/artifacts/`:

- `nginx-1.31.2-arm64.tar.gz`
- `redis-7.4.9-arm64.tar.gz`
- `jdk21-arm64.tar.gz`
- `uos1070u1-java21-redis7-nginx1.31.2-arm64-v1.tar.gz`
- `dependency-audit/`

Useful overrides:

```bash
BASE_IMAGE=registry.uniontech.com/uos-server-base/uos-server-20-1070u1e:latest ./scripts/build-arm64.sh
USE_BUNDLED_DEPS=1 ./scripts/build-arm64.sh
```

`USE_BUNDLED_DEPS=1` builds OpenSSL, PCRE, and zlib from source inside the UOS builder stage and links nginx against that source build. Use it only when UOS repository development packages are too old, unavailable, or fail the vulnerability gate.

## nginx Build Policy

Enabled nginx configure flags:

- `--with-http_ssl_module`
- `--with-http_v2_module`
- `--with-pcre-jit`
- `--with-threads`

Forbidden modules:

- HTTP/3 module
- mail modules

`requires` policy: do not use Ubuntu/Debian prebuilt nginx, OpenSSL, PCRE, or zlib artifacts. System packages must come from the UOS base repositories, or dependencies must be compiled from source inside the UOS builder stage.

`scripts/build-nginx.sh` records the following audit data in `/opt/build-audit` inside the final image:

- `uname -a`
- `ldd --version`
- `openssl version -a`
- `pcre-config --version` or `pcre2-config --version`
- zlib package/header version
- gcc and binutils versions
- `nginx -v`
- `nginx -V`
- `ldd /usr/local/nginx/sbin/nginx`
- `readelf -d /usr/local/nginx/sbin/nginx`

## Redis

Redis listens on `0.0.0.0:6379`, stores data in `/data/redis`, and requires this password by default:

```text
gaojing_5211
```

Override `redis/redis.conf` for environment-specific password management before production deployment.

## Verify

Run:

```bash
IMAGE=uos1070u1-java21-redis7-nginx1.31.2-arm64:v1 ./scripts/verify.sh
```

Verification checks:

- container architecture is `aarch64` or `arm64`
- Java 21 is available
- Redis 7.4.9 is available
- nginx version is 1.31.2
- nginx contains the required modules
- nginx does not contain HTTP/3 or mail modules
- `ldd` has no `not found` entries
- `nginx -t` passes in the runtime image
- `/data/redis` and `/logs` are writable
- the default entrypoint starts Redis and nginx

## GitHub Actions Build

Use this path when you do not have a local ARM64 machine:

1. Push the repository to GitHub.
2. If the UOS Harbor registry requires login, add repository secrets `UNIONTECH_REGISTRY_USERNAME` and `UNIONTECH_REGISTRY_PASSWORD`.
3. Open `Actions` -> `Build ARM64 Runtime` -> `Run workflow`.
4. Keep `base_image` as the default UOS image if GitHub-hosted runners can reach `registry.uniontech.com`, or replace it with a mirrored base image such as `ghcr.io/<owner>/<image>:<tag>`.
5. Keep `use_bundled_deps` as `0` for UOS system dependencies, or set it to `1` to compile OpenSSL/PCRE/zlib from source inside the UOS builder stage.
6. Download the `uos1070u1-runtime-arm64` artifact after the workflow succeeds.

The downloaded artifact contains the final image tar:

```text
uos1070u1-java21-redis7-nginx1.31.2-arm64-v1.tar.gz
```

Load it on the target ARM64 server:

```bash
gzip -dc uos1070u1-java21-redis7-nginx1.31.2-arm64-v1.tar.gz | docker load
```
## Runtime

Default directories:

- application: `/opt/app`
- nginx config: `/etc/nginx/nginx.conf`
- Redis config: `/etc/redis/redis.conf`
- persistent data: `/data`
- Redis data: `/data/redis`
- logs: `/logs`

Default startup runs Redis and nginx. If `/opt/app/app.jar` exists, the entrypoint starts it with Java 21:

```bash
docker run --rm -p 80:80 -p 6379:6379 \
  -v "$PWD/app:/opt/app" \
  -v runtime-data:/data \
  -v runtime-logs:/logs \
  uos1070u1-java21-redis7-nginx1.31.2-arm64:v1
```

Override the Java application path with `APP_JAR`, JVM options with `JAVA_OPTS`, and application arguments with `APP_ARGS`.

## CI/CD

`.github/workflows/build-arm64.yml` runs on GitHub-hosted `ubuntu-latest`, enables QEMU ARM64 emulation, builds `linux/arm64`, verifies the image under emulation, and uploads the component tarballs, final image tarball, and dependency audit logs. If `registry.uniontech.com` requires authentication, configure repository secrets `UNIONTECH_REGISTRY_USERNAME` and `UNIONTECH_REGISTRY_PASSWORD`.

`.github/workflows/security-scan.yml` also runs on `ubuntu-latest` with QEMU and runs Trivy against the ARM64 image. HIGH and CRITICAL findings fail the workflow, and JSON/SARIF reports are uploaded for audit.

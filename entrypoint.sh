#!/bin/bash
# =============================================================
# entrypoint.sh
# 容器入口: 启动 redis + nginx + (可选) Java 应用
# 说明:
#   - 如果设置了 REDIS_PASSWORD 环境变量, 动态替换 redis.conf 中的密码
#   - 启动前做组件版本检查和 nginx -t 配置测试
#   - 单容器多进程, TERM/INT 信号优雅停止全部进程
# =============================================================
set -euo pipefail

export MALLOC=libc

REDIS_CONF=${REDIS_CONF:-/etc/redis/redis.conf}
NGINX_CONF=${NGINX_CONF:-/etc/nginx/nginx.conf}
APP_JAR=${APP_JAR:-/opt/app/app.jar}

mkdir -p /data/redis /logs /run /var/log/nginx

# ----- 非 serve 模式: 直接 exec 用户命令 (用于调试) -----
if [ "${1:-serve}" != "serve" ]; then
    exec "$@"
fi

echo "============================================"
echo "Starting UOS 1070U1 E ARM64 Runtime v1.3"
echo "============================================"

# ----- 组件版本日志 -----
echo "[entrypoint] Component versions:"
echo "  arch:       $(uname -m)"
java -version 2>&1 | head -1 | sed 's/^/  java:       /'
redis-server --version 2>&1 | sed 's/^/  redis:      /'
nginx -v 2>&1 | sed 's/^/  nginx:      /'
if command -v libreoffice >/dev/null 2>&1; then
    libreoffice --version 2>&1 | head -1 | sed 's/^/  libreoffice:/'
fi
echo ""

# ----- redis 密码 env 化 -----
# 如果设置了 REDIS_PASSWORD 环境变量, 替换 redis.conf 中的默认密码
if [ -n "${REDIS_PASSWORD:-}" ]; then
    echo "[entrypoint] Applying REDIS_PASSWORD from environment variable..."
    # 用 sed 替换 requirepass 行 (生成临时配置, 不修改原文件)
    sed "s/^requirepass .*/requirepass ${REDIS_PASSWORD}/" "$REDIS_CONF" > /tmp/redis.runtime.conf
    REDIS_CONF=/tmp/redis.runtime.conf
    echo "[entrypoint] Redis password updated from REDIS_PASSWORD env"
else
    echo "[entrypoint] Using default password from redis.conf"
fi

# ----- 启动前检查 -----
echo "[entrypoint] Pre-flight checks:"
# nginx 配置测试
if ! nginx -t -c "$NGINX_CONF" 2>&1; then
    echo "[entrypoint] ERROR: nginx config test failed" >&2
    exit 1
fi
echo "[entrypoint]   -> nginx config OK"

# redis 配置测试 (启动后立即检查, 不阻塞)
echo "[entrypoint]   -> redis config: $REDIS_CONF"
echo ""

# ----- 启动 Redis -----
echo "[entrypoint] Starting Redis..."
redis-server "$REDIS_CONF" &
redis_pid=$!
echo "[entrypoint]   -> Redis PID: $redis_pid"

# ----- 启动 nginx -----
echo "[entrypoint] Starting nginx..."
nginx -c "$NGINX_CONF" -g "daemon off;" &
nginx_pid=$!
echo "[entrypoint]   -> nginx PID: $nginx_pid"

# ----- 启动 Java 应用 (可选) -----
app_pid=""
if [ -f "$APP_JAR" ]; then
    echo "[entrypoint] Starting Java application: $APP_JAR"
    echo "[entrypoint]   JAVA_OPTS: ${JAVA_OPTS:-<none>}"
    echo "[entrypoint]   APP_ARGS:  ${APP_ARGS:-<none>}"
    java ${JAVA_OPTS:-} -jar "$APP_JAR" ${APP_ARGS:-} &
    app_pid=$!
    echo "[entrypoint]   -> App PID: $app_pid"
else
    echo "[entrypoint] No Java application jar found at $APP_JAR; running Redis and nginx only."
fi

echo ""
echo "[entrypoint] All services started. Waiting..."
echo "============================================"

# ----- 优雅停止函数 -----
stop_services() {
    echo ""
    echo "[entrypoint] Received stop signal, shutting down..."
    [ -n "$app_pid" ] && kill "$app_pid" >/dev/null 2>&1 || true
    kill "$redis_pid" "$nginx_pid" >/dev/null 2>&1 || true
    [ -n "$app_pid" ] && wait "$app_pid" >/dev/null 2>&1 || true
    wait "$redis_pid" "$nginx_pid" >/dev/null 2>&1 || true
    echo "[entrypoint] All services stopped."
}
trap stop_services TERM INT

# ----- 进程监控循环 -----
# 任意核心进程退出则停止全部
while true; do
    for pid in "$redis_pid" "$nginx_pid" ${app_pid:+$app_pid}; do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            wait "$pid" || exit_code=$?
            echo "[entrypoint] Process $pid exited with code ${exit_code:-unknown}" >&2
            stop_services
            exit "${exit_code:-1}"
        fi
    done
    sleep 2
done

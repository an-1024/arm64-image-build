#!/bin/bash
set -euo pipefail

REDIS_CONF=${REDIS_CONF:-/etc/redis/redis.conf}
NGINX_CONF=${NGINX_CONF:-/etc/nginx/nginx.conf}
APP_JAR=${APP_JAR:-/opt/app/app.jar}

mkdir -p /data/redis /logs /run

if [ "${1:-serve}" != "serve" ]; then
    exec "$@"
fi

echo "Starting Redis..."
redis-server "$REDIS_CONF" &
redis_pid=$!

echo "Starting nginx..."
nginx -c "$NGINX_CONF" -g "daemon off;" &
nginx_pid=$!

app_pid=""
if [ -f "$APP_JAR" ]; then
    echo "Starting Java application: $APP_JAR"
    java ${JAVA_OPTS:-} -jar "$APP_JAR" ${APP_ARGS:-} &
    app_pid=$!
else
    echo "No Java application jar found at $APP_JAR; running Redis and nginx only."
fi

stop_services() {
    [ -n "$app_pid" ] && kill "$app_pid" >/dev/null 2>&1 || true
    kill "$redis_pid" "$nginx_pid" >/dev/null 2>&1 || true
    [ -n "$app_pid" ] && wait "$app_pid" >/dev/null 2>&1 || true
    wait "$redis_pid" "$nginx_pid" >/dev/null 2>&1 || true
}
trap stop_services TERM INT

while true; do
    for pid in "$redis_pid" "$nginx_pid" ${app_pid:+$app_pid}; do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            wait "$pid" || exit_code=$?
            stop_services
            exit "${exit_code:-1}"
        fi
    done
    sleep 2
done

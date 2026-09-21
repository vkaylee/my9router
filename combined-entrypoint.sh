#!/bin/sh
set -eu

mkdir -p /tmp/nginx /app/data /app/data-home

go_stdout_fifo=/tmp/nginx/9router-go.stdout
go_stderr_fifo=/tmp/nginx/9router-go.stderr
dashboard_stdout_fifo=/tmp/nginx/dashboard.stdout
dashboard_stderr_fifo=/tmp/nginx/dashboard.stderr
nginx_stdout_fifo=/tmp/nginx/nginx.stdout
nginx_stderr_fifo=/tmp/nginx/nginx.stderr

for fifo in \
  "$go_stdout_fifo" "$go_stderr_fifo" \
  "$dashboard_stdout_fifo" "$dashboard_stderr_fifo" \
  "$nginx_stdout_fifo" "$nginx_stderr_fifo"; do
  rm -f "$fifo"
  mkfifo "$fifo"
done

chown -R node:node /tmp/nginx 2>/dev/null || true

prefix_stream() {
  service=$1
  while IFS= read -r line || [ -n "$line" ]; do
    printf '[%s] %s\n' "$service" "$line"
  done
}

# Each service keeps stdout/stderr as separate container streams while every
# line receives a stable service prefix for Fly/Docker log aggregation.
prefix_stream 9router-go < "$go_stdout_fifo" &
go_stdout_logger_pid=$!
prefix_stream 9router-go < "$go_stderr_fifo" >&2 &
go_stderr_logger_pid=$!
prefix_stream dashboard < "$dashboard_stdout_fifo" &
dashboard_stdout_logger_pid=$!
prefix_stream dashboard < "$dashboard_stderr_fifo" >&2 &
dashboard_stderr_logger_pid=$!
prefix_stream nginx < "$nginx_stdout_fifo" &
nginx_stdout_logger_pid=$!
prefix_stream nginx < "$nginx_stderr_fifo" >&2 &
nginx_stderr_logger_pid=$!

(
  cd /app
  exec su-exec node env PORT="${GO_PORT:-20129}" DATA_DIR="${DATA_DIR:-/app/data}" \
    /usr/local/bin/9router-go > "$go_stdout_fifo" 2> "$go_stderr_fifo"
) &
go_pid=$!

(
  cd /app
  exec su-exec node env PORT="${DASHBOARD_PORT:-3000}" "$@" \
    > "$dashboard_stdout_fifo" 2> "$dashboard_stderr_fifo"
) &
dashboard_pid=$!

nginx -c /etc/nginx/nginx.conf -g 'daemon off;' \
  > "$nginx_stdout_fifo" 2> "$nginx_stderr_fifo" &
nginx_pid=$!

term() {
  kill -TERM \
    "$nginx_pid" "$dashboard_pid" "$go_pid" \
    "$nginx_stdout_logger_pid" "$nginx_stderr_logger_pid" \
    "$dashboard_stdout_logger_pid" "$dashboard_stderr_logger_pid" \
    "$go_stdout_logger_pid" "$go_stderr_logger_pid" 2>/dev/null || true
}
trap term INT TERM

while :; do
  for pid in "$nginx_pid" "$dashboard_pid" "$go_pid"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      term
      wait "$pid" 2>/dev/null || true
      exit 1
    fi
  done
  sleep 2
done

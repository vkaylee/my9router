#!/bin/sh
set -eu

shutdown_timeout=${SHUTDOWN_TIMEOUT:-20}
shutdown_started=0

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

kill_if_running() {
  signal=$1
  shift
  for pid in "$@"; do
    kill -0 "$pid" 2>/dev/null && kill -"$signal" "$pid" 2>/dev/null || true
  done
}

pid_running() {
  pid=$1
  [ -r "/proc/$pid/stat" ] || return 1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) || return 1
  [ "$state" != "Z" ]
}

wait_for_services() {
  elapsed=0
  while [ "$elapsed" -lt "$shutdown_timeout" ]; do
    pid_running "$nginx_pid" || nginx_done=1
    pid_running "$dashboard_pid" || dashboard_done=1
    pid_running "$go_pid" || go_done=1
    [ "${nginx_done:-0}" -eq 1 ] && [ "${dashboard_done:-0}" -eq 1 ] && [ "${go_done:-0}" -eq 1 ] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

reap() {
  wait "$1" 2>/dev/null || true
}

term() {
  [ "$shutdown_started" -eq 1 ] && return
  shutdown_started=1

  # Nginx SIGQUIT drains active requests. Go and Node receive SIGTERM so
  # their own handlers can close listeners and finish in-flight work.
  kill_if_running QUIT "$nginx_pid"
  kill_if_running TERM "$dashboard_pid" "$go_pid"

  if ! wait_for_services; then
    kill_if_running KILL "$dashboard_pid" "$go_pid"
    kill_if_running TERM "$nginx_pid"
    sleep 1
    kill_if_running KILL "$nginx_pid"
  fi

  reap "$nginx_pid"
  reap "$dashboard_pid"
  reap "$go_pid"

  # Service writers are now closed; FIFO readers flush their final lines and
  # exit naturally. Bound the drain so a broken child cannot hang PID 1.
  elapsed=0
  while [ "$elapsed" -lt 2 ]; do
    pid_running "$nginx_stdout_logger_pid" || nginx_stdout_done=1
    pid_running "$nginx_stderr_logger_pid" || nginx_stderr_done=1
    pid_running "$dashboard_stdout_logger_pid" || dashboard_stdout_done=1
    pid_running "$dashboard_stderr_logger_pid" || dashboard_stderr_done=1
    pid_running "$go_stdout_logger_pid" || go_stdout_done=1
    pid_running "$go_stderr_logger_pid" || go_stderr_done=1
    [ "${nginx_stdout_done:-0}" -eq 1 ] && [ "${nginx_stderr_done:-0}" -eq 1 ] && \
      [ "${dashboard_stdout_done:-0}" -eq 1 ] && [ "${dashboard_stderr_done:-0}" -eq 1 ] && \
      [ "${go_stdout_done:-0}" -eq 1 ] && [ "${go_stderr_done:-0}" -eq 1 ] && break
    sleep 1
    elapsed=$((elapsed + 1))
  done
  kill_if_running TERM \
    "$nginx_stdout_logger_pid" "$nginx_stderr_logger_pid" \
    "$dashboard_stdout_logger_pid" "$dashboard_stderr_logger_pid" \
    "$go_stdout_logger_pid" "$go_stderr_logger_pid"
  reap "$nginx_stdout_logger_pid"
  reap "$nginx_stderr_logger_pid"
  reap "$dashboard_stdout_logger_pid"
  reap "$dashboard_stderr_logger_pid"
  reap "$go_stdout_logger_pid"
  reap "$go_stderr_logger_pid"
}

trap 'term; exit 0' INT TERM

while :; do
  for pid in "$nginx_pid" "$dashboard_pid" "$go_pid"; do
    if ! pid_running "$pid"; then
      term
      exit 1
    fi
  done
  sleep 2
done

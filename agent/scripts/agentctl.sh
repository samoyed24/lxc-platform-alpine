#!/usr/bin/env sh
set -eu

BASE_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BIN="${LXC_PLATFORM_AGENT_BIN:-$BASE_DIR/bin/lxc-platform-agent}"
CONF="${LXC_PLATFORM_AGENT_CONFIG:-$BASE_DIR/config.yaml}"
PID_FILE="${LXC_PLATFORM_AGENT_PID:-$BASE_DIR/run/lxc-platform-agent.pid}"
LOG_FILE="${LXC_PLATFORM_AGENT_LOG:-$BASE_DIR/run/lxc-platform-agent.log}"

mkdir -p "$(dirname "$PID_FILE")" "$(dirname "$LOG_FILE")" "$BASE_DIR/bin"

ensure_build_deps() {
  if command -v go >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v apk >/dev/null 2>&1; then
    echo "[agentctl] go not found and apk is unavailable; please install Go first" >&2
    exit 1
  fi

  echo "[agentctl] installing build dependencies via apk"
  apk add --no-cache go
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

build_bin() {
  ensure_build_deps
  echo "[agentctl] building binary"
  (cd "$BASE_DIR" && go build -o "$BIN" ./cmd/lxc-platform-agent)
}

start_agent() {
  if is_running; then
    echo "[agentctl] already running (pid=$(cat "$PID_FILE"))"
    exit 0
  fi

  [ -x "$BIN" ] || build_bin

  echo "[agentctl] starting"
  nohup "$BIN" -config "$CONF" >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  echo "[agentctl] started pid=$(cat "$PID_FILE")"
}

stop_agent() {
  if ! is_running; then
    echo "[agentctl] not running"
    rm -f "$PID_FILE"
    exit 0
  fi

  pid=$(cat "$PID_FILE")
  echo "[agentctl] stopping pid=$pid"
  kill "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
}

status_agent() {
  if is_running; then
    echo "[agentctl] running pid=$(cat "$PID_FILE")"
  else
    echo "[agentctl] stopped"
  fi
}

run_fg() {
  [ -x "$BIN" ] || build_bin
  exec "$BIN" -config "$CONF"
}

case "${1:-}" in
  start)
    start_agent
    ;;
  stop)
    stop_agent
    ;;
  restart)
    stop_agent
    start_agent
    ;;
  status)
    status_agent
    ;;
  build)
    build_bin
    ;;
  run)
    run_fg
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|build|run}"
    exit 1
    ;;
esac

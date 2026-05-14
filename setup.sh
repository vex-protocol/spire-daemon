#!/usr/bin/env bash
# Single entrypoint for this host (see: setup.sh help).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-deploy}"

export PATH="$HOME/.nvm/versions/node/v24.14.1/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

usage() {
  cat <<'EOF'
Commands:
  deploy (default)   git reset to origin/$BRANCH, pnpm install --frozen-lockfile, docker compose up
  daemon start|stop|status|tail   run watcher.sh in the background (flock + nohup)
  install            symlink user systemd unit and daemon-reload
  help

Environment (deploy):
  REPO_DIR, BRANCH, COMPOSE_DIR — repo root, git branch, Spire app directory

  Optional (same script for prod vs staging — set in EnvironmentFile / shell):
  COMPOSE_FILE        extra compose file: basename under COMPOSE_DIR, or absolute path
                      (passed once as: docker compose -f <file> …)
  SPIRE_DOCKER_NO_BUILD=1   omit --build (e.g. image already rebuilt by PRE_COMPOSE_COMMAND)
  PRE_COMPOSE_COMMAND optional shell snippet run in COMPOSE_DIR before docker compose
                      (e.g. bash deploy/rebuild-staging-image.sh)
EOF
}

deploy() {
  local REPO_DIR="${REPO_DIR:-$HOME/vex-protocol}"
  local BRANCH="${BRANCH:-master}"
  local COMPOSE_DIR="${COMPOSE_DIR:-$REPO_DIR/apps/spire}"

  log() { printf '[setup deploy %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

  cd "$REPO_DIR"

  log "fetching origin"
  git fetch --prune origin

  log "checking out $BRANCH and resetting to origin/$BRANCH"
  git checkout "$BRANCH"
  git reset --hard "origin/$BRANCH"

  local NEW_SHA
  NEW_SHA="$(git rev-parse HEAD)"
  log "now at $NEW_SHA"

  log "pnpm install --frozen-lockfile"
  pnpm install --frozen-lockfile

  cd "$COMPOSE_DIR"

  if [[ -n "${PRE_COMPOSE_COMMAND:-}" ]]; then
    log "PRE_COMPOSE_COMMAND: $PRE_COMPOSE_COMMAND"
    (cd "$COMPOSE_DIR" && bash -c "$PRE_COMPOSE_COMMAND")
  fi

  local -a compose_cmd=(docker compose)
  if [[ -n "${COMPOSE_FILE:-}" ]]; then
    local cf="$COMPOSE_FILE"
    [[ "$cf" != /* ]] && cf="$COMPOSE_DIR/$cf"
    compose_cmd+=(-f "$cf")
  fi
  compose_cmd+=(up -d)
  if [[ "${SPIRE_DOCKER_NO_BUILD:-0}" != 1 ]]; then
    compose_cmd+=(--build)
  fi

  log "docker compose (${compose_cmd[*]}) in $COMPOSE_DIR"
  "${compose_cmd[@]}"

  log "deploy complete: $NEW_SHA"
}

daemon() {
  set -euo pipefail
  local sub="${1:-start}"
  local PID_FILE="$SCRIPT_DIR/watcher.pid"
  local LOCK_FILE="$SCRIPT_DIR/watcher.lock"
  local LOG_FILE="$SCRIPT_DIR/watcher.log"

  case "$sub" in
    start)
      if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "already running as pid $(cat "$PID_FILE")"
        exit 0
      fi
      nohup setsid bash -c "
        exec flock -n '$LOCK_FILE' '$SCRIPT_DIR/watcher.sh'
      " >> "$LOG_FILE" 2>&1 &
      echo $! > "$PID_FILE"
      sleep 1
      if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "started pid $(cat "$PID_FILE"); logs: $LOG_FILE"
      else
        echo "failed to start; see $LOG_FILE"
        exit 1
      fi
      ;;
    stop)
      if [[ ! -f "$PID_FILE" ]]; then
        echo "no pid file; not running"
        exit 0
      fi
      local pid
      pid="$(cat "$PID_FILE")"
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid"
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -KILL "-$pid" 2>/dev/null || true
        echo "stopped pid $pid"
      else
        echo "pid $pid not running"
      fi
      rm -f "$PID_FILE"
      ;;
    status)
      if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "running, pid $(cat "$PID_FILE")"
      else
        echo "not running"
        exit 1
      fi
      ;;
    tail)
      exec tail -n 100 -f "$LOG_FILE"
      ;;
    *)
      echo "usage: $0 daemon {start|stop|status|tail}" >&2
      exit 2
      ;;
  esac
}

install_unit() {
  local src="$SCRIPT_DIR/vex-protocol-watcher.service"
  local dst="$HOME/.config/systemd/user/vex-protocol-watcher.service"
  if [[ ! -f "$src" ]]; then
    echo "missing $src" >&2
    exit 1
  fi
  mkdir -p "$HOME/.config/systemd/user"
  ln -sf "$src" "$dst"
  systemctl --user daemon-reload
  echo "Linked $dst"
  echo "Next: systemctl --user enable --now vex-protocol-watcher"
  echo "Optional token: EnvironmentFile in the unit points to /etc/vex-protocol-watcher.env"
}

case "$cmd" in
  deploy)
    deploy
    ;;
  daemon)
    shift
    daemon "${1:-start}"
    ;;
  install)
    install_unit
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    echo "unknown command: $cmd (try: deploy, daemon, install, help)" >&2
    exit 2
    ;;
esac

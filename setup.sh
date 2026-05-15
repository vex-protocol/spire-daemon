#!/usr/bin/env bash
# Single entrypoint for this host (see: setup.sh help).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

usage() {
  cat <<'EOF'
Commands:
  deploy (default)   git reset, pnpm install --frozen-lockfile, docker compose up
  daemon [opts] start|stop|status|tail   background watcher (opts: --config PATH)
  install            symlink user systemd unit and daemon-reload
  help

Config: config.json next to this script (or $VEX_WATCHER_CONFIG). Created automatically
if missing when you use the default path. Env overrides file; CLI flags override both.
If deploy.repo_dir does not exist, it is git-cloned from github.owner/repo (or deploy.clone_url).
First deploy installs nvm (if needed), Node NVM_NODE_VERSION (default 24), and pnpm (needs curl).
If apps/spire/.env is missing, copies .env.example when present and fills SPK/JWT_SECRET via gen-spk.

deploy flags (omit the word deploy when the first argument is already a flag, e.g. ./setup.sh --branch dev):
  --config|-c PATH
  --clone-url URL       (default https://github.com/<owner>/<repo>.git)
  --branch STR          (git checkout; default is github.branch in config)
  --repo-dir, --compose-dir, --compose-file PATH
  --pre-compose SHELL_SNIPPET
  --no-build
EOF
}

deploy_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config | -c)
        [[ $# -lt 2 ]] && {
          echo "deploy: --config needs a path" >&2
          exit 2
        }
        VEX_WATCHER_CONFIG="$2"
        shift 2
        ;;
      --repo-dir)
        [[ $# -lt 2 ]] && {
          echo "deploy: --repo-dir needs a path" >&2
          exit 2
        }
        CLI_REPO_DIR="$2"
        shift 2
        ;;
      --clone-url)
        [[ $# -lt 2 ]] && {
          echo "deploy: --clone-url needs a value" >&2
          exit 2
        }
        CLI_CLONE_URL="$2"
        shift 2
        ;;
      --branch)
        [[ $# -lt 2 ]] && {
          echo "deploy: --branch needs a value" >&2
          exit 2
        }
        CLI_BRANCH="$2"
        shift 2
        ;;
      --compose-dir)
        [[ $# -lt 2 ]] && {
          echo "deploy: --compose-dir needs a path" >&2
          exit 2
        }
        CLI_COMPOSE_DIR="$2"
        shift 2
        ;;
      --compose-file)
        [[ $# -lt 2 ]] && {
          echo "deploy: --compose-file needs a path" >&2
          exit 2
        }
        CLI_COMPOSE_FILE="$2"
        shift 2
        ;;
      --pre-compose)
        [[ $# -lt 2 ]] && {
          echo "deploy: --pre-compose needs a value" >&2
          exit 2
        }
        CLI_PRE_COMPOSE_COMMAND="$2"
        shift 2
        ;;
      --no-build)
        CLI_NO_BUILD=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "deploy: unknown option: $1 (try: setup.sh help)" >&2
        exit 2
        ;;
    esac
  done

  # shellcheck source=lib-config.sh
  source "$SCRIPT_DIR/lib-config.sh"
  # shellcheck source=lib-node.sh
  source "$SCRIPT_DIR/lib-node.sh"
  local cfg_path
  cfg_path="$(vex_watcher_prepare_config_path "$SCRIPT_DIR")" || exit 1
  vex_watcher_apply_config "$cfg_path" || exit 1

  [[ -n "${CLI_REPO_DIR:-}" ]] && REPO_DIR="$(vex_watcher_expand_path "$CLI_REPO_DIR")"
  [[ -n "${CLI_CLONE_URL:-}" ]] && REPO_CLONE_URL="$CLI_CLONE_URL"
  [[ -n "${CLI_BRANCH:-}" ]] && BRANCH="$CLI_BRANCH"
  [[ -n "${CLI_COMPOSE_DIR:-}" ]] && COMPOSE_DIR="$(vex_watcher_expand_path "$CLI_COMPOSE_DIR")"
  [[ -n "${CLI_COMPOSE_FILE:-}" ]] && COMPOSE_FILE="$CLI_COMPOSE_FILE"
  [[ -n "${CLI_PRE_COMPOSE_COMMAND:-}" ]] && PRE_COMPOSE_COMMAND="$CLI_PRE_COMPOSE_COMMAND"
  [[ -n "${CLI_NO_BUILD:-}" ]] && SPIRE_DOCKER_NO_BUILD=1

  local REPO_DIR="${REPO_DIR:-$HOME/vex-protocol}"
  local BRANCH="${BRANCH:-${GITHUB_BRANCH:-master}}"
  local COMPOSE_DIR="${COMPOSE_DIR:-$REPO_DIR/apps/spire}"

  log() { printf '[setup deploy %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

  deploy_ensure_repo() {
    local dir="$1" branch="$2"
    local url="${REPO_CLONE_URL:-https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git}"
    if [[ -d "$dir/.git" ]]; then
      return 0
    fi
    if [[ -e "$dir" ]]; then
      if [[ ! -d "$dir" ]]; then
        echo "deploy: path exists and is not a directory: $dir" >&2
        exit 1
      fi
      if compgen -G "$dir/*" >/dev/null 2>&1 || compgen -G "$dir/.[!.]*" >/dev/null 2>&1; then
        echo "deploy: $dir exists but is not a git clone (directory not empty)" >&2
        exit 1
      fi
      rmdir "$dir" 2>/dev/null || {
        echo "deploy: $dir exists, is not a clone, and could not be removed" >&2
        exit 1
      }
    fi
    mkdir -p "$(dirname "$dir")"
    log "cloning $url -> $dir (branch $branch)"
    if git clone --branch "$branch" "$url" "$dir" 2>/dev/null; then
      return 0
    fi
    log "clone with --branch $branch failed; cloning full repo then checking out $branch"
    git clone "$url" "$dir"
    (
      cd "$dir" || exit 1
      git fetch origin
      git fetch origin "refs/heads/$branch:refs/remotes/origin/$branch"
      git checkout -B "$branch" "origin/$branch"
    )
  }

  deploy_ensure_spire_env() {
    local d="$1"
    if [[ -f "$d/.env" ]]; then
      return 0
    fi
    log "creating $d/.env (copy .env.example + gen-spk)"
    if [[ -f "$d/.env.example" ]]; then
      cp "$d/.env.example" "$d/.env"
    else
      printf '%s\n' 'SPIRE_FIPS=false' 'DB_TYPE=sqlite3' >"$d/.env"
    fi
    if [[ ! -f "$d/scripts/gen-spk.js" ]]; then
      echo "deploy: missing $d/scripts/gen-spk.js (incomplete checkout?)" >&2
      exit 1
    fi
    local spk jwt
    mapfile -t _gk < <(cd "$d" && node scripts/gen-spk.js --raw)
    spk="${_gk[0]:-}"
    jwt="${_gk[1]:-}"
    if [[ -z "$spk" || -z "$jwt" ]]; then
      echo "deploy: gen-spk --raw did not produce SPK + JWT_SECRET lines" >&2
      exit 1
    fi
    if grep -qE '^SPK=' "$d/.env"; then
      sed -i "s/^SPK=.*/SPK=${spk}/" "$d/.env"
    else
      printf 'SPK=%s\n' "$spk" >>"$d/.env"
    fi
    if grep -qE '^JWT_SECRET=' "$d/.env"; then
      sed -i "s/^JWT_SECRET=.*/JWT_SECRET=${jwt}/" "$d/.env"
    else
      printf 'JWT_SECRET=%s\n' "$jwt" >>"$d/.env"
    fi
  }

  deploy_ensure_repo "$REPO_DIR" "$BRANCH"

  cd "$REPO_DIR"

  log "fetching origin (including branch $BRANCH)"
  git fetch --prune origin
  # Single-branch clones only map one remote ref; force this branch into refs/remotes/origin/*
  if ! git fetch origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; then
    echo "deploy: could not fetch refs/heads/$BRANCH from origin (missing branch or no access?)" >&2
    exit 1
  fi

  if ! git rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null; then
    echo "deploy: origin/$BRANCH ref missing after explicit fetch" >&2
    exit 1
  fi

  log "checking out $BRANCH at origin/$BRANCH"
  git checkout -B "$BRANCH" "refs/remotes/origin/$BRANCH"
  git reset --hard "origin/$BRANCH"

  local NEW_SHA
  NEW_SHA="$(git rev-parse HEAD)"
  log "now at $NEW_SHA"

  vex_watcher_ensure_nvm_node_pnpm

  log "pnpm install --frozen-lockfile"
  pnpm install --frozen-lockfile

  cd "$COMPOSE_DIR"

  deploy_ensure_spire_env "$COMPOSE_DIR"

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
  local sub="start"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config | -c)
        [[ $# -lt 2 ]] && {
          echo "daemon: --config needs a path" >&2
          exit 2
        }
        export VEX_WATCHER_CONFIG="$2"
        shift 2
        ;;
      start | stop | status | tail)
        sub="$1"
        shift
        ;;
      *)
        echo "daemon: unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done

  local PID_FILE="$SCRIPT_DIR/watcher.pid"
  local LOCK_FILE="$SCRIPT_DIR/watcher.lock"
  local LOG_FILE="$SCRIPT_DIR/watcher.log"

  case "$sub" in
    start)
      if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "already running as pid $(cat "$PID_FILE")"
        exit 0
      fi
      # shellcheck disable=SC2086
      nohup setsid env "VEX_WATCHER_CONFIG=${VEX_WATCHER_CONFIG:-}" bash -c "
        exec flock -n '$LOCK_FILE' '$SCRIPT_DIR/watcher.sh'
      " >>"$LOG_FILE" 2>&1 &
      echo $! >"$PID_FILE"
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
      echo "usage: $0 daemon [--config PATH] {start|stop|status|tail}" >&2
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

if [[ $# -eq 0 || "${1:-}" == -* ]]; then
  deploy_main "$@"
  exit $?
fi

case "$1" in
  deploy)
    shift
    deploy_main "$@"
    ;;
  daemon)
    shift
    daemon "$@"
    ;;
  install)
    install_unit
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    echo "unknown command: $1 (try: deploy, daemon, install, help)" >&2
    exit 2
    ;;
esac

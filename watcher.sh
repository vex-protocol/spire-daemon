#!/usr/bin/env bash
# vex-protocol watcher daemon.
#
# Polls the GitHub REST API for the latest commit on $GITHUB_BRANCH of
# $GITHUB_OWNER/$GITHUB_REPO every $POLL_INTERVAL seconds. When the SHA
# changes, runs $DEPLOY_SCRIPT (default: setup.sh deploy).
#
# Config: JSON at $VEX_WATCHER_CONFIG, default <this_dir>/config.json (created
# there automatically if missing when the path is implicit). github.branch is
# the watched ref and default deploy checkout. Env overrides file; watcher.sh --config.
# GITHUB_TOKEN still lifts API rate limits.
#
# Logs to stdout/stderr; use `setup.sh daemon start` or systemd — log file
# is watcher.log in this directory when using the daemon helper.

set -uo pipefail

WATCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config | -c)
      [[ $# -lt 2 ]] && {
        echo "watcher: --config needs a path" >&2
        exit 2
      }
      VEX_WATCHER_CONFIG="$2"
      shift 2
      ;;
    -h | --help)
      echo "usage: watcher.sh [--config PATH]"
      exit 0
      ;;
    *)
      echo "watcher: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=lib-config.sh
source "$WATCHER_DIR/lib-config.sh"
cfg_path="$(vex_watcher_prepare_config_path "$WATCHER_DIR")" || exit 1
vex_watcher_apply_config "$cfg_path" || exit 1

GITHUB_OWNER="${GITHUB_OWNER:-vex-protocol}"
GITHUB_REPO="${GITHUB_REPO:-vex-protocol}"
GITHUB_BRANCH="${GITHUB_BRANCH:-master}"
POLL_INTERVAL="${POLL_INTERVAL:-90}"
STATE_DIR="${STATE_DIR:-$HOME/vex-protocol-watcher}"
LAST_SHA_FILE="${LAST_SHA_FILE:-$STATE_DIR/last-sha}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$WATCHER_DIR/setup.sh}"

export PATH="$HOME/.nvm/versions/node/v24.14.1/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$STATE_DIR"

log() { printf '[watcher %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

cfg="${VEX_WATCHER_CONFIG:-$WATCHER_DIR/config.json}"
if [[ -f "$(vex_watcher_expand_path "$cfg")" ]]; then
  log "config: $(vex_watcher_expand_path "$cfg")"
fi

fetch_remote_sha() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  local url="https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/commits/$GITHUB_BRANCH"
  curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: vex-protocol-watcher' \
    "${auth[@]}" \
    --max-time 20 \
    "$url" \
    | jq -er '.sha'
}

migrate_legacy_state() {
  local legacy_master="$STATE_DIR/last-sha-master"
  if [[ -f "$legacy_master" ]]; then
    if [[ ! -f "$LAST_SHA_FILE" ]] || ! cmp -s "$legacy_master" "$LAST_SHA_FILE"; then
      cp "$legacy_master" "$LAST_SHA_FILE"
      log "using last-sha-master as $LAST_SHA_FILE (prod tracking)"
    fi
  fi
}

seed_if_missing() {
  [[ -f "$LAST_SHA_FILE" ]] && return 0
  local repo="${REPO_DIR:-$HOME/vex-protocol}"
  if [[ -d "$repo/.git" ]]; then
    git -C "$repo" fetch origin "$GITHUB_BRANCH" 2>/dev/null || true
    if local_sha="$(git -C "$repo" rev-parse "origin/$GITHUB_BRANCH" 2>/dev/null)"; then
      echo "$local_sha" > "$LAST_SHA_FILE"
      log "seeded from origin/$GITHUB_BRANCH: $local_sha"
      return 0
    fi
  fi
  if remote_sha="$(fetch_remote_sha 2>/dev/null)"; then
    echo "$remote_sha" > "$LAST_SHA_FILE"
    log "seeded from GitHub API: $remote_sha"
  fi
}

trap 'log "received signal, exiting"; exit 0' INT TERM

log "starting; watching $GITHUB_OWNER/$GITHUB_REPO@$GITHUB_BRANCH every ${POLL_INTERVAL}s"
log "deploy: $DEPLOY_SCRIPT"

migrate_legacy_state
seed_if_missing

while true; do
  if remote_sha="$(fetch_remote_sha 2>/dev/null)"; then
    last_sha=""
    [[ -f "$LAST_SHA_FILE" ]] && last_sha="$(cat "$LAST_SHA_FILE")"
    if [[ "$remote_sha" != "$last_sha" ]]; then
      log "change: ${last_sha:-<none>} -> $remote_sha"
      if [[ -n "${REPO_DIR:-}" ]]; then export REPO_DIR; fi
      if [[ -n "${COMPOSE_DIR:-}" ]]; then export COMPOSE_DIR; fi
      if [[ -n "${COMPOSE_FILE:-}" ]]; then export COMPOSE_FILE; fi
      if [[ -n "${PRE_COMPOSE_COMMAND:-}" ]]; then export PRE_COMPOSE_COMMAND; fi
      if [[ -n "${SPIRE_DOCKER_NO_BUILD:-}" ]]; then export SPIRE_DOCKER_NO_BUILD; fi
      if env BRANCH="$GITHUB_BRANCH" "$DEPLOY_SCRIPT"; then
        echo "$remote_sha" > "$LAST_SHA_FILE"
        log "deploy succeeded @ $remote_sha"
      else
        rc=$?
        log "deploy FAILED (exit $rc); will retry on next change"
      fi
    fi
  else
    log "github poll failed (curl/jq); will retry"
  fi
  sleep "$POLL_INTERVAL"
done

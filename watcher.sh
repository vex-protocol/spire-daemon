#!/usr/bin/env bash
# vex-protocol watcher daemon.
#
# Polls the GitHub REST API for the latest commit on $GITHUB_BRANCH of
# $GITHUB_OWNER/$GITHUB_REPO every $POLL_INTERVAL seconds. When the SHA
# changes, runs $DEPLOY_SCRIPT (default: setup.sh deploy).
#
# Auth: optional. Set GITHUB_TOKEN to lift the unauth rate limit (60 req/hr) to
# 5,000 req/hr. With the default 90s interval (~40 req/hr) unauth is fine.
#
# Logs to stdout/stderr; use `setup.sh daemon start` or systemd — log file
# is watcher.log in this directory when using the daemon helper.

set -uo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-vex-protocol}"
GITHUB_REPO="${GITHUB_REPO:-vex-protocol}"
GITHUB_BRANCH="${GITHUB_BRANCH:-master}"
POLL_INTERVAL="${POLL_INTERVAL:-90}"
STATE_DIR="${STATE_DIR:-$HOME/vex-protocol-watcher}"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$STATE_DIR/setup.sh}"
LAST_SHA_FILE="${LAST_SHA_FILE:-$STATE_DIR/last-sha}"

export PATH="$HOME/.nvm/versions/node/v24.14.1/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$STATE_DIR"

log() { printf '[watcher %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

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
  if [[ -d "$HOME/vex-protocol/.git" ]]; then
    git -C "$HOME/vex-protocol" fetch origin "$GITHUB_BRANCH" 2>/dev/null || true
    if local_sha="$(git -C "$HOME/vex-protocol" rev-parse "origin/$GITHUB_BRANCH" 2>/dev/null)"; then
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

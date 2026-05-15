# shellcheck shell=bash
# Load JSON config; environment variables override file values.
# Optional: create default config when using the implicit path and file is missing.

vex_watcher_expand_path() {
  local p="$1"
  case "$p" in
    '~' | '~/'*) echo "$HOME${p:1}" ;;
    *) echo "$p" ;;
  esac
}

vex_watcher_default_config_json() {
  cat <<'JSON'
{
  "github": {
    "owner": "vex-protocol",
    "repo": "vex-protocol",
    "branch": "master"
  },
  "poll_interval_seconds": 90,
  "state_dir": "~/vex-protocol-watcher",
  "last_sha_file": null,
  "deploy_script": null,
  "deploy": {
    "repo_dir": "~/vex-protocol",
    "clone_url": null,
    "compose_dir": null,
    "compose_file": null,
    "pre_compose_command": null,
    "docker_skip_build": false
  }
}
JSON
}

# If default_path=1 and $VEX_WATCHER_CONFIG is unset, write defaults when file missing.
vex_watcher_prepare_config_path() {
  local default_dir="$1"
  local cfg="${VEX_WATCHER_CONFIG:-$default_dir/config.json}"
  local exp
  exp="$(vex_watcher_expand_path "$cfg")"
  if [[ ! -f "$exp" ]]; then
    if [[ -n "${VEX_WATCHER_CONFIG:-}" ]]; then
      echo "vex-watcher: config not found: $exp" >&2
      return 1
    fi
    mkdir -p "$(dirname "$exp")"
    vex_watcher_default_config_json > "$exp"
  fi
  printf '%s' "$exp"
}

vex_watcher_apply_config() {
  local f="${1:-}"
  [[ -n "$f" ]] || return 0
  f="$(vex_watcher_expand_path "$f")"
  [[ -f "$f" ]] || return 0
  jq empty "$f" 2>/dev/null || {
    echo "vex-watcher: invalid JSON in $f" >&2
    return 1
  }

  GITHUB_OWNER="${GITHUB_OWNER:-$(jq -r '.github.owner // "vex-protocol"' "$f")}"
  GITHUB_REPO="${GITHUB_REPO:-$(jq -r '.github.repo // "vex-protocol"' "$f")}"

  local gh_br
  gh_br="$(jq -r '.github.branch // empty' "$f")"
  # One ref for both GitHub polling and default git checkout (override checkout with BRANCH= env or setup.sh --branch).
  [[ -n "$gh_br" && "$gh_br" != "null" ]] && GITHUB_BRANCH="${GITHUB_BRANCH:-$gh_br}"
  [[ -n "$gh_br" && "$gh_br" != "null" ]] && BRANCH="${BRANCH:-$gh_br}"

  local pi
  pi="$(jq -r '.poll_interval_seconds // empty' "$f")"
  if [[ -n "$pi" && "$pi" != "null" ]] && [[ "$pi" =~ ^[0-9]+$ ]]; then
    POLL_INTERVAL="${POLL_INTERVAL:-$pi}"
  fi

  local sd
  sd="$(jq -r '.state_dir // empty' "$f")"
  [[ -n "$sd" && "$sd" != "null" ]] && STATE_DIR="${STATE_DIR:-$(vex_watcher_expand_path "$sd")}"

  local lf
  lf="$(jq -r '.last_sha_file // empty' "$f")"
  [[ -n "$lf" && "$lf" != "null" ]] && LAST_SHA_FILE="${LAST_SHA_FILE:-$(vex_watcher_expand_path "$lf")}"

  local ds
  ds="$(jq -r '.deploy_script // empty' "$f")"
  [[ -n "$ds" && "$ds" != "null" ]] && DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$(vex_watcher_expand_path "$ds")}"

  local rd
  rd="$(jq -r '.deploy.repo_dir // empty' "$f")"
  [[ -n "$rd" && "$rd" != "null" ]] && REPO_DIR="${REPO_DIR:-$(vex_watcher_expand_path "$rd")}"

  local cu
  cu="$(jq -r '.deploy.clone_url // empty' "$f")"
  [[ -n "$cu" && "$cu" != "null" ]] && REPO_CLONE_URL="${REPO_CLONE_URL:-$cu}"

  local cd_
  cd_="$(jq -r '.deploy.compose_dir // empty' "$f")"
  [[ -n "$cd_" && "$cd_" != "null" ]] && COMPOSE_DIR="${COMPOSE_DIR:-$(vex_watcher_expand_path "$cd_")}"

  local cf
  cf="$(jq -r '.deploy.compose_file // empty' "$f")"
  [[ -n "$cf" && "$cf" != "null" ]] && COMPOSE_FILE="${COMPOSE_FILE:-$cf}"

  local pc
  pc="$(jq -r '.deploy.pre_compose_command // empty' "$f")"
  [[ -n "$pc" && "$pc" != "null" ]] && PRE_COMPOSE_COMMAND="${PRE_COMPOSE_COMMAND:-$pc}"

  if [[ -z "${SPIRE_DOCKER_NO_BUILD:-}" ]] && jq -e '.deploy.docker_skip_build == true' "$f" >/dev/null 2>&1; then
    SPIRE_DOCKER_NO_BUILD=1
  fi
}

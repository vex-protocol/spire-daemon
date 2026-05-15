# shellcheck shell=bash
# Install nvm + Node (default 24) + pnpm for non-interactive deploy. Idempotent.

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
NVM_NODE_VERSION="${NVM_NODE_VERSION:-24}"
NVM_SH_INSTALL_TAG="${NVM_SH_INSTALL_TAG:-v0.40.3}"

_vex_node_log() {
  printf '[vex toolchain %s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

vex_watcher_ensure_nvm_node_pnpm() {
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    _vex_node_log "installing nvm (${NVM_SH_INSTALL_TAG}) into $NVM_DIR"
    if ! command -v curl >/dev/null 2>&1; then
      echo "vex toolchain: curl is required to install nvm" >&2
      return 1
    fi
    if ! command -v bash >/dev/null 2>&1; then
      echo "vex toolchain: bash is required to install nvm" >&2
      return 1
    fi
    unset NVM_SOURCE
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_SH_INSTALL_TAG}/install.sh" |
      PROFILE=/dev/null NVM_DIR="$NVM_DIR" bash
  fi

  # shellcheck disable=SC1090,SC1091
  \. "$NVM_DIR/nvm.sh"

  _vex_node_log "ensuring Node.js ${NVM_NODE_VERSION} (nvm)"
  nvm install "${NVM_NODE_VERSION}"
  nvm use "${NVM_NODE_VERSION}"
  nvm alias default "${NVM_NODE_VERSION}" >/dev/null 2>&1 || true

  hash -r 2>/dev/null || true

  if ! command -v pnpm >/dev/null 2>&1; then
    _vex_node_log "installing pnpm"
    if command -v corepack >/dev/null 2>&1; then
      corepack enable
      corepack prepare pnpm@latest --activate
    else
      npm install -g pnpm
    fi
  fi

  hash -r 2>/dev/null || true
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "vex toolchain: pnpm not found after install" >&2
    return 1
  fi

  _vex_node_log "using $(command -v node) $(node -v), $(command -v pnpm) $(pnpm -v)"
}

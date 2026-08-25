#!/usr/bin/env bash
# helpers.sh - shared utilities for opencode-bootstrap.
# Sourced by every script; never executed directly.

# ---------------------------------------------------------------- paths ----
# REPO_DIR is resolved from this file's location so the scripts work no
# matter where the repository was cloned or which cwd invoked them.
_helpers_self="${BASH_SOURCE[0]}"
while [ -L "$_helpers_self" ]; do
  _helpers_link="$(readlink "$_helpers_self")"
  case "$_helpers_link" in
    /*) _helpers_self="$_helpers_link" ;;
    *)  _helpers_self="$(dirname "$_helpers_self")/$_helpers_link" ;;
  esac
done
REPO_DIR="$(cd "$(dirname "$_helpers_self")/.." && pwd)"
unset _helpers_self _helpers_link
export REPO_DIR

OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
OPENCODE_DATA_DIR="${OPENCODE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode}"
# Where the `skills` CLI stores global skills. OpenCode reads this natively.
SKILLS_HOME="${SKILLS_HOME:-$HOME/.agents/skills}"
# Everything this repository owns inside the OpenCode config dir lives here,
# so uninstall can remove it without touching pre-existing user files.
MANAGED_DIR="$OPENCODE_CONFIG_DIR/opencode-bootstrap"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
export OPENCODE_CONFIG_DIR OPENCODE_DATA_DIR SKILLS_HOME MANAGED_DIR BIN_DIR

# --------------------------------------------------------------- colors ----
# Disabled when stdout is not a tty, when TERM is dumb, or when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

# ---------------------------------------------------------------- output ----
banner() {
  printf '%s\n' "${C_CYAN}════════════════════════════════════════${C_RESET}"
  printf '%s\n' " ${C_BOLD}$1${C_RESET}"
  printf '%s\n' "${C_CYAN}════════════════════════════════════════${C_RESET}"
}
section() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }
step()    { printf '\n%s\n' "${C_BOLD}[$1] $2${C_RESET}"; }
ok()      { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
fail()    { printf '%s\n' "${C_RED}✗${C_RESET} $*"; }
warn()    { printf '%s\n' "${C_YELLOW}!${C_RESET} $*"; }
info()    { printf '%s\n' "${C_DIM}·${C_RESET} $*"; }
hint()    { printf '%s\n' "  ${C_DIM}$*${C_RESET}"; }
die()     { fail "$*"; exit 1; }

# ------------------------------------------------------------ detection ----
has() { command -v "$1" >/dev/null 2>&1; }

is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version && return 0
  return 1
}

os_name() {
  case "$(uname -s)" in
    Linux)  is_wsl && echo "WSL" || echo "Linux" ;;
    Darwin) echo "macOS" ;;
    *)      echo "$(uname -s)" ;;
  esac
}

# Resolve the OpenCode global config file. OpenCode accepts either
# opencode.json or opencode.jsonc; prefer whichever already exists so we
# never orphan the user's current settings by writing a second file.
config_file() {
  if [ -f "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]; then
    printf '%s\n' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
  else
    printf '%s\n' "$OPENCODE_CONFIG_DIR/opencode.json"
  fi
}

# --------------------------------------------------------------- backup ----
# Copies the whole OpenCode config dir once per script run. Node modules are
# skipped: they are large, regenerable, and never something we modify.
BACKUP_DONE=""
backup_config_dir() {
  [ -n "$BACKUP_DONE" ] && return 0
  [ -d "$OPENCODE_CONFIG_DIR" ] || return 0
  local dest="${OPENCODE_CONFIG_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest"
  # tar keeps permissions and symlinks intact and lets us exclude node_modules.
  ( cd "$OPENCODE_CONFIG_DIR" && tar cf - --exclude=node_modules . ) | ( cd "$dest" && tar xf - )
  BACKUP_DONE="$dest"
  info "Backup: $dest"
}

# ------------------------------------------------------------------ env ----
# Loads .env from the repository root, if present, without echoing values.
# Only KEY=VALUE lines are honoured; anything else is ignored.
load_env() {
  local f="$REPO_DIR/.env"
  [ -f "$f" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#export }"; key="${key// /}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    # Strip one layer of surrounding quotes.
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "$val" ] && export "$key=$val"
  done < "$f"
}

# ---------------------------------------------------------------- config ----
# Reads a pipe-delimited manifest, dropping comments and blank lines.
# Usage: read_manifest <file>  -> emits "owner/repo|skill" per line
read_manifest() {
  [ -f "$1" ] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"
}

node_bin() {
  if has node; then printf 'node\n'; return 0; fi
  return 1
}

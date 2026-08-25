#!/usr/bin/env bash
# platform.sh — the only file allowed to care about Linux vs WSL vs macOS.
# Sourced, never executed. Depends on logging.sh for debug() only.
#
# Every command with a known GNU/BSD split is wrapped here:
#   readlink -f  -> resolve_path      sha256sum -> hash_file
#   sed -i       -> sed_inplace       stat      -> file_mode / file_mtime
#   realpath     -> resolve_path      date -r   -> file_mtime
# Callers use the wrappers so the rest of the repo stays portable by default.

[ -n "${_AI_DEV_PLATFORM_LOADED:-}" ] && return 0
_AI_DEV_PLATFORM_LOADED=1

has() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- detection ----
is_macos() { [ "$(uname -s)" = "Darwin" ]; }
is_linux() { [ "$(uname -s)" = "Linux" ]; }

is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version && return 0
  return 1
}

# One of: WSL, Linux, macOS, or the raw uname for anything else.
os_name() {
  case "$(uname -s)" in
    Linux)  if is_wsl; then echo "WSL"; else echo "Linux"; fi ;;
    Darwin) echo "macOS" ;;
    *)      uname -s ;;
  esac
}

os_id() {
  case "$(os_name)" in
    WSL) echo "wsl" ;; Linux) echo "linux" ;; macOS) echo "macos" ;; *) echo "unknown" ;;
  esac
}

# Descriptive line for the health reports, e.g. "macOS 15.5 (arm64)".
os_describe() {
  local ver=""
  if is_macos; then ver="$(sw_vers -productVersion 2>/dev/null || true)"
  elif [ -r /etc/os-release ]; then
    ver="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")"
  fi
  if [ -n "$ver" ]; then printf '%s %s (%s)' "$(os_name)" "$ver" "$(uname -m)"
  else printf '%s (%s)' "$(os_name)" "$(uname -m)"; fi
}

# --------------------------------------------------------------- paths ------
# Absolute path with every symlink in the chain resolved. Replaces `readlink -f`
# and `realpath`, neither of which is dependable on macOS.
resolve_path() {
  local p="${1:-}" dir base i=0
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ -L "$p" ] && [ "$i" -lt 40 ]; do
    local target
    target="$(readlink "$p")" || return 1
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname "$p")/$target" ;;
    esac
    i=$((i + 1))
  done
  [ "$p" = "/" ] && { printf '/\n'; return 0; }
  dir="$(dirname "$p")"; base="$(basename "$p")"
  if [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd -P "$dir" 2>/dev/null && pwd)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

# Where a symlink points, made absolute, WITHOUT following further links.
# This is what symlink verification needs: the recorded target, not the
# eventual file, so a link pointing at a moved repo is still reportable.
link_target() {
  local link="${1:-}" target
  [ -L "$link" ] || return 1
  target="$(readlink "$link")" || return 1
  case "$target" in
    /*) printf '%s\n' "$target" ;;
    *)  printf '%s/%s\n' "$(cd -P "$(dirname "$link")" 2>/dev/null && pwd)" "$target" ;;
  esac
}

# ------------------------------------------------------------ file facts ----
hash_file() {
  [ -f "$1" ] || return 1
  if   has sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif has shasum;    then shasum -a 256 "$1" | awk '{print $1}'
  elif has openssl;   then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1; fi
}

# Octal permission bits, e.g. 755. BSD stat and GNU stat disagree on flags.
file_mode() {
  [ -e "$1" ] || return 1
  if is_macos; then stat -f '%OLp' "$1"; else stat -c '%a' "$1"; fi
}

file_mtime() {
  [ -e "$1" ] || return 1
  if is_macos; then stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1"; else date -d "@$(stat -c '%Y' "$1")" '+%Y-%m-%d %H:%M'; fi
}

# ------------------------------------------------------------- mutation -----
# `sed -i` takes a mandatory suffix argument on BSD and rejects one on GNU.
# Writing through a temp file and copying the bytes back also preserves the
# original inode, mode and owner, which an `mv` would silently replace.
sed_inplace() {
  local expr="$1" file="$2" tmp
  [ -f "$file" ] || return 1
  tmp="$(mktemp)" || return 1
  if sed "$expr" "$file" > "$tmp"; then
    cat "$tmp" > "$file"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

# --------------------------------------------------------------- shell ------
# The rc file of the user's LOGIN shell, which is not the bash running this.
login_shell_rc() {
  case "${SHELL:-}" in
    */zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    */bash) if is_macos && [ -f "$HOME/.bash_profile" ]; then printf '%s\n' "$HOME/.bash_profile"
            else printf '%s\n' "$HOME/.bashrc"; fi ;;
    *)      return 1 ;;
  esac
}

# Every rc file this repo may have written to, for cleanup and verification.
candidate_rc_files() {
  printf '%s\n' "$HOME/.bashrc" "$HOME/.bash_profile" "${ZDOTDIR:-$HOME}/.zshrc"
}

path_has_dir() {
  case ":${PATH}:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

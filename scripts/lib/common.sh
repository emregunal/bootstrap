#!/usr/bin/env bash
# common.sh — repository paths, exit codes and the safe-mutation primitives.
# Sourced by every script:  source "<repo>/scripts/lib/common.sh"
#
# Nothing in here mutates anything on its own. The functions that CAN write
# (ensure_directory, ensure_symlink, safe_backup, ensure_block) all honour
# DRY_RUN and all refuse to clobber a file this repository does not own.

[ -n "${_AI_DEV_COMMON_LOADED:-}" ] && return 0
_AI_DEV_COMMON_LOADED=1

# ------------------------------------------------------------ repo root -----
# Resolved from this file's own location, with symlinks followed, so every
# script works no matter where the repo was cloned, what the cwd is, or
# whether it was reached through ~/.local/bin. Never hard-code a path.
_ai_dev_self="${BASH_SOURCE[0]}"
_ai_dev_link=""
while [ -L "$_ai_dev_self" ]; do
  _ai_dev_link="$(readlink "$_ai_dev_self")"
  case "$_ai_dev_link" in
    /*) _ai_dev_self="$_ai_dev_link" ;;
    *)  _ai_dev_self="$(dirname "$_ai_dev_self")/$_ai_dev_link" ;;
  esac
done
REPO_DIR="$(cd -P "$(dirname "$_ai_dev_self")/../.." && pwd)"
unset _ai_dev_self _ai_dev_link
export REPO_DIR

# shellcheck source=./logging.sh
. "$REPO_DIR/scripts/lib/logging.sh"
# shellcheck source=./platform.sh
. "$REPO_DIR/scripts/lib/platform.sh"

# ----------------------------------------------------------- exit codes -----
# Kept small on purpose. CI and the git hooks branch on these.
EX_OK=0          # success
EX_FAIL=1        # general failure
EX_CONFIG=2      # configuration is missing or unparseable
EX_DEPS=3        # a required dependency is not installed
EX_SECURITY=4    # preflight/secret problem — never auto-fixable
EX_DRIFT=5       # local state has drifted from the repository
export EX_OK EX_FAIL EX_CONFIG EX_DEPS EX_SECURITY EX_DRIFT

# ---------------------------------------------------------------- paths -----
# Every one of these is overridable from the environment, which is what makes
# the sandboxed behaviour tests possible: they run with HOME pointed at a
# throwaway directory and nothing escapes it.
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$XDG_CONFIG/opencode}"
OPENCODE_DATA_DIR="${OPENCODE_DATA_DIR:-$XDG_DATA/opencode}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
# Where the `skills` CLI keeps the canonical copy of every global skill; the
# agent directories then hold symlinks into it.
SKILLS_HOME="${SKILLS_HOME:-$HOME/.agents/skills}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
STATE_DIR="$REPO_DIR/state"
# This repository's own local footprint, outside any agent's config dir. Holds
# the generated credential bridge (env.sh) that the login shell sources.
LOCAL_STATE_DIR="${AI_DEV_LOCAL_STATE:-$XDG_CONFIG/ai-dev-bootstrap}"
ENV_BRIDGE="$LOCAL_STATE_DIR/env.sh"

# The single directory name this repo owns inside each agent's config dir.
# Keeping everything under one namespaced folder is what lets uninstall be
# exact and lets `check.sh` repair links without ever touching a user file.
MANAGED_NAME="ai-dev-bootstrap"
export XDG_CONFIG XDG_DATA OPENCODE_CONFIG_DIR OPENCODE_DATA_DIR
export CLAUDE_HOME CODEX_HOME SKILLS_HOME BIN_DIR STATE_DIR MANAGED_NAME
export LOCAL_STATE_DIR ENV_BRIDGE

# Legacy names from when this repo was OpenCode-only. Used by the migration
# path in setup.sh and by check.sh to report leftovers; never written to.
LEGACY_MANAGED_NAME="opencode-bootstrap"
LEGACY_COMMANDS="opencode-sync opencode-doctor"
export LEGACY_MANAGED_NAME LEGACY_COMMANDS

# -------------------------------------------------------------- markers -----
# Managed blocks are delimited so they can be rewritten or removed exactly,
# leaving every other line of the user's file untouched.
BLOCK_BEGIN="# >>> ai-dev-bootstrap >>>"
BLOCK_END="# <<< ai-dev-bootstrap <<<"
WRAPPER_MARKER="# ai-dev-bootstrap"
LEGACY_BLOCK_BEGIN="# >>> opencode-bootstrap >>>"
LEGACY_BLOCK_END="# <<< opencode-bootstrap <<<"
export BLOCK_BEGIN BLOCK_END WRAPPER_MARKER LEGACY_BLOCK_BEGIN LEGACY_BLOCK_END

# ------------------------------------------------------------- run mode -----
DRY_RUN="${DRY_RUN:-0}"
is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  command_exists "$1" && return 0
  fail "$1 is required but not installed"
  [ -n "${2:-}" ] && hint "$2"
  exit "$EX_DEPS"
}

now_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
file_stamp() { date '+%Y%m%d-%H%M%S'; }

# Path relative to the repo root, for readable reports.
repo_relative() {
  case "$1" in "$REPO_DIR"/*) printf '%s' "${1#"$REPO_DIR"/}" ;; *) printf '%s' "$1" ;; esac
}

# ---------------------------------------------------------- directories -----
ensure_directory() {
  local dir="$1"
  [ -d "$dir" ] && return 0
  if is_dry_run; then plan_action CREATE "$(tilde "$dir")"; return 0; fi
  mkdir -p "$dir" || return 1
  debug "created directory $dir"
  return 0
}

# --------------------------------------------------------------- backup -----
# Timestamped copy beside the original. Returns the backup path on stdout so
# the caller can report it. Never overwrites an existing backup.
safe_backup() {
  local src="$1" dest
  [ -e "$src" ] || return 0
  dest="${src}.ai-dev-backup-$(file_stamp)"
  if is_dry_run; then plan_action BACKUP "$(tilde "$dest")"; printf '%s\n' "$dest"; return 0; fi
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    ( cd "$src" && tar cf - --exclude=node_modules . ) | ( cd "$dest" && tar xf - )
  else
    cp -p "$src" "$dest"
  fi
  printf '%s\n' "$dest"
}

# Keep the N most recent backups matching a prefix; older ones are noise.
# Counted explicitly because `head -n -N` is GNU-only.
prune_backups() {
  local pattern="$1" keep="${2:-10}" total prune
  # `|| true`: with `set -o pipefail`, a glob that matches nothing makes the
  # whole pipeline fail and would abort the caller.
  # shellcheck disable=SC2086,SC2012  # $pattern must glob; these are our own
  # timestamped backup directories, so the names are known to be plain.
  total="$(ls -d ${pattern} 2>/dev/null | wc -l | tr -d ' ' || true)"
  [ "${total:-0}" -gt "$keep" ] || return 0
  prune=$((total - keep))
  # shellcheck disable=SC2086,SC2012
  ls -d ${pattern} 2>/dev/null | sort | head -n "$prune" 2>/dev/null | while IFS= read -r stale; do
    [ -n "$stale" ] && rm -rf "$stale"
  done
}

# One config-directory snapshot per run, taken before the first write.
# Skipped when the newest snapshot already holds an identical config file, so
# a daily `ai-dev-sync` does not bury the one backup that matters.
BACKUP_DONE=""
backup_config_dir() {
  [ -n "$BACKUP_DONE" ] && return 0
  [ -d "$OPENCODE_CONFIG_DIR" ] || return 0
  is_dry_run && return 0

  local cfg newest dest
  cfg="$(opencode_config_file)"
  newest="$(ls -d "${OPENCODE_CONFIG_DIR}".backup-* 2>/dev/null | sort | tail -1 || true)"
  if [ -n "$newest" ] && [ -f "$cfg" ] && [ -f "$newest/$(basename "$cfg")" ] \
     && cmp -s "$cfg" "$newest/$(basename "$cfg")"; then
    BACKUP_DONE="$newest"; return 0
  fi

  dest="${OPENCODE_CONFIG_DIR}.backup-$(file_stamp)"
  mkdir -p "$dest"
  ( cd "$OPENCODE_CONFIG_DIR" && tar cf - --exclude=node_modules . ) | ( cd "$dest" && tar xf - )
  BACKUP_DONE="$dest"
  info "Backup: $(tilde "$dest")"
  prune_backups "${OPENCODE_CONFIG_DIR}.backup-*" 10
  return 0
}

# OpenCode accepts opencode.json or opencode.jsonc. Prefer whichever exists so
# a second file never orphans the user's current settings.
opencode_config_file() {
  if [ -f "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]; then
    printf '%s\n' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
  else
    printf '%s\n' "$OPENCODE_CONFIG_DIR/opencode.json"
  fi
}

# -------------------------------------------------------------- symlinks ----
# link_state SRC DEST — read-only. Prints exactly one word:
#   ok        DEST is a symlink pointing at SRC
#   missing   DEST does not exist
#   broken    DEST is a symlink whose target does not exist
#   wrong     DEST is a symlink pointing somewhere else
#   conflict  DEST exists but is a real file/directory, not a symlink
link_state() {
  local src="$1" dest="$2" target
  if [ -L "$dest" ]; then
    target="$(link_target "$dest" 2>/dev/null || true)"
    if [ "$target" = "$src" ]; then
      if [ -e "$dest" ]; then printf 'ok\n'; else printf 'broken\n'; fi
    elif [ ! -e "$dest" ]; then printf 'broken\n'
    else printf 'wrong\n'; fi
  elif [ -e "$dest" ]; then printf 'conflict\n'
  else printf 'missing\n'; fi
}

# ensure_symlink SRC DEST — converges DEST onto SRC. Prints the action taken:
#   current | created | repaired | would-create | would-repair | conflict
# Returns non-zero only for `conflict`: a real file sitting where the link
# belongs is a user file, and this function will not delete user files.
ensure_symlink() {
  local src="$1" dest="$2" state
  state="$(link_state "$src" "$dest")"
  case "$state" in
    ok) printf 'current\n'; return 0 ;;
    conflict) printf 'conflict\n'; return 1 ;;
  esac
  if is_dry_run; then
    case "$state" in
      missing) printf 'would-create\n' ;;
      *)       printf 'would-repair\n' ;;
    esac
    return 0
  fi
  mkdir -p "$(dirname "$dest")" || return 1
  # -f alone will not replace a symlink pointing at a directory, so the old
  # link is removed explicitly first. Only ever a symlink, never a real file.
  [ -L "$dest" ] && rm -f "$dest"
  ln -s "$src" "$dest" || return 1
  case "$state" in
    missing) printf 'created\n' ;;
    *)       printf 'repaired\n' ;;
  esac
  return 0
}

# ----------------------------------------------------------- text blocks ----
# block_state FILE — present | absent | stale (present but content differs)
# The desired body is read from stdin.
block_state() {
  local file="$1" want current
  want="$(cat)"
  [ -f "$file" ] || { printf 'absent\n'; return 0; }
  grep -qF "$BLOCK_BEGIN" "$file" 2>/dev/null || { printf 'absent\n'; return 0; }
  current="$(awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b { inb = 1; next } $0 == e { inb = 0; next } inb == 1 { print }' "$file")"
  if [ "$current" = "$want" ]; then printf 'present\n'; else printf 'stale\n'; fi
}

# ensure_block FILE — rewrites just this repository's marked region of FILE,
# creating the file if needed. Desired body on stdin. Prints the action:
#   current | created | updated | would-create | would-update
# Every line outside the markers is copied through byte-for-byte.
ensure_block() {
  local file="$1" want state tmp
  want="$(cat)"
  state="$(printf '%s\n' "$want" | block_state "$file")"
  [ "$state" = "present" ] && { printf 'current\n'; return 0; }
  if is_dry_run; then
    case "$state" in absent) printf 'would-create\n' ;; *) printf 'would-update\n' ;; esac
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp)" || return 1
  if [ -f "$file" ]; then
    awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
      $0 == b { skip = 1 } skip != 1 { print } $0 == e { skip = 0 }' "$file" > "$tmp"
    # Collapse trailing blank lines so repeated runs cannot grow the file.
    awk 'BEGIN{n=0} {lines[NR]=$0} END{last=NR; while(last>0 && lines[last]=="") last--; for(i=1;i<=last;i++) print lines[i]}' "$tmp" > "$tmp.2"
    mv "$tmp.2" "$tmp"
    [ -s "$tmp" ] && printf '\n' >> "$tmp"
  fi
  { printf '%s\n' "$BLOCK_BEGIN"; printf '%s\n' "$want"; printf '%s\n' "$BLOCK_END"; } >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  case "$state" in absent) printf 'created\n' ;; *) printf 'updated\n' ;; esac
}

# Removes this repository's marked region, leaving the rest of FILE intact.
remove_block() {
  local file="$1" b="${2:-$BLOCK_BEGIN}" e="${3:-$BLOCK_END}" tmp
  [ -f "$file" ] || return 0
  grep -qF "$b" "$file" 2>/dev/null || return 0
  is_dry_run && { plan_action UNLINK "block in $(tilde "$file")"; return 0; }
  tmp="$(mktemp)" || return 1
  awk -v b="$b" -v e="$e" '$0 == b { skip = 1 } skip != 1 { print } $0 == e { skip = 0 }' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
  return 0
}

# ------------------------------------------------------------- manifests ----
# Pipe-delimited manifests, comments and blank lines removed.
read_manifest() {
  [ -f "$1" ] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"
}

# Resolves a profile name into the manifest files it covers.
manifests_for_profile() {
  local profile="$1" line
  line="$(read_manifest "$REPO_DIR/skills/profiles.conf" | awk -F'|' -v p="$profile" '$1==p {print $2; exit}')"
  if [ -z "$line" ]; then
    [ -f "$REPO_DIR/skills/$profile.conf" ] || return 1
    line="$profile"
  fi
  printf '%s\n' "$line" | tr ',' '\n' | sed -e 's/[[:space:]]//g' -e '/^$/d'
}

# ------------------------------------------------------------------ env -----
# Loads repo .env without ever echoing a value. Only KEY=VALUE lines count.
load_env() {
  local f="$REPO_DIR/.env" line key val
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key#export }"; key="${key// /}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "$val" ] && export "$key=$val"
  done < "$f"
  debug ".env loaded ($(grep -c '=' "$f" 2>/dev/null || echo 0) candidate lines)"
}

# ------------------------------------------------------------- adapters -----
# An adapter is adapters/<name>/adapter.sh implementing: detect, paths, plan,
# apply, verify, remove. Iterating the directory means adding an agent is a
# matter of adding a folder — no dispatch table to keep in sync.
adapter_list() {
  local d
  for d in "$REPO_DIR"/adapters/*/; do
    [ -f "${d}adapter.sh" ] || continue
    basename "$d"
  done
}

adapter_run() {
  local name="$1"; shift
  local script="$REPO_DIR/adapters/$name/adapter.sh"
  [ -f "$script" ] || { fail "unknown adapter: $name"; return "$EX_CONFIG"; }
  DRY_RUN="$DRY_RUN" VERBOSE="$VERBOSE" bash "$script" "$@"
}

# Human label for an adapter, read from its own `label` subcommand.
adapter_label() { adapter_run "$1" label 2>/dev/null || printf '%s' "$1"; }

# ----------------------------------------------------------- validation -----
# Each returns 0 valid, 1 invalid, 2 no parser available (caller reports skip).
validate_json() {
  local f="$1"
  [ -f "$f" ] || return 1
  if command_exists node; then node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" >/dev/null 2>&1
  elif command_exists python3; then python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
  elif command_exists jq; then jq -e . "$f" >/dev/null 2>&1
  else return 2; fi
}

# JSON with comments and trailing commas — what OpenCode actually accepts.
validate_jsonc() {
  local f="$1"
  [ -f "$f" ] || return 1
  command_exists node || return 2
  node "$REPO_DIR/scripts/lib/merge-config.mjs" read --config "$f" >/dev/null 2>&1
}

validate_toml() {
  local f="$1"
  [ -f "$f" ] || return 1
  if command_exists python3 && python3 -c 'import tomllib' >/dev/null 2>&1; then
    python3 -c 'import tomllib,sys;tomllib.load(open(sys.argv[1],"rb"))' "$f" >/dev/null 2>&1
  else return 2; fi
}

validate_yaml() {
  local f="$1"
  [ -f "$f" ] || return 1
  if command_exists python3 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' "$f" >/dev/null 2>&1
  else return 2; fi
}

# ------------------------------------------------- config fragments ---------
# config/shared/ is symlinked into every agent's managed directory;
# config/<agent>/ into that agent's only. Dropping a file in either is all it
# takes to distribute it — no script needs to learn about the new file.
# Prints LINK|src|dest|label lines, the same protocol the adapters use.
config_fragment_links() {
  local agent="$1" managed="$2" dir src name
  for dir in "$REPO_DIR/config/shared" "$REPO_DIR/config/$agent"; do
    [ -d "$dir" ] || continue
    for src in "$dir"/*; do
      [ -f "$src" ] || continue
      name="$(basename "$src")"
      case "$name" in .gitkeep|README.md) continue ;; esac
      printf 'LINK|%s|%s|config: %s\n' "$src" "$managed/$name" "$name"
    done
  done
}

# ------------------------------------------------------------- commands -----
# The global helper commands, defined once and consumed by the installer, the
# health check and the uninstaller alike.
ai_dev_commands() {
  cat <<'CMDS'
ai-dev-sync|update.sh
ai-dev-doctor|doctor.sh
ai-dev-check|scripts/setup/check.sh
ai-dev-verify|scripts/context/verify.sh
ai-dev-audit|scripts/context/audit.sh
CMDS
}

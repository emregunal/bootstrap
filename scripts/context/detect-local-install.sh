#!/usr/bin/env bash
# detect-local-install.sh — work out where this repository actually lives, and
# where it has installed itself on this machine.
#
#   ./scripts/context/detect-local-install.sh          human-readable report
#   ./scripts/context/detect-local-install.sh --path   just the repository root
#   ./scripts/context/detect-local-install.sh --env    KEY=VALUE, for scripts
#
# Why this exists: every path in this repository is derived, never written
# down. The resolution itself lives in scripts/lib/common.sh so that sourcing
# one file is enough for any script to know where it is; this script exposes
# that answer, and cross-checks it against what is installed — which is how a
# moved or duplicated clone gets noticed.
#
# Read-only.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

MODE="report"
while [ $# -gt 0 ]; do
  case "$1" in
    --path)    MODE="path"; shift ;;
    --env)     MODE="env"; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) printf 'Usage: detect-local-install.sh [--path|--env]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

if [ "$MODE" = "path" ]; then
  printf '%s\n' "$REPO_DIR"
  exit "$EX_OK"
fi

if [ "$MODE" = "env" ]; then
  printf 'REPO_DIR=%s\n' "$REPO_DIR"
  printf 'OS=%s\n' "$(os_id)"
  printf 'BIN_DIR=%s\n' "$BIN_DIR"
  printf 'LOCAL_STATE_DIR=%s\n' "$LOCAL_STATE_DIR"
  printf 'SKILLS_HOME=%s\n' "$SKILLS_HOME"
  for agent in $(adapter_list); do
    adapter_run "$agent" detect >/dev/null 2>&1 || continue
    adapter_run "$agent" paths | sed "s/^/${agent}_/"
  done
  exit "$EX_OK"
fi

banner "Local Install"

section "Repository"
ok "Root       ${C_DIM}$REPO_DIR${C_RESET}"
ok "Resolved   ${C_DIM}$(resolve_path "$REPO_DIR")${C_RESET}"
if command_exists git && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ok "Git        ${C_DIM}branch $(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)${C_RESET}"
  remote="$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null || true)"
  [ -n "$remote" ] && ok "Remote     ${C_DIM}$remote${C_RESET}" || info "No remote configured"
else
  info "Not a git clone"
fi

section "Platform"
ok "$(os_describe)"
for c in git node npm npx; do
  if command_exists "$c"; then ok "$c  ${C_DIM}$("$c" --version 2>/dev/null | head -1)${C_RESET}"
  else warn "$c not found"; fi
done

section "Agents"
for agent in $(adapter_list); do
  label="$(adapter_run "$agent" label)"
  if adapter_run "$agent" detect >/dev/null 2>&1; then
    cfgdir="$(adapter_run "$agent" paths | sed -n 's/^CONFIG_DIR=//p')"
    ok "$label  ${C_DIM}$(tilde "$cfgdir")${C_RESET}"
  else
    info "$label not installed"
  fi
done

section "Installed here"
info "commands   $(tilde "$BIN_DIR")"
info "state      $(tilde "$LOCAL_STATE_DIR")"
info "skills     $(tilde "$SKILLS_HOME")"

# A wrapper pointing at a different clone is the single most common cause of
# "the command stopped working": the repository was moved, or cloned twice.
section "Command targets"
mismatch=0
while IFS='|' read -r name _; do
  [ -n "$name" ] || continue
  p="$BIN_DIR/$name"
  if [ ! -f "$p" ]; then
    warn "$name not installed"
    continue
  fi
  target="$(sed -n 's/^REPO="\(.*\)"$/\1/p' "$p" | head -1)"
  if [ "$target" = "$REPO_DIR" ]; then
    ok "$name  ${C_DIM}→ this clone${C_RESET}"
  elif [ -n "$target" ]; then
    fail "$name  ${C_DIM}→ $target${C_RESET}"
    mismatch=$((mismatch + 1))
  else
    warn "$name is not a managed wrapper"
  fi
done < <(ai_dev_commands)

if [ "$mismatch" -gt 0 ]; then
  printf '\n'
  warn "$mismatch command(s) point at a different clone of this repository"
  hint "Run ./bootstrap.sh from the clone you want to keep, or: ai-dev-check"
  printf '\n'
  exit "$EX_DRIFT"
fi
printf '\n'
exit "$EX_OK"

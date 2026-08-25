#!/usr/bin/env bash
# update.sh — pull repository changes and re-apply them locally.
# Installed as the `opencode-sync` command.
#
#   opencode-sync                    # pull, then sync everything
#   opencode-sync --no-pull          # re-apply without touching git
#   opencode-sync --profile frontend # sync a single profile
#
# Local changes are never discarded: the pull is fast-forward only and is
# skipped entirely when the working tree is dirty.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/helpers.sh"

PROFILE="full"
NO_PULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --no-pull)   NO_PULL=1; shift ;;
    -h|--help)   printf 'Usage: opencode-sync [--profile NAME] [--no-pull]\n'; exit 0 ;;
    *)           fail "Unknown option: $1"; exit 1 ;;
  esac
done

banner "OpenCode Bootstrap Sync"

# -------------------------------------------------------------- repository --
section "Repository"
if [ "$NO_PULL" = "1" ]; then
  info "pull skipped (--no-pull)"
elif ! has git; then
  warn "git not found — skipping pull"
elif ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  info "Not a git clone — nothing to pull"
elif [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  # Refusing to pull here is deliberate: a fast-forward can still fail
  # halfway and leave the tree in a worse state than it started.
  warn "Local changes present — pull skipped so nothing is overwritten"
  git -C "$REPO_DIR" status --short | sed 's/^/  /'
  hint "Commit or stash your changes, then run opencode-sync again"
else
  before="$(git -C "$REPO_DIR" rev-parse HEAD)"
  if git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1; then
    after="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then ok "Already up to date"
    else ok "Repository updated  ${C_DIM}${before:0:7} → ${after:0:7}${C_RESET}"; fi
  else
    warn "Fast-forward pull failed — the branch has diverged"
    hint "Resolve it manually in $REPO_DIR, then run opencode-sync again"
  fi
fi

# ------------------------------------------------------------------ skills --
section "Skills"
"$REPO_DIR/scripts/install-skills.sh" --profile "$PROFILE"

# --------------------------------------------------------------------- MCP --
section "MCP"
"$REPO_DIR/scripts/install-mcps.sh"

# ------------------------------------------------------------------ config --
section "Config"
"$REPO_DIR/scripts/install-config.sh"
"$REPO_DIR/scripts/install-aliases.sh"

# ------------------------------------------------------------------ doctor --
printf '\n'
if PROFILE="$PROFILE" "$REPO_DIR/doctor.sh"; then
  ok "Everything is up to date"
  exit 0
else
  exit 1
fi

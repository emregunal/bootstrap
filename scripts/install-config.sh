#!/usr/bin/env bash
# install-config.sh — install the global agent rules and register them with
# OpenCode via the `instructions` config field.
#
# The rules live in a directory this repository owns
# (~/.config/opencode/opencode-bootstrap/) rather than at
# ~/.config/opencode/AGENTS.md, so a personal AGENTS.md is never overwritten.
# OpenCode merges `instructions` files with AGENTS.md, so both apply.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

DRY_RUN="${DRY_RUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) DRY_RUN=1; shift ;; *) shift ;; esac
done

has node || die "node not found — required to edit the OpenCode config safely."

SRC="$REPO_DIR/config/AGENTS.md"
DEST="$MANAGED_DIR/AGENTS.md"
CFG="$(config_file)"
STATE="$MANAGED_DIR/state.json"

[ -f "$SRC" ] || die "Missing $SRC"

if [ "$DRY_RUN" = "1" ]; then
  info "would install rules to $DEST"
  info "would register it in ${CFG}'s instructions"
  exit 0
fi

mkdir -p "$MANAGED_DIR"
backup_config_dir

if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
  ok "Agent rules already current"
else
  cp "$SRC" "$DEST"
  ok "Agent rules installed  ${C_DIM}($DEST)${C_RESET}"
fi

err="$(mktemp)"
if ! node "$REPO_DIR/scripts/lib/merge-config.mjs" apply \
      --config "$CFG" --mcp "$REPO_DIR/mcp/mcps.json" --state "$STATE" \
      --instructions "$DEST" --servers "" 2>"$err"; then
  cat "$err" >&2; rm -f "$err"; die "Failed to update $CFG"
fi
grep -q '^comments-dropped:' "$err" && warn "Comments in $(basename "$CFG") were removed by the rewrite (a backup was taken)"
rm -f "$err"

ok "OpenCode config synchronized  ${C_DIM}($CFG)${C_RESET}"
exit 0

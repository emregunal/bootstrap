#!/usr/bin/env bash
# install-hooks.sh — point git at the version-controlled hooks in .githooks/.
#
# .git/hooks can never be committed, so the hooks live in .githooks/ and git is
# told to look there. One `git config` line, and every clone of this repository
# gets the same pre-commit and commit-msg checks.
#
#   install-hooks.sh [--dry-run] [--verbose]

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) printf 'Usage: install-hooks.sh [--dry-run]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

if ! command_exists git; then
  warn "git not found — hooks not installed"
  exit "$EX_OK"
fi
if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  info "Not a git clone — hooks skipped"
  exit "$EX_OK"
fi

# Relative on purpose: git resolves core.hooksPath against the top of the work
# tree, so the setting survives the repository being moved or re-cloned.
WANT=".githooks"
CURRENT="$(git -C "$REPO_DIR" config --local --get core.hooksPath 2>/dev/null || true)"

if [ "$CURRENT" = "$WANT" ]; then
  ok "core.hooksPath  ${C_DIM}$WANT${C_RESET}"
elif is_dry_run; then
  plan_action CONFIGURE "git core.hooksPath = $WANT"
else
  git -C "$REPO_DIR" config core.hooksPath "$WANT"
  ok "core.hooksPath set to $WANT"
fi

for hook in "$REPO_DIR"/.githooks/*; do
  [ -f "$hook" ] || continue
  name="$(basename "$hook")"
  if [ -x "$hook" ]; then
    ok "$name"
  elif is_dry_run; then
    plan_action CHMOD "$(repo_relative "$hook")  (make executable)"
  else
    chmod +x "$hook"
    ok "$name  ${C_DIM}(made executable)${C_RESET}"
  fi
done
exit "$EX_OK"

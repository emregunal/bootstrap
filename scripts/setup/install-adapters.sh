#!/usr/bin/env bash
# install-adapters.sh — install the global rules and config fragments into
# every AI agent present on this machine.
#
# The per-agent knowledge lives in adapters/<agent>/adapter.sh; this script
# only decides who is present and reports the results uniformly. Adding
# support for another agent means adding a directory, not editing this file.
#
#   install-adapters.sh [--dry-run] [--verbose] [--agent NAME]

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --agent)   [ $# -ge 2 ] || die "$EX_FAIL" "--agent needs a value"; ONLY="$2"; shift 2 ;;
    --agent=*) ONLY="${1#*=}"; shift ;;
    -h|--help) printf 'Usage: install-adapters.sh [--dry-run] [--verbose] [--agent NAME]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done
export DRY_RUN VERBOSE

[ -f "$REPO_DIR/rules/global.md" ] || die "$EX_CONFIG" "Missing rules/global.md"

found=0
for agent in $(adapter_list); do
  [ -n "$ONLY" ] && [ "$ONLY" != "$agent" ] && continue
  label="$(adapter_run "$agent" label)"
  if ! adapter_run "$agent" detect >/dev/null 2>&1; then
    info "$label not installed — skipped"
    continue
  fi
  found=$((found + 1))
  section "$label"
  adapter_run "$agent" apply
done

if [ "$found" -eq 0 ]; then
  warn "No supported agent found (OpenCode, Claude Code or Codex)"
  hint "Install at least one, then run: ai-dev-sync"
fi
exit "$EX_OK"

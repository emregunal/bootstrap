#!/usr/bin/env bash
# doctor.sh — the full read-only health report.
# Installed as the `ai-dev-doctor` command.
#
#   ai-dev-doctor          check + verify
#   ai-dev-doctor --full   also audit and run the behaviour tests
#
# Read-only by definition: it runs check.sh in --no-repair mode so that what
# you see is the state of the machine, not the state after a quiet fix. Run
# ai-dev-check when you want the repairs.
#
# Exit: 0 healthy, otherwise the worst exit code of the stages it ran
#       (2 config, 4 security, 5 drift).

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/common.sh"

FULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --full)    FULL=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) printf 'Usage: ai-dev-doctor [--full] [--verbose]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done
export VERBOSE

WORST=0
note() { [ "$1" -gt "$WORST" ] && WORST="$1"; return 0; }

banner "AI Dev Doctor"
info "$(now_stamp)  ·  $(os_describe)"
info "Repository  $REPO_DIR"

rc=0; "$REPO_DIR/scripts/setup/check.sh" --no-repair || rc=$?; note "$rc"
rc=0; "$REPO_DIR/scripts/context/verify.sh" || rc=$?; note "$rc"

if [ "$FULL" = "1" ]; then
  rc=0; "$REPO_DIR/scripts/context/audit.sh" || rc=$?; note "$rc"
  rc=0; "$REPO_DIR/scripts/context/behavior-check.sh" || rc=$?; note "$rc"
fi

banner "Doctor summary"
case "$WORST" in
  0) ok "Everything checks out"
     [ "$FULL" = "1" ] || hint "Deeper inspection: ai-dev-doctor --full" ;;
  "$EX_DRIFT")    warn "Drift found — run: ai-dev-sync" ;;
  "$EX_SECURITY") fail "Security problem — run: ai-dev-audit" ;;
  "$EX_CONFIG")   fail "Configuration problem — run: ai-dev-check" ;;
  *)              fail "Problems found (exit $WORST)" ;;
esac
printf '\n'
exit "$WORST"

#!/usr/bin/env bash
# setup.sh — the whole installation, in order. bootstrap.sh is a thin front
# door onto this file; there is no second copy of this logic anywhere.
#
#   ./scripts/setup/setup.sh [--profile NAME] [--dry-run] [--skip-skills]
#                            [--skip-mcp] [--no-shell-rc] [--verbose]
#
# Order matters:
#   directories → backup → adapters (rules) → commands → hooks → skills → MCP → check
# MCP comes after commands because the credential bridge it writes is only
# useful once the shell rc block that sources it exists.
#
# Idempotent by construction: every step converges rather than appends. Running
# it three times in a row leaves exactly the state one run leaves.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

PROFILE="full"
SKIP_SKILLS=0
SKIP_MCP=0
NO_RC=0
usage() {
  cat <<USAGE
Usage: ./bootstrap.sh [options]

  --profile NAME   frontend | backend | database | devops | testing | security | full
                   (default: full; any skills/<name>.conf works too)
  --dry-run        report the planned changes and make none
  --skip-skills    do not install skills
  --skip-mcp       do not configure MCP servers
  --no-shell-rc    do not touch the shell rc file
  --verbose        show debug output
  -h, --help       this message
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)     [ $# -ge 2 ] || die "$EX_FAIL" "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --profile=*)   PROFILE="${1#*=}"; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --skip-skills) SKIP_SKILLS=1; shift ;;
    --skip-mcp)    SKIP_MCP=1; shift ;;
    --no-shell-rc) NO_RC=1; shift ;;
    --verbose)     VERBOSE=1; shift ;;
    -h|--help)     usage; exit "$EX_OK" ;;
    *)             fail "Unknown option: $1"; usage; exit "$EX_FAIL" ;;
  esac
done
export DRY_RUN VERBOSE

DRY=()
is_dry_run && DRY=(--dry-run)
VERB=()
[ "$VERBOSE" = "1" ] && VERB=(--verbose)

banner "AI Dev Bootstrap"
is_dry_run && warn "Dry run — nothing will be modified"
info "Repository  $REPO_DIR"
info "Profile     $PROFILE"

# ------------------------------------------------------- 1-3. environment ---
step "1/8" "Environment"
ok "$(os_describe)"
MISSING=0
for c in git node npm npx; do
  if command_exists "$c"; then
    ok "$c  ${C_DIM}$("$c" --version 2>/dev/null | head -1)${C_RESET}"
  else
    fail "$c not found"; MISSING=1
  fi
done
if [ "$MISSING" = "1" ]; then
  printf '\n'
  fail "Install the missing tools and re-run."
  case "$(os_id)" in
    macos) hint "brew install git node" ;;
    *)     hint "sudo apt update && sudo apt install -y git curl"
           hint "curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs" ;;
  esac
  exit "$EX_DEPS"
fi

FOUND_AGENT=0
for agent in $(adapter_list); do
  label="$(adapter_run "$agent" label)"
  if adapter_run "$agent" detect >/dev/null 2>&1; then
    ok "$label detected"; FOUND_AGENT=1
  else
    info "$label not installed"
  fi
done
if [ "$FOUND_AGENT" = "0" ]; then
  printf '\n'
  fail "No supported AI agent found on this machine."
  hint "OpenCode:     curl -fsSL https://opencode.ai/install | bash"
  hint "Claude Code:  https://claude.com/claude-code"
  hint "Codex:        npm i -g @openai/codex"
  exit "$EX_DEPS"
fi

# ------------------------------------------------------------ 4. directories -
step "2/8" "Directories"
for d in "$BIN_DIR" "$LOCAL_STATE_DIR" "$STATE_DIR"; do
  if [ -d "$d" ]; then ok "$(tilde "$d")"
  elif is_dry_run; then ensure_directory "$d"
  else ensure_directory "$d" && ok "created $(tilde "$d")"; fi
done

# ---------------------------------------------------------------- 5. backup -
step "3/8" "Backup"
if is_dry_run; then
  info "skipped in dry run"
elif [ -d "$OPENCODE_CONFIG_DIR" ]; then
  backup_config_dir
  ok "Existing config backed up before any write"
else
  info "Nothing to back up yet"
fi

# ------------------------------------------------- 6+11. adapters and rules -
step "4/8" "Agents"
"$REPO_DIR/scripts/setup/install-adapters.sh" "${DRY[@]+"${DRY[@]}"}" "${VERB[@]+"${VERB[@]}"}"

# --------------------------------------------------------------- 7. commands -
step "5/8" "Commands"
RCFLAG=()
[ "$NO_RC" = "1" ] && RCFLAG=(--no-shell-rc)
"$REPO_DIR/scripts/setup/install-commands.sh" "${DRY[@]+"${DRY[@]}"}" "${VERB[@]+"${VERB[@]}"}" "${RCFLAG[@]+"${RCFLAG[@]}"}"

# ------------------------------------------------------------------ 8. hooks -
step "6/8" "Git hooks"
"$REPO_DIR/scripts/setup/install-hooks.sh" "${DRY[@]+"${DRY[@]}"}" "${VERB[@]+"${VERB[@]}"}"

# ----------------------------------------------------------------- 9. skills -
step "7/8" "Skills"
if [ "$SKIP_SKILLS" = "1" ]; then
  info "skipped (--skip-skills)"
else
  "$REPO_DIR/scripts/setup/install-skills.sh" --profile "$PROFILE" "${DRY[@]+"${DRY[@]}"}" "${VERB[@]+"${VERB[@]}"}"
fi

# -------------------------------------------------------------------- 10. MCP
step "8/8" "MCP"
if [ "$SKIP_MCP" = "1" ]; then
  info "skipped (--skip-mcp)"
else
  if [ ! -f "$REPO_DIR/.env" ] && ! is_dry_run; then
    warn "No .env file — servers needing a key are configured but unauthenticated"
    hint "cp .env.example .env, fill in what you have, then run: ai-dev-sync"
  fi
  "$REPO_DIR/scripts/setup/install-mcps.sh" "${DRY[@]+"${DRY[@]}"}" "${VERB[@]+"${VERB[@]}"}"
fi

# ------------------------------------------------------------------- 12. check
printf '\n'
if is_dry_run; then
  banner "Dry run complete"
  hint "Nothing was changed. Run without --dry-run to apply."
  exit "$EX_OK"
fi

rc=0
"$REPO_DIR/scripts/setup/check.sh" || rc=$?
printf '\n'
if [ "$rc" = "0" ]; then
  banner "Bootstrap complete"
  printf '\n'
  hint "ai-dev-doctor   full health report"
  hint "ai-dev-check    check and repair the installation"
  hint "ai-dev-verify   compare this machine against the repository"
  hint "ai-dev-audit    deep inspection"
  hint "ai-dev-sync     pull repository updates and re-apply them"
  if ! path_has_dir "$BIN_DIR"; then
    printf '\n'
    warn "Open a new shell before using those commands:  exec \$SHELL -l"
  fi
  exit "$EX_OK"
else
  banner "Bootstrap finished with problems"
  hint "See the check output above; each problem lists its fix."
  exit "$rc"
fi

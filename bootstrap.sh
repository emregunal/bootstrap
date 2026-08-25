#!/usr/bin/env bash
# bootstrap.sh — set up this machine's OpenCode environment from scratch.
#
#   ./bootstrap.sh                      # full profile
#   ./bootstrap.sh --profile frontend   # frontend skills only
#   ./bootstrap.sh --dry-run            # show what would happen, change nothing
#   ./bootstrap.sh --skip-skills        # config + MCP + aliases only
#
# Idempotent: running it repeatedly converges on the same state.
# It never deletes ~/.config/opencode and never rewrites config keys it does
# not own. A backup of the config directory is taken before the first write.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/helpers.sh"

PROFILE="full"
DRY_RUN=0
SKIP_SKILLS=0
SKIP_MCP=0

usage() {
  cat <<USAGE
Usage: ./bootstrap.sh [options]

  --profile NAME   frontend | backend | devops | testing | security | full
                   (default: full; any skills/<name>.conf also works)
  --dry-run        report planned changes without making any
  --skip-skills    do not install skills
  --skip-mcp       do not configure MCP servers
  -h, --help       this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)     [ $# -ge 2 ] || die "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --profile=*)   PROFILE="${1#*=}"; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --skip-skills) SKIP_SKILLS=1; shift ;;
    --skip-mcp)    SKIP_MCP=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             fail "Unknown option: $1"; usage; exit 1 ;;
  esac
done
export DRY_RUN

DRY=()
[ "$DRY_RUN" = "1" ] && DRY=(--dry-run)

banner "OpenCode Bootstrap"
[ "$DRY_RUN" = "1" ] && warn "Dry run — nothing will be modified"
info "Profile: $PROFILE"

# ------------------------------------------------------------- 1. environment
step "1/6" "Environment"
ok "$(os_name)"
FATAL=0
for c in git node npm npx; do
  if has "$c"; then
    ok "$c  ${C_DIM}$("$c" --version 2>/dev/null | head -1)${C_RESET}"
  else
    fail "$c not found"
    FATAL=1
  fi
done
if [ "$FATAL" = "1" ]; then
  printf '\n'
  die "Install the missing tools and re-run. On Ubuntu/WSL:
  sudo apt update && sudo apt install -y git curl
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt install -y nodejs"
fi

# ---------------------------------------------------------------- 2. opencode
step "2/6" "OpenCode"
if has opencode; then
  ok "OpenCode detected  ${C_DIM}$(opencode --version 2>/dev/null | head -1)${C_RESET}"
else
  fail "opencode not found on PATH"
  hint "Install it, then re-run this script:"
  hint "  curl -fsSL https://opencode.ai/install | bash"
  die "OpenCode is required."
fi

if [ -d "$OPENCODE_CONFIG_DIR" ]; then
  ok "Config directory  ${C_DIM}$OPENCODE_CONFIG_DIR${C_RESET}"
else
  if [ "$DRY_RUN" = "1" ]; then info "would create $OPENCODE_CONFIG_DIR"
  else mkdir -p "$OPENCODE_CONFIG_DIR"; ok "Config directory created  ${C_DIM}$OPENCODE_CONFIG_DIR${C_RESET}"; fi
fi

# The backup happens here, before any script has a chance to write.
if [ "$DRY_RUN" != "1" ]; then backup_config_dir; fi

# ------------------------------------------------------------------ 3. skills
step "3/6" "Skills"
if [ "$SKIP_SKILLS" = "1" ]; then
  info "skipped (--skip-skills)"
else
  "$REPO_DIR/scripts/install-skills.sh" --profile "$PROFILE" "${DRY[@]+"${DRY[@]}"}"
fi

# --------------------------------------------------------------------- 4. mcp
step "4/6" "MCP"
if [ "$SKIP_MCP" = "1" ]; then
  info "skipped (--skip-mcp)"
elif [ ! -f "$REPO_DIR/.env" ] && [ "$DRY_RUN" != "1" ]; then
  warn "No .env file — servers needing an API key will be configured but unauthenticated"
  hint "cp .env.example .env  and fill in what you have, then run: opencode-sync"
  "$REPO_DIR/scripts/install-mcps.sh" "${DRY[@]+"${DRY[@]}"}"
else
  "$REPO_DIR/scripts/install-mcps.sh" "${DRY[@]+"${DRY[@]}"}"
fi

# ------------------------------------------------------------------ 5. config
step "5/6" "Config"
"$REPO_DIR/scripts/install-config.sh" "${DRY[@]+"${DRY[@]}"}"
"$REPO_DIR/scripts/install-aliases.sh" "${DRY[@]+"${DRY[@]}"}"

# ------------------------------------------------------------------ 6. doctor
step "6/6" "Doctor"
if [ "$DRY_RUN" = "1" ]; then
  info "skipped in dry run"
  exit 0
fi

printf '\n'
if PROFILE="$PROFILE" "$REPO_DIR/doctor.sh"; then
  banner "Bootstrap complete"
  hint "opencode-doctor   check environment health"
  hint "opencode-sync     pull repo updates and re-apply"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf '\n'; warn "Open a new shell (or source your rc file) before using those commands." ;;
  esac
  exit 0
else
  banner "Bootstrap finished with problems"
  hint "See the Doctor output above; each problem lists its fix."
  exit 1
fi

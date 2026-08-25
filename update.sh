#!/usr/bin/env bash
# update.sh — pull the repository and re-apply it to this machine.
# Installed as the `ai-dev-sync` command.
#
#   ai-dev-sync                      pull, then sync everything
#   ai-dev-sync --no-pull            re-apply without touching git
#   ai-dev-sync --profile frontend   sync one profile
#   ai-dev-sync --refresh-skills     re-download skills that are already present
#   ai-dev-sync --dry-run            show what would change
#
# Local work is never discarded: the pull is fast-forward only and is skipped
# entirely when the working tree is dirty.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/common.sh"

PROFILE="full"
NO_PULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)        [ $# -ge 2 ] || die "$EX_FAIL" "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --profile=*)      PROFILE="${1#*=}"; shift ;;
    --no-pull)        NO_PULL=1; shift ;;
    --refresh-skills) REFRESH_SKILLS=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --verbose)        VERBOSE=1; shift ;;
    -h|--help)        printf 'Usage: ai-dev-sync [--profile NAME] [--no-pull] [--refresh-skills] [--dry-run]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done
export DRY_RUN VERBOSE REFRESH_SKILLS="${REFRESH_SKILLS:-0}"

DRY=()
is_dry_run && DRY=(--dry-run)

banner "AI Dev Sync"
is_dry_run && warn "Dry run — nothing will be modified"

# -------------------------------------------------------------- repository --
section "Repository"
if [ "$NO_PULL" = "1" ]; then
  info "pull skipped (--no-pull)"
elif ! command_exists git; then
  warn "git not found — skipping pull"
elif ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  info "Not a git clone — nothing to pull"
elif [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  # Refusing to pull here is deliberate: a fast-forward can still fail halfway
  # and leave the tree in a worse state than it started in.
  warn "Local changes present — pull skipped so nothing is overwritten"
  git -C "$REPO_DIR" status --short | sed 's/^/  /'
  hint "Commit or stash, then run ai-dev-sync again"
elif ! git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  info "No upstream branch configured — nothing to pull"
  hint "git push -u origin $(git -C "$REPO_DIR" branch --show-current)"
elif is_dry_run; then
  plan_action PULL "$(git -C "$REPO_DIR" rev-parse --abbrev-ref '@{u}')"
else
  before="$(git -C "$REPO_DIR" rev-parse HEAD)"
  if git -C "$REPO_DIR" pull --ff-only >/dev/null 2>&1; then
    after="$(git -C "$REPO_DIR" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then ok "Already up to date"
    else
      ok "Updated  ${C_DIM}${before:0:7} → ${after:0:7}${C_RESET}"
      git -C "$REPO_DIR" --no-pager log --oneline "${before}..${after}" | head -10 | sed 's/^/  /'
    fi
  else
    warn "Fast-forward pull failed — the branch has diverged"
    hint "Resolve it in $REPO_DIR, then run ai-dev-sync again"
  fi
fi

# -------------------------------------------------------------------- apply --
section "Agents"
"$REPO_DIR/scripts/setup/install-adapters.sh" "${DRY[@]+"${DRY[@]}"}"

section "Commands"
"$REPO_DIR/scripts/setup/install-commands.sh" "${DRY[@]+"${DRY[@]}"}"

section "Git hooks"
"$REPO_DIR/scripts/setup/install-hooks.sh" "${DRY[@]+"${DRY[@]}"}"

section "Skills"
"$REPO_DIR/scripts/setup/install-skills.sh" --profile "$PROFILE" "${DRY[@]+"${DRY[@]}"}"

section "MCP"
"$REPO_DIR/scripts/setup/install-mcps.sh" "${DRY[@]+"${DRY[@]}"}"

# ------------------------------------------------------------------- verify --
if is_dry_run; then
  printf '\n'; banner "Dry run complete"
  exit "$EX_OK"
fi

printf '\n'
rc=0
"$REPO_DIR/scripts/context/verify.sh" --quiet || rc=$?
printf '\n'
crc=0
"$REPO_DIR/scripts/setup/check.sh" || crc=$?

printf '\n'
if [ "$rc" = "0" ] && [ "$crc" = "0" ]; then
  ok "Everything is up to date"
  exit "$EX_OK"
fi
[ "$crc" != "0" ] && exit "$crc"
exit "$rc"

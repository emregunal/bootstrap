#!/usr/bin/env bash
# install-skills.sh — install/refresh the global OpenCode skills listed in
# skills/*.conf. Safe to re-run: the skills CLI overwrites an existing skill
# with the current upstream version rather than failing.
#
#   install-skills.sh [--profile NAME] [--dry-run]

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PROFILE="${PROFILE:-full}"
DRY_RUN="${DRY_RUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) shift ;;
  esac
done

# --- resolve the profile into a list of manifest files ---------------------
manifests_for_profile() {
  local profile="$1" line
  line="$(read_manifest "$REPO_DIR/skills/profiles.conf" | awk -F'|' -v p="$profile" '$1==p {print $2; exit}')"
  if [ -z "$line" ]; then
    # Any manifest file name doubles as a profile of its own.
    if [ -f "$REPO_DIR/skills/$profile.conf" ]; then line="$profile"; else return 1; fi
  fi
  printf '%s\n' "$line" | tr ',' '\n' | sed '/^[[:space:]]*$/d'
}

if ! MANIFESTS="$(manifests_for_profile "$PROFILE")"; then
  fail "Unknown profile: $PROFILE"
  hint "Available: $(read_manifest "$REPO_DIR/skills/profiles.conf" | cut -d'|' -f1 | tr '\n' ' ')"
  exit 1
fi

has npx || die "npx not found — install Node.js first."

installed=0; failed=0
mkdir -p "$SKILLS_HOME"

for m in $MANIFESTS; do
  f="$REPO_DIR/skills/$m.conf"
  [ -f "$f" ] || { warn "Manifest not found: $m.conf"; continue; }
  while IFS='|' read -r repo skill; do
    repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
    skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
    [ -n "$repo" ] && [ -n "$skill" ] || continue

    if [ "$DRY_RUN" = "1" ]; then info "would install $skill  ($repo)"; continue; fi

    # A single failing skill must not abort the run, so the CLI call is
    # guarded and its output kept for the failure report only.
    log="$(mktemp)"
    # stdin is redirected from /dev/null for two reasons: npx would otherwise
    # swallow the manifest lines this loop is reading, and the skills CLI would
    # block on an interactive prompt instead of failing cleanly.
    if npx -y skills@latest add "${repo}@${skill}" -g -a opencode -y \
         </dev/null >"$log" 2>&1; then
      ok "$skill"
      installed=$((installed + 1))
    else
      fail "$skill  ${C_DIM}($repo)${C_RESET}"
      hint "$(tail -n 3 "$log" | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | tr '\n' ' ')"
      failed=$((failed + 1))
    fi
    rm -f "$log"
  done < <(read_manifest "$f")
done

if [ "$DRY_RUN" = "1" ]; then exit 0; fi

printf '\n%s installed\n' "$installed"
printf '%s failed\n' "$failed"
if [ "$failed" -gt 0 ]; then
  hint "Retry a single skill with: npx skills@latest add <owner/repo@skill> -g -a opencode -y"
fi
# Skill failures are non-fatal by design: a broken upstream repository should
# not block the rest of the environment from being set up.
exit 0

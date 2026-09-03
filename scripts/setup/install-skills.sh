#!/usr/bin/env bash
# install-skills.sh — install the global skills listed in skills/*.conf into
# every agent present on this machine.
#
# The `skills` CLI keeps one canonical copy per skill in ~/.agents/skills and
# symlinks it into each agent's own directory, which is why one install covers
# OpenCode, Claude Code and Codex at once. Re-running refreshes to the current
# upstream version rather than failing.
#
#   install-skills.sh [--profile NAME] [--dry-run] [--verbose]

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

PROFILE="${PROFILE:-full}"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   [ $# -ge 2 ] || die "$EX_FAIL" "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    -h|--help)   printf 'Usage: install-skills.sh [--profile NAME] [--dry-run]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

if ! MANIFESTS="$(manifests_for_profile "$PROFILE")"; then
  fail "Unknown profile: $PROFILE"
  hint "Available: $(read_manifest "$REPO_DIR/skills/profiles.conf" | cut -d'|' -f1 | tr '\n' ' ')"
  exit "$EX_CONFIG"
fi

# Which agents to install into: whichever ones are actually on this machine.
AGENTS=""
for agent in $(adapter_list); do
  adapter_run "$agent" detect >/dev/null 2>&1 || continue
  id="$(adapter_run "$agent" paths | sed -n 's/^SKILLS_AGENT=//p')"
  [ -n "$id" ] || continue
  case ",$AGENTS," in *",$id,"*) ;; *) AGENTS="${AGENTS:+$AGENTS,}$id" ;; esac
done
[ -n "$AGENTS" ] || AGENTS="opencode"
info "Target agents: $AGENTS"

# The skills CLI takes one -a per agent; a comma-joined value is read as a
# single (invalid) agent name. Build the repeated-flag argument list once.
AGENT_FLAGS=()
_old_ifs="$IFS"; IFS=','
for _a in $AGENTS; do [ -n "$_a" ] && AGENT_FLAGS+=(-a "$_a"); done
IFS="$_old_ifs"

if ! command_exists npx; then
  if is_dry_run; then warn "npx not found — skills would be skipped"; exit "$EX_OK"; fi
  die "$EX_DEPS" "npx not found — install Node.js first."
fi

installed=0; failed=0; skipped=0
is_dry_run || ensure_directory "$SKILLS_HOME"

for m in $MANIFESTS; do
  f="$REPO_DIR/skills/$m.conf"
  [ -f "$f" ] || { warn "Manifest not found: $m.conf"; continue; }
  while IFS='|' read -r repo skill; do
    repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
    skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
    [ -n "$repo" ] && [ -n "$skill" ] || continue

    if is_dry_run; then plan_action INSTALL "$skill  ${C_DIM}($repo)${C_RESET}"; continue; fi

    # Already present and this is a re-sync: the CLI would re-download it, so
    # skip unless the skill is genuinely missing. `ai-dev-sync --refresh-skills`
    # is the way to force an update.
    if [ "${REFRESH_SKILLS:-0}" != "1" ] && [ -f "$SKILLS_HOME/$skill/SKILL.md" ]; then
      debug "$skill already installed"
      skipped=$((skipped + 1))
      continue
    fi

    log="$(mktemp)"
    # stdin from /dev/null for two reasons: npx would otherwise swallow the
    # manifest lines this loop is reading, and the CLI would block on a prompt.
    if npx -y skills@latest add "${repo}@${skill}" -g "${AGENT_FLAGS[@]}" -y </dev/null >"$log" 2>&1; then
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

is_dry_run && exit "$EX_OK"

printf '\n'
info "$installed installed, $skipped already present, $failed failed"
if [ "$failed" -gt 0 ]; then
  hint "Retry one with: npx skills@latest add <owner/repo@skill> -g -a $AGENTS -y"
fi
# A broken upstream skill repository must not block the rest of the setup.
exit "$EX_OK"

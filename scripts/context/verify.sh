#!/usr/bin/env bash
# verify.sh — does this machine match what the repository declares?
#
# Installed as the `ai-dev-verify` command.
#
#     repository (desired state)  ──compare──▶  local machine (actual state)
#
# Read-only, always. It changes nothing, ever — not even a repair that check.sh
# would consider safe. That separation is the point: verify tells you the truth
# about drift, check is what acts on it.
#
# Exit: 0 in sync, 5 drift detected, 2 a manifest is unreadable.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

PROFILE="${PROFILE:-full}"
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)   [ $# -ge 2 ] || die "$EX_FAIL" "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --quiet)     QUIET=1; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    -h|--help)   printf 'Usage: ai-dev-verify [--profile NAME] [--quiet]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

DRIFT=0
BROKEN=0
drift()  { warn "$1"; DRIFT=$((DRIFT + 1)); return 0; }
broken() { fail "$1"; BROKEN=$((BROKEN + 1)); return 0; }

load_env || true
banner "Context Verification"

# ------------------------------------------------------------------ skills --
section "Skills"
if ! MANIFESTS="$(manifests_for_profile "$PROFILE")"; then
  broken "Unknown profile: $PROFILE"
  MANIFESTS=""
else
  ok "manifests valid  ${C_DIM}profile: $PROFILE${C_RESET}"
fi

declared=0; present=0; missing_list=""
for m in $MANIFESTS; do
  f="$REPO_DIR/skills/$m.conf"
  [ -f "$f" ] || { broken "skills/$m.conf declared by the profile but missing"; continue; }
  while IFS='|' read -r _ skill; do
    skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
    [ -n "$skill" ] || continue
    declared=$((declared + 1))
    if [ -f "$SKILLS_HOME/$skill/SKILL.md" ]; then
      present=$((present + 1))
      [ "$QUIET" = "1" ] || debug "skill present: $skill"
    else
      missing_list="$missing_list $skill"
    fi
  done < <(read_manifest "$f")
done
if [ -z "$missing_list" ]; then
  ok "$present/$declared skills installed"
else
  drift "$((declared - present))/$declared skills missing"
  for s in $missing_list; do hint "$s"; done
  hint "Run: ai-dev-sync"
fi

# --------------------------------------------------------------------- MCP --
section "MCP"
MANIFEST="$REPO_DIR/mcp/mcps.json"
if [ ! -f "$MANIFEST" ]; then
  broken "mcp/mcps.json is missing"
elif ! validate_json "$MANIFEST"; then
  broken "mcp/mcps.json does not parse"
else
  ok "manifest valid  ${C_DIM}$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST" | wc -l | tr -d ' ') server(s) declared${C_RESET}"
  if command_exists node; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      status="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server "$name")"
      case "$status" in
        ok)        ok "$name" ;;
        optional:*) ok "$name  ${C_DIM}(no \$${status#optional:} — anonymous/rate-limited)${C_RESET}" ;;
        missing:*)  warn "$name  ${C_DIM}\$${status#missing:} not set${C_RESET}" ;;
      esac
    done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST")
  fi
fi

# ------------------------------------------------------------------- rules --
section "Rules"
if [ -f "$REPO_DIR/rules/global.md" ]; then
  ok "rules/global.md  ${C_DIM}$(wc -l < "$REPO_DIR/rules/global.md" | tr -d ' ') lines${C_RESET}"
else
  broken "rules/global.md is missing"
fi

# ---------------------------------------------------------------- adapters --
section "Adapters"
for agent in $(adapter_list); do
  label="$(adapter_run "$agent" label)"
  if ! adapter_run "$agent" detect >/dev/null 2>&1; then
    info "$label not installed — skipped"
    continue
  fi
  rc=0
  out="$(adapter_run "$agent" verify)" || rc=$?
  agent_drift=0
  while IFS='|' read -r status desc detail; do
    [ -n "${status:-}" ] || continue
    case "$status" in
      OK)    [ "$QUIET" = "1" ] || ok "$label: $desc" ;;
      MISS)  drift "$label: $desc — ${detail:-missing}"; agent_drift=1 ;;
      DRIFT) drift "$label: $desc — ${detail:-drifted}"; agent_drift=1 ;;
      WARN)  warn "$label: $desc — ${detail:-}" ;;
      SKIP)  info "$label: $desc — ${detail:-skipped}" ;;
    esac
  done <<EOF
$out
EOF
  [ "$agent_drift" = "0" ] && [ "$rc" = "0" ] && ok "$label in sync"
done

# ------------------------------------------------------------ local state ---
section "Local state"
while IFS='|' read -r name _; do
  [ -n "$name" ] || continue
  p="$BIN_DIR/$name"
  if [ ! -f "$p" ]; then
    drift "command $name is not installed"
  elif grep -q "$WRAPPER_MARKER" "$p" 2>/dev/null && ! grep -qF "REPO=\"$REPO_DIR\"" "$p" 2>/dev/null; then
    drift "command $name points at a different clone"
  else
    [ "$QUIET" = "1" ] || ok "command $name"
  fi
done < <(ai_dev_commands)

if [ -f "$ENV_BRIDGE" ]; then
  mode="$(file_mode "$ENV_BRIDGE" 2>/dev/null || echo '')"
  if [ "$mode" = "600" ]; then ok "credential bridge  ${C_DIM}$(tilde "$ENV_BRIDGE") (600)${C_RESET}"
  else warn "credential bridge is mode $mode, expected 600"; fi
else
  info "credential bridge not generated yet"
fi

# ------------------------------------------------------------------ hooks ---
section "Hooks"
if command_exists git && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  hp="$(git -C "$REPO_DIR" config --local --get core.hooksPath 2>/dev/null || true)"
  if [ "$hp" = ".githooks" ]; then ok "core.hooksPath"
  else drift "core.hooksPath is '${hp:-unset}', expected .githooks"; fi
  for hook in pre-commit commit-msg; do
    if [ -x "$REPO_DIR/.githooks/$hook" ]; then ok "$hook"
    else drift "$hook is missing or not executable"; fi
  done
else
  info "Not a git clone — hooks not applicable"
fi

# ----------------------------------------------------------------- result ---
section "Result"
if [ "$BROKEN" -gt 0 ]; then
  fail "$BROKEN repository problem(s), $DRIFT drift item(s)"
  printf '\n'
  exit "$EX_CONFIG"
elif [ "$DRIFT" -gt 0 ]; then
  warn "Config drift detected  ${C_DIM}($DRIFT item(s))${C_RESET}"
  printf '\n%s\n' "Run:"
  printf '%s\n' "  ai-dev-sync     apply the repository's state to this machine"
  printf '%s\n' "  ai-dev-check    repair links and commands only"
  printf '\n'
  exit "$EX_DRIFT"
else
  ok "Local machine matches the repository"
  printf '\n'
  exit "$EX_OK"
fi

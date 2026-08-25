#!/usr/bin/env bash
# doctor.sh — read-only health check of the OpenCode environment.
# This script never writes, installs or modifies anything.
#
# Exit code: 0 when everything required is present, 1 when something is broken.
# Warnings (optional pieces) do not affect the exit code.

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/helpers.sh"

PROBLEMS=0
WARNINGS=0
problem() { fail "$1"; PROBLEMS=$((PROBLEMS + 1)); [ $# -gt 1 ] && printf '%s\n' "  ${C_DIM}Fix: $2${C_RESET}" || true; }
soft()    { warn "$1"; WARNINGS=$((WARNINGS + 1)); [ $# -gt 1 ] && printf '%s\n' "  ${C_DIM}Fix: $2${C_RESET}" || true; }

load_env || true

banner "OpenCode Environment"

# ------------------------------------------------------------------ system --
section "System"
ok "$(os_name)"
for c in git node npm npx; do
  if has "$c"; then ok "$c  ${C_DIM}$("$c" --version 2>/dev/null | head -1)${C_RESET}"
  else problem "$c not found" "install $c"; fi
done

# ---------------------------------------------------------------- opencode --
section "OpenCode"
if has opencode; then
  ok "Installed  ${C_DIM}$(opencode --version 2>/dev/null | head -1)${C_RESET}"
else
  problem "opencode not found" "curl -fsSL https://opencode.ai/install | bash"
fi

CFG="$(config_file)"
if [ -d "$OPENCODE_CONFIG_DIR" ]; then
  ok "Config directory  ${C_DIM}$OPENCODE_CONFIG_DIR${C_RESET}"
else
  problem "Config directory missing: $OPENCODE_CONFIG_DIR" "./bootstrap.sh"
fi

if [ -f "$CFG" ]; then
  if has node && node "$REPO_DIR/scripts/lib/merge-config.mjs" read --config "$CFG" >/dev/null 2>&1; then
    ok "Config parses  ${C_DIM}$(basename "$CFG")${C_RESET}"
  else
    problem "Config does not parse: $CFG" "restore from ${OPENCODE_CONFIG_DIR}.backup-*"
  fi
else
  problem "No config file at $CFG" "./bootstrap.sh"
fi

if [ -f "$MANAGED_DIR/AGENTS.md" ]; then
  ok "Global agent rules"
else
  problem "Global agent rules not installed" "./scripts/install-config.sh"
fi

# ---------------------------------------------------------- authentication --
section "Authentication"
AUTH="$OPENCODE_DATA_DIR/auth.json"
if [ -f "$AUTH" ] && [ -s "$AUTH" ]; then
  # Read only the provider keys. Credential values are never touched.
  if has node; then
    provs="$(node -e '
      try {
        const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.stdout.write(Object.keys(a).join(" "));
      } catch { process.stdout.write(""); }
    ' "$AUTH" 2>/dev/null || true)"
  else
    provs=""
  fi
  if [ -n "$provs" ]; then ok "Credentials present  ${C_DIM}$provs${C_RESET}"
  else soft "auth.json present but no providers parsed" "opencode auth login"; fi
else
  soft "No provider credentials configured" "opencode auth login"
fi

# The Antigravity provider is an optional community plugin. Bootstrap only
# reports on it — it never installs it and never touches OAuth tokens.
if has node && [ -f "$CFG" ] && node -e '
    const fs=require("fs");
    const s=fs.readFileSync(process.argv[1],"utf8");
    process.exit(/antigravity/i.test(s) ? 0 : 1);
  ' "$CFG" 2>/dev/null; then
  ok "Antigravity plugin configured"
  if [ -f "$AUTH" ] && grep -qi 'antigravity' "$AUTH" 2>/dev/null; then
    ok "Antigravity authentication present"
  else
    soft "Antigravity plugin configured but not authenticated" "opencode auth login  (choose Antigravity)"
  fi
else
  info "Antigravity plugin not configured (optional)"
fi

# ------------------------------------------------------------------ skills --
section "Skills"
PROFILE="${PROFILE:-full}"
manifests="$(read_manifest "$REPO_DIR/skills/profiles.conf" | awk -F'|' -v p="$PROFILE" '$1==p {print $2; exit}' | tr ',' ' ')"
# A bare manifest name works as a profile too, matching install-skills.sh.
if [ -z "$manifests" ] && [ -f "$REPO_DIR/skills/$PROFILE.conf" ]; then manifests="$PROFILE"; fi
[ -n "$manifests" ] || manifests="frontend backend database devops testing security"

skill_missing=0
for m in $manifests; do
  f="$REPO_DIR/skills/$m.conf"
  [ -f "$f" ] || continue
  while IFS='|' read -r repo skill; do
    skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
    [ -n "$skill" ] || continue
    if [ -f "$SKILLS_HOME/$skill/SKILL.md" ]; then
      ok "$skill"
    else
      fail "$skill"
      skill_missing=$((skill_missing + 1))
    fi
  done < <(read_manifest "$f")
done
if [ "$skill_missing" -gt 0 ]; then
  PROBLEMS=$((PROBLEMS + 1))
  printf '%s\n' "  ${C_DIM}Fix: ./scripts/install-skills.sh${C_RESET}"
fi

# --------------------------------------------------------------------- mcp --
section "MCP"
if has node && [ -f "$CFG" ]; then
  while IFS='|' read -r name present enabled envmissing envoptional; do
    [ -n "$name" ] || continue
    if [ "$present" = "yes" ]; then
      if [ -n "$envmissing" ]; then
        soft "$name disabled — \$$envmissing not set" "add $envmissing to $REPO_DIR/.env, then run: opencode-sync"
      elif [ "$enabled" = "no" ]; then
        soft "$name is disabled in the config" "set \"enabled\": true, or run: ./scripts/install-mcps.sh"
      elif [ -n "$envoptional" ]; then
        ok "$name  ${C_DIM}(no \$$envoptional — anonymous/rate-limited)${C_RESET}"
      else
        ok "$name"
      fi
    else
      fail "$name missing"
      PROBLEMS=$((PROBLEMS + 1))
      printf '%s\n' "  ${C_DIM}Fix: ./scripts/install-mcps.sh${C_RESET}"
    fi
  done < <(node -e '
    const fs = require("fs");
    const man = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let cfg = {};
    try {
      const raw = fs.readFileSync(process.argv[2], "utf8")
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .replace(/^\s*\/\/.*$/gm, "")
        .replace(/,(\s*[}\]])/g, "$1");
      cfg = JSON.parse(raw);
    } catch {}
    for (const [name, entry] of Object.entries(man.servers || {})) {
      const live = cfg.mcp && cfg.mcp[name];
      const present = live ? "yes" : "no";
      const enabled = live && live.enabled === false ? "no" : "yes";
      const miss = (entry.requiresEnv || []).filter((v) => !process.env[v]);
      const opt = (entry.optionalEnv || []).filter((v) => !process.env[v]);
      console.log([name, present, enabled, miss.join(" "), opt.join(" ")].join("|"));
    }
  ' "$REPO_DIR/mcp/mcps.json" "$CFG")
else
  problem "Cannot inspect MCP config" "./bootstrap.sh"
fi

# The {env:VAR} placeholders in the config are resolved from OpenCode's own
# process environment, so the generated env file must actually be sourced by
# the login shell for the keys to reach it.
if [ -f "$MANAGED_DIR/env.sh" ]; then
  rc_ok=0
  for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$RC" ] && grep -qF "# >>> opencode-bootstrap >>>" "$RC" && rc_ok=1
  done
  if [ "$rc_ok" = "1" ]; then ok "Credentials bridged to shell environment"
  else soft "env.sh not sourced by any shell config" "./scripts/install-aliases.sh"; fi
fi

# ------------------------------------------------------------------ status --
section "Status"
if [ "$PROBLEMS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  ok "Environment ready"
elif [ "$PROBLEMS" -eq 0 ]; then
  ok "Environment ready  ${C_DIM}($WARNINGS warning(s))${C_RESET}"
else
  fail "$PROBLEMS problem(s), $WARNINGS warning(s)"
fi
printf '\n'

[ "$PROBLEMS" -eq 0 ]

#!/usr/bin/env bash
# OpenCode adapter.
#
# Rules   : symlinked into ~/.config/opencode/ai-dev-bootstrap/ and registered
#           in the config's `instructions` array (OpenCode merges those with
#           whatever AGENTS.md the user already has).
# MCP     : merged into the `mcp` block by scripts/lib/merge-config.mjs, which
#           rewrites only the keys this repo owns.
# Secrets : never written to the config. OpenCode resolves {env:VAR} from its
#           own process environment at runtime; the credential bridge in
#           install-mcps.sh is what puts the value there.
#
# Subcommands: label detect paths plan apply mcp-apply verify remove

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

AGENT="opencode"
MANAGED="$OPENCODE_CONFIG_DIR/$MANAGED_NAME"
RULES_LINK="$MANAGED/global.md"
RULES_SRC="$REPO_DIR/rules/global.md"
STATE_JSON="$MANAGED/state.json"
CFG="$(opencode_config_file)"

cmd="${1:-}"; shift || true

case "$cmd" in

label) printf 'OpenCode\n' ;;

# Present if the CLI is installed or the config directory already exists —
# either is enough to make managing it worthwhile.
detect)
  command_exists opencode && exit 0
  [ -d "$OPENCODE_CONFIG_DIR" ] && exit 0
  exit 1 ;;

paths)
  printf 'AGENT=%s\n' "$AGENT"
  printf 'CONFIG_DIR=%s\n' "$OPENCODE_CONFIG_DIR"
  printf 'CONFIG_FILE=%s\n' "$CFG"
  printf 'MANAGED_DIR=%s\n' "$MANAGED"
  printf 'SKILLS_AGENT=%s\n' "opencode"
  printf 'SUPPORTS_MCP=%s\n' "yes" ;;

# Declarative desired state. check.sh repairs LINK rows; verify.sh reports on
# every row. Nothing here mutates anything.
plan)
  printf 'LINK|%s|%s|global rules\n' "$RULES_SRC" "$RULES_LINK"
  config_fragment_links "$AGENT" "$MANAGED"
  printf 'CFG|%s|instructions entry\n' "$CFG" ;;

apply)
  command_exists node || die "$EX_DEPS" "node is required to edit the OpenCode config safely"
  ensure_directory "$MANAGED"
  is_dry_run || backup_config_dir

  case "$(ensure_symlink "$RULES_SRC" "$RULES_LINK")" in
    current)       ok "Global rules" ;;
    created)       ok "Global rules linked  ${C_DIM}$(tilde "$RULES_LINK")${C_RESET}" ;;
    repaired)      ok "Global rules link repaired" ;;
    would-create)  plan_action LINK "$(tilde "$RULES_LINK")" ;;
    would-repair)  plan_action RELINK "$(tilde "$RULES_LINK")" ;;
    conflict)      warn "$(tilde "$RULES_LINK") exists and is not a symlink — left alone" ;;
  esac

  config_fragment_links "$AGENT" "$MANAGED" | while IFS='|' read -r _ src dest label; do
    case "$(ensure_symlink "$src" "$dest")" in
      current|created|repaired) ok "$label" ;;
      would-*)                  plan_action LINK "$(tilde "$dest")" ;;
      conflict)                 warn "$label: $(tilde "$dest") is a real file — left alone" ;;
    esac
  done

  if is_dry_run; then
    plan_action REGISTER "instructions → $(tilde "$RULES_LINK")"
    exit 0
  fi

  # --servers "" means "manage instructions only on this run".
  err="$(mktemp)"
  if ! node "$REPO_DIR/scripts/lib/merge-config.mjs" apply \
        --config "$CFG" --mcp "$REPO_DIR/mcp/mcps.json" --state "$STATE_JSON" \
        --instructions "$RULES_LINK" --servers "" 2>"$err"; then
    cat "$err" >&2; rm -f "$err"; die "$EX_CONFIG" "Failed to update $CFG"
  fi
  grep -q '^comments-dropped:' "$err" && warn "Comments in $(basename "$CFG") were removed by the rewrite (a backup was taken)"
  rm -f "$err"
  ok "Registered in instructions  ${C_DIM}$(tilde "$CFG")${C_RESET}" ;;

mcp-apply)
  command_exists node || die "$EX_DEPS" "node is required to edit the OpenCode config safely"
  MANIFEST="$REPO_DIR/mcp/mcps.json"
  SERVERS="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST" | tr '\n' ',' | sed 's/,$//')"

  if is_dry_run; then
    printf '%s\n' "$SERVERS" | tr ',' '\n' | while IFS= read -r s; do
      [ -n "$s" ] && plan_action CONFIGURE "opencode mcp: $s"
    done
    exit 0
  fi

  ensure_directory "$MANAGED"
  backup_config_dir
  err="$(mktemp)"
  if ! node "$REPO_DIR/scripts/lib/merge-config.mjs" apply \
        --config "$CFG" --mcp "$MANIFEST" --state "$STATE_JSON" --servers "$SERVERS" 2>"$err"; then
    cat "$err" >&2; rm -f "$err"; die "$EX_CONFIG" "Failed to update $CFG"
  fi
  # Two passes so the per-server results read as a list with advisories under it.
  while IFS= read -r line; do
    case "$line" in
      applied:*) printf '%s\n' "${line#applied:}" | tr ',' '\n' | while IFS= read -r s; do
                   [ -n "$s" ] && ok "$s"
                 done ;;
    esac
  done < "$err"
  while IFS= read -r line; do
    case "$line" in
      user-owned:*)    warn "${line#user-owned:} already configured by you — left unchanged" ;;
      removed-stale:*) info "removed ${line#removed-stale:} (no longer in the manifest)" ;;
      missing-env:*)
        IFS=':' read -r mserver mvar mkind <<EOF_MISSING
${line#missing-env:}
EOF_MISSING
        if [ "${mkind:-}" = "required" ]; then
          warn "$mserver: \$$mvar is not set — written disabled so it cannot fail on startup"
        else
          warn "$mserver: \$$mvar is not set — enabled, but anonymous/rate-limited"
        fi
        hint "Add $mvar to $REPO_DIR/.env, then run: ai-dev-sync" ;;
      comments-dropped:*) warn "Comments in $(basename "$CFG") were removed by the rewrite (a backup was taken)" ;;
      unknown-server:*)   fail "Unknown server in manifest: ${line#unknown-server:}" ;;
    esac
  done < "$err"
  rm -f "$err" ;;

# Read-only. OK|DRIFT|MISS|WARN|SKIP per line; exit 5 if anything drifted.
verify)
  drift=0
  case "$(link_state "$RULES_SRC" "$RULES_LINK")" in
    ok)       printf 'OK|global rules\n' ;;
    missing)  printf 'MISS|global rules|not linked\n'; drift=1 ;;
    broken)   printf 'DRIFT|global rules|symlink is broken\n'; drift=1 ;;
    wrong)    printf 'DRIFT|global rules|points elsewhere\n'; drift=1 ;;
    conflict) printf 'WARN|global rules|a real file occupies the link path\n' ;;
  esac

  config_fragment_links "$AGENT" "$MANAGED" | while IFS='|' read -r _ src dest label; do
    case "$(link_state "$src" "$dest")" in
      ok) printf 'OK|%s\n' "$label" ;;
      *)  printf 'MISS|%s|not linked\n' "$label" ;;
    esac
  done

  if [ ! -f "$CFG" ]; then
    printf 'MISS|config file|%s\n' "$(tilde "$CFG")"; drift=1
  elif ! validate_jsonc "$CFG"; then
    printf 'DRIFT|config file|does not parse\n'; drift=1
  else
    printf 'OK|config parses\n'
    if command_exists node && node -e '
        const fs=require("fs");
        const raw=fs.readFileSync(process.argv[1],"utf8")
          .replace(/\/\*[\s\S]*?\*\//g,"").replace(/^\s*\/\/.*$/gm,"").replace(/,(\s*[}\]])/g,"$1");
        const cfg=JSON.parse(raw);
        process.exit((cfg.instructions||[]).includes(process.argv[2])?0:1);
      ' "$CFG" "$RULES_LINK" 2>/dev/null; then
      printf 'OK|instructions entry\n'
    else
      printf 'DRIFT|instructions entry|rules not registered in the config\n'; drift=1
    fi
    # Report MCP servers that the manifest declares but the config lacks.
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if command_exists node && node -e '
          const fs=require("fs");
          const raw=fs.readFileSync(process.argv[1],"utf8")
            .replace(/\/\*[\s\S]*?\*\//g,"").replace(/^\s*\/\/.*$/gm,"").replace(/,(\s*[}\]])/g,"$1");
          const cfg=JSON.parse(raw);
          process.exit(cfg.mcp && cfg.mcp[process.argv[2]] ? 0 : 1);
        ' "$CFG" "$name" 2>/dev/null; then
        printf 'OK|mcp: %s\n' "$name"
      else
        printf 'MISS|mcp: %s|not in the config\n' "$name"; drift=1
      fi
    done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$REPO_DIR/mcp/mcps.json")
  fi
  [ "$drift" -eq 0 ] || exit "$EX_DRIFT" ;;

remove)
  if command_exists node && [ -f "$STATE_JSON" ] && [ -f "$CFG" ]; then
    backup_config_dir
    err="$(mktemp)"
    node "$REPO_DIR/scripts/lib/merge-config.mjs" remove --config "$CFG" --state "$STATE_JSON" 2>"$err" || true
    while IFS= read -r line; do
      case "$line" in removed:*) ok "MCP removed: ${line#removed:}" ;; esac
    done < "$err"
    rm -f "$err"
    ok "Managed config entries removed"
  else
    info "No managed OpenCode state found"
  fi
  if [ -d "$MANAGED" ]; then rm -rf "$MANAGED"; ok "Removed $(tilde "$MANAGED")"; fi ;;

*) die "$EX_FAIL" "opencode adapter: unknown subcommand '${cmd:-}'" ;;
esac

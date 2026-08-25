#!/usr/bin/env bash
# Claude Code adapter.
#
# Rules   : symlinked into ~/.claude/rules/ as ai-dev-global.md. Claude Code
#           loads every *.md in that directory as global instructions, so no
#           file of the user's has to be edited at all — the link IS the
#           integration point, and a namespaced filename cannot collide.
# MCP     : added through `claude mcp add-json -s user`. The CLI owns
#           ~/.claude.json; this adapter never writes that file itself, which
#           is what keeps a machine's project history and OAuth state safe.
# Secrets : Claude Code has no runtime placeholder for user-scope servers, so a
#           required key is resolved at install time and lands in the local
#           config. The caller warns about it; a server whose key is missing is
#           skipped rather than added broken.
#
# Subcommands: label detect paths plan apply mcp-apply verify remove

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

AGENT="claude-code"
MANAGED="$CLAUDE_HOME/$MANAGED_NAME"
RULES_DIR="$CLAUDE_HOME/rules"
RULES_LINK="$RULES_DIR/ai-dev-global.md"
RULES_SRC="$REPO_DIR/rules/global.md"
OWNED="$MANAGED/mcp-owned.txt"
MANIFEST="$REPO_DIR/mcp/mcps.json"

# `claude mcp get` exits 0 whether or not the server exists, so presence is
# read off the first line of its output instead of the exit code.
claude_has_server() {
  [ "$(claude mcp get "$1" 2>/dev/null | head -1)" = "$1:" ]
}
we_own() { [ -f "$OWNED" ] && grep -qxF "$1" "$OWNED"; }

cmd="${1:-}"; shift || true

case "$cmd" in

label) printf 'Claude Code\n' ;;

detect)
  command_exists claude && exit 0
  [ -d "$CLAUDE_HOME" ] && exit 0
  exit 1 ;;

paths)
  printf 'AGENT=%s\n' "$AGENT"
  printf 'CONFIG_DIR=%s\n' "$CLAUDE_HOME"
  printf 'CONFIG_FILE=%s\n' "$HOME/.claude.json"
  printf 'MANAGED_DIR=%s\n' "$MANAGED"
  printf 'SKILLS_AGENT=%s\n' "claude"
  printf 'SUPPORTS_MCP=%s\n' "$(command_exists claude && echo yes || echo no)" ;;

plan)
  printf 'LINK|%s|%s|global rules\n' "$RULES_SRC" "$RULES_LINK"
  config_fragment_links "$AGENT" "$MANAGED" ;;

apply)
  ensure_directory "$RULES_DIR"
  ensure_directory "$MANAGED"
  case "$(ensure_symlink "$RULES_SRC" "$RULES_LINK")" in
    current)      ok "Global rules" ;;
    created)      ok "Global rules linked  ${C_DIM}$(tilde "$RULES_LINK")${C_RESET}" ;;
    repaired)     ok "Global rules link repaired" ;;
    would-create) plan_action LINK "$(tilde "$RULES_LINK")" ;;
    would-repair) plan_action RELINK "$(tilde "$RULES_LINK")" ;;
    conflict)     warn "$(tilde "$RULES_LINK") exists and is not a symlink — left alone" ;;
  esac
  config_fragment_links "$AGENT" "$MANAGED" | while IFS='|' read -r _ src dest label; do
    case "$(ensure_symlink "$src" "$dest")" in
      current|created|repaired) ok "$label" ;;
      would-*)                  plan_action LINK "$(tilde "$dest")" ;;
      conflict)                 warn "$label: $(tilde "$dest") is a real file — left alone" ;;
    esac
  done ;;

mcp-apply)
  if ! command_exists claude; then
    info "claude CLI not found — MCP servers skipped"
    exit 0
  fi
  command_exists node || die "$EX_DEPS" "node is required to render MCP definitions"

  warned_secret=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    status="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server "$name")"
    case "$status" in
      missing:*)
        warn "$name skipped — \$${status#missing:} is not set"
        hint "Add ${status#missing:} to $REPO_DIR/.env, then run: ai-dev-sync"
        continue ;;
    esac

    # The CLI is not consulted during a dry run: `claude mcp get` initialises
    # ~/.claude.json when it is absent, and a dry run that creates a file is
    # not a dry run.
    if is_dry_run; then plan_action CONFIGURE "claude mcp: $name"; continue; fi

    if claude_has_server "$name" && ! we_own "$name"; then
      warn "$name already configured by you — left unchanged"
      continue
    fi

    json="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target claude --server "$name")"
    # A credential resolved into the JSON must not reach the terminal or a log.
    case "$json" in
      *Bearer*|*token*|*key*|*KEY*)
        if [ "$warned_secret" = "0" ]; then
          warn "Claude Code has no runtime placeholder — resolved keys are written to ~/.claude.json"
          warned_secret=1
        fi ;;
    esac

    # Replace rather than duplicate when the server is one we added before.
    claude mcp remove "$name" -s user >/dev/null 2>&1 || true
    if claude mcp add-json "$name" "$json" -s user >/dev/null 2>&1; then
      ensure_directory "$MANAGED"
      grep -qxF "$name" "$OWNED" 2>/dev/null || printf '%s\n' "$name" >> "$OWNED"
      case "$status" in
        optional:*) ok "$name  ${C_DIM}(no \$${status#optional:} — anonymous/rate-limited)${C_RESET}" ;;
        *)          ok "$name" ;;
      esac
    else
      fail "$name could not be added"
      hint "Try by hand: claude mcp add-json $name '<json>' -s user"
    fi
  done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST") ;;

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

  if [ -f "$HOME/.claude.json" ]; then
    if validate_json "$HOME/.claude.json"; then printf 'OK|config parses\n'
    else printf 'DRIFT|config file|~/.claude.json does not parse\n'; drift=1; fi
  fi

  if ! command_exists claude; then
    printf 'SKIP|mcp|claude CLI not installed\n'
  elif [ ! -f "$HOME/.claude.json" ]; then
    # Querying the CLI would create the file. verify never creates anything.
    printf 'MISS|mcp|no Claude Code config yet\n'
    drift=1
  elif command_exists node; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      status="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server "$name")"
      if claude_has_server "$name"; then
        printf 'OK|mcp: %s\n' "$name"
      elif [ "${status#missing:}" != "$status" ]; then
        printf 'SKIP|mcp: %s|$%s not set\n' "$name" "${status#missing:}"
      else
        printf 'MISS|mcp: %s|not configured\n' "$name"; drift=1
      fi
    done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST")
  fi
  [ "$drift" -eq 0 ] || exit "$EX_DRIFT" ;;

remove)
  if [ -L "$RULES_LINK" ]; then rm -f "$RULES_LINK"; ok "Removed $(tilde "$RULES_LINK")"; fi
  if command_exists claude && [ -f "$OWNED" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      claude mcp remove "$name" -s user >/dev/null 2>&1 && ok "MCP removed: $name" || true
    done < "$OWNED"
  fi
  if [ -d "$MANAGED" ]; then rm -rf "$MANAGED"; ok "Removed $(tilde "$MANAGED")"; fi ;;

*) die "$EX_FAIL" "claude-code adapter: unknown subcommand '${cmd:-}'" ;;
esac

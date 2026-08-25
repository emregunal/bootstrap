#!/usr/bin/env bash
# Codex adapter.
#
# Rules   : Codex reads ~/.codex/AGENTS.md and has no include directive, so the
#           rules are rendered into a marked block inside that file. Every line
#           outside the markers is preserved byte-for-byte, and because the
#           block is generated, check.sh can re-render it when it drifts — a
#           repair that can only ever touch text this repository wrote.
# MCP     : a marked block of [mcp_servers.*] tables in ~/.codex/config.toml.
#           A server already defined outside the block belongs to the user and
#           is left alone. The file is backed up first and re-parsed after; a
#           write that does not parse as TOML is rolled back immediately.
# Secrets : Codex stores header values literally. A server whose required key
#           is missing is skipped rather than written broken, and config.toml
#           is left at mode 600.
#
# Subcommands: label detect paths plan apply mcp-apply verify remove

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

AGENT="codex"
MANAGED="$CODEX_HOME/$MANAGED_NAME"
AGENTS_MD="$CODEX_HOME/AGENTS.md"
CONFIG_TOML="$CODEX_HOME/config.toml"
RULES_SRC="$REPO_DIR/rules/global.md"
MANIFEST="$REPO_DIR/mcp/mcps.json"

# Markdown needs comment markers that do not render as a heading.
MD_BEGIN="<!-- >>> ai-dev-bootstrap >>> -->"
MD_END="<!-- <<< ai-dev-bootstrap <<< -->"

rules_body() {
  printf '%s\n\n' "<!-- Generated from rules/global.md by ai-dev-bootstrap. Edit the repo file, not this block. -->"
  cat "$RULES_SRC"
}

# Servers the user defined themselves, i.e. [mcp_servers.x] tables that appear
# outside this repository's marked block.
user_defined_servers() {
  local tmp
  [ -f "$CONFIG_TOML" ] || return 0
  tmp="$(mktemp)"
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b { skip = 1 } skip != 1 { print } $0 == e { skip = 0 }' "$CONFIG_TOML" > "$tmp"
  sed -n 's/^[[:space:]]*\[mcp_servers\.\([A-Za-z0-9_-]*\)\].*$/\1/p' "$tmp" | sort -u
  rm -f "$tmp"
}

# Manifest servers that are installable here: key present, not user-defined.
wanted_servers() {
  local name status
  command_exists node || return 0
  local userdef; userdef="$(user_defined_servers | tr '\n' ' ')"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case " $userdef " in *" $name "*) continue ;; esac
    status="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server "$name")"
    case "$status" in missing:*) continue ;; esac
    printf '%s\n' "$name"
  done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST")
}

cmd="${1:-}"; shift || true

case "$cmd" in

label) printf 'Codex\n' ;;

detect)
  command_exists codex && exit 0
  [ -d "$CODEX_HOME" ] && exit 0
  exit 1 ;;

paths)
  printf 'AGENT=%s\n' "$AGENT"
  printf 'CONFIG_DIR=%s\n' "$CODEX_HOME"
  printf 'CONFIG_FILE=%s\n' "$CONFIG_TOML"
  printf 'MANAGED_DIR=%s\n' "$MANAGED"
  printf 'SKILLS_AGENT=%s\n' "codex"
  printf 'SUPPORTS_MCP=%s\n' "yes" ;;

plan)
  printf 'BLOCK|%s|global rules\n' "$AGENTS_MD"
  config_fragment_links "$AGENT" "$MANAGED"
  printf 'BLOCK|%s|mcp servers\n' "$CONFIG_TOML" ;;

apply)
  ensure_directory "$CODEX_HOME"
  ensure_directory "$MANAGED"
  state="$(rules_body | ( BLOCK_BEGIN="$MD_BEGIN"; BLOCK_END="$MD_END"; ensure_block "$AGENTS_MD" ))"
  case "$state" in
    current)      ok "Global rules" ;;
    created)      ok "Global rules written  ${C_DIM}$(tilde "$AGENTS_MD")${C_RESET}" ;;
    updated)      ok "Global rules refreshed" ;;
    would-create) plan_action CREATE "rules block in $(tilde "$AGENTS_MD")" ;;
    would-update) plan_action UPDATE "rules block in $(tilde "$AGENTS_MD")" ;;
  esac
  config_fragment_links "$AGENT" "$MANAGED" | while IFS='|' read -r _ src dest label; do
    case "$(ensure_symlink "$src" "$dest")" in
      current|created|repaired) ok "$label" ;;
      would-*)                  plan_action LINK "$(tilde "$dest")" ;;
      conflict)                 warn "$label: $(tilde "$dest") is a real file — left alone" ;;
    esac
  done ;;

mcp-apply)
  command_exists node || die "$EX_DEPS" "node is required to render MCP definitions"
  if [ ! -d "$CODEX_HOME" ]; then
    info "Codex home not found — MCP servers skipped"
    exit 0
  fi

  servers="$(wanted_servers | tr '\n' ',' | sed 's/,$//')"
  user_defined_servers | while IFS= read -r s; do
    [ -n "$s" ] && warn "$s already configured by you — left unchanged"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    status="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server "$name")"
    case "$status" in
      missing:*) warn "$name skipped — \$${status#missing:} is not set"
                 hint "Add ${status#missing:} to $REPO_DIR/.env, then run: ai-dev-sync" ;;
    esac
  done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST")

  if [ -z "$servers" ]; then
    info "No Codex MCP servers to configure"
    exit 0
  fi

  if is_dry_run; then
    printf '%s\n' "$servers" | tr ',' '\n' | while IFS= read -r s; do
      [ -n "$s" ] && plan_action CONFIGURE "codex mcp: $s"
    done
    exit 0
  fi

  backup=""
  [ -f "$CONFIG_TOML" ] && backup="$(safe_backup "$CONFIG_TOML")"
  body="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target codex --servers "$servers")"
  state="$(printf '%s' "$body" | ensure_block "$CONFIG_TOML")"

  # A config.toml Codex cannot parse would break every session, so the write is
  # verified and undone on failure rather than left for the user to discover.
  if ! validate_toml "$CONFIG_TOML"; then
    rc=$?
    if [ "$rc" = "2" ]; then
      warn "No TOML parser available — could not verify $(tilde "$CONFIG_TOML")"
    else
      if [ -n "$backup" ] && [ -f "$backup" ]; then
        cat "$backup" > "$CONFIG_TOML"
        fail "Write produced invalid TOML — rolled back from $(tilde "$backup")"
      else
        fail "Write produced invalid TOML in $(tilde "$CONFIG_TOML")"
      fi
      exit "$EX_CONFIG"
    fi
  fi
  chmod 600 "$CONFIG_TOML" 2>/dev/null || true
  prune_backups "${CONFIG_TOML}.ai-dev-backup-*" 5

  case "$state" in
    current) info "Codex MCP block already current" ;;
    *)       printf '%s\n' "$servers" | tr ',' '\n' | while IFS= read -r s; do
               [ -n "$s" ] && ok "$s"
             done ;;
  esac
  warn "Codex stores keys literally — $(tilde "$CONFIG_TOML") holds credentials (mode 600)" ;;

verify)
  drift=0
  want="$(rules_body)"
  state="$(printf '%s' "$want" | ( BLOCK_BEGIN="$MD_BEGIN"; BLOCK_END="$MD_END"; block_state "$AGENTS_MD" ))"
  case "$state" in
    present) printf 'OK|global rules\n' ;;
    absent)  printf 'MISS|global rules|not present in AGENTS.md\n'; drift=1 ;;
    stale)   printf 'DRIFT|global rules|AGENTS.md block differs from rules/global.md\n'; drift=1 ;;
  esac
  config_fragment_links "$AGENT" "$MANAGED" | while IFS='|' read -r _ src dest label; do
    case "$(link_state "$src" "$dest")" in
      ok) printf 'OK|%s\n' "$label" ;;
      *)  printf 'MISS|%s|not linked\n' "$label" ;;
    esac
  done

  if [ -f "$CONFIG_TOML" ]; then
    if validate_toml "$CONFIG_TOML"; then printf 'OK|config parses\n'
    elif [ $? = 2 ]; then printf 'SKIP|config parse|no TOML parser available\n'
    else printf 'DRIFT|config file|config.toml does not parse\n'; drift=1; fi
    mode="$(file_mode "$CONFIG_TOML" 2>/dev/null || echo '')"
    case "$mode" in ''|600|400) ;; *) printf 'WARN|permissions|config.toml is %s, expected 600\n' "$mode" ;; esac
  else
    printf 'SKIP|config file|no config.toml yet\n'
  fi

  if command_exists node; then
    userdef="$(user_defined_servers | tr '\n' ' ')"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case " $userdef " in *" $name "*) printf 'OK|mcp: %s (yours)\n' "$name"; continue ;; esac
      status="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server "$name")"
      if [ -f "$CONFIG_TOML" ] && grep -q "^\[mcp_servers\.$name\]" "$CONFIG_TOML"; then
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
  if [ -f "$AGENTS_MD" ]; then
    ( BLOCK_BEGIN="$MD_BEGIN"; BLOCK_END="$MD_END"; remove_block "$AGENTS_MD" )
    ok "Rules block removed from $(tilde "$AGENTS_MD")"
  fi
  if [ -f "$CONFIG_TOML" ]; then
    safe_backup "$CONFIG_TOML" >/dev/null
    remove_block "$CONFIG_TOML"
    ok "MCP block removed from $(tilde "$CONFIG_TOML")"
  fi
  if [ -d "$MANAGED" ]; then rm -rf "$MANAGED"; ok "Removed $(tilde "$MANAGED")"; fi ;;

*) die "$EX_FAIL" "codex adapter: unknown subcommand '${cmd:-}'" ;;
esac

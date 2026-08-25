#!/usr/bin/env bash
# uninstall.sh — remove what this repository installed. Nothing else.
#
# Removed:  the ~/.local/bin wrappers, the managed rules directory, the MCP
#           entries and instructions path this repo added to the OpenCode
#           config, and (with --skills) the skills listed in the manifests.
# Kept:     OpenCode itself, your credentials, your provider/model/agent
#           settings, any MCP server you configured yourself, and any config
#           key this repository never wrote.
#
#   ./uninstall.sh              # config, aliases and rules
#   ./uninstall.sh --skills     # also remove the manifest skills
#   ./uninstall.sh --yes        # no confirmation prompt

set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/scripts/helpers.sh"

REMOVE_SKILLS=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skills) REMOVE_SKILLS=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) printf 'Usage: ./uninstall.sh [--skills] [--yes]\n'; exit 0 ;;
    *) fail "Unknown option: $1"; exit 1 ;;
  esac
done

banner "OpenCode Bootstrap Uninstall"
info "OpenCode, your credentials and your own settings are left untouched."
[ "$REMOVE_SKILLS" = "1" ] && info "Skills listed in skills/*.conf will also be removed."

if [ "$ASSUME_YES" != "1" ]; then
  printf '\n%s' "Continue? [y/N] "
  read -r reply
  case "$reply" in [yY]*) ;; *) info "Aborted."; exit 0 ;; esac
fi

CFG="$(config_file)"
STATE="$MANAGED_DIR/state.json"

section "Config"
if has node && [ -f "$STATE" ] && [ -f "$CFG" ]; then
  backup_config_dir
  err="$(mktemp)"
  node "$REPO_DIR/scripts/lib/merge-config.mjs" remove --config "$CFG" --state "$STATE" 2>"$err" || true
  while IFS= read -r line; do
    case "$line" in removed:*) ok "MCP removed: ${line#removed:}" ;; esac
  done < "$err"
  rm -f "$err"
  ok "Managed config entries removed"
else
  info "No managed config state found — nothing to revert"
fi

section "Rules"
if [ -d "$MANAGED_DIR" ]; then
  rm -rf "$MANAGED_DIR"
  ok "Removed $MANAGED_DIR"
else
  info "Nothing installed at $MANAGED_DIR"
fi

section "Commands"
for name in opencode-sync opencode-doctor; do
  p="$BIN_DIR/$name"
  # Only remove a wrapper this repository generated.
  if [ -f "$p" ] && grep -q '# opencode-bootstrap' "$p" 2>/dev/null; then
    rm -f "$p"; ok "Removed $p"
  elif [ -e "$p" ]; then
    warn "$p exists but was not created by bootstrap — left in place"
  else
    info "$name not installed"
  fi
done

# Remove the managed rc block, leaving every other line in the file alone.
BEGIN="# >>> opencode-bootstrap >>>"
END="# <<< opencode-bootstrap <<<"
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$RC" ] || continue
  grep -qF "$BEGIN" "$RC" || continue
  tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 }
    skip != 1 { print }
    $0 == e { skip = 0 }
  ' "$RC" > "$tmp"
  cat "$tmp" > "$RC"
  rm -f "$tmp"
  ok "Removed managed block from $RC"
done

section "Skills"
if [ "$REMOVE_SKILLS" = "1" ]; then
  if has npx; then
    for f in "$REPO_DIR"/skills/*.conf; do
      case "$f" in *profiles.conf) continue ;; esac
      [ -f "$f" ] || continue
      while IFS='|' read -r repo skill; do
        skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
        [ -n "$skill" ] || continue
        if npx -y skills@latest remove -g -s "$skill" -y >/dev/null 2>&1; then ok "$skill"
        else warn "$skill could not be removed"; fi
      done < <(read_manifest "$f")
    done
  else
    warn "npx not found — skills left installed"
  fi
else
  info "Skills kept (pass --skills to remove them)"
fi

printf '\n'
ok "Uninstall complete"
hint "Config backups, if any, are at ${OPENCODE_CONFIG_DIR}.backup-*"

exit 0

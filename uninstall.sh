#!/usr/bin/env bash
# uninstall.sh — remove what this repository installed. Nothing else.
#
# Removed:  the ~/.local/bin wrappers, the managed directory inside each
#           agent's config, the MCP entries and rules registrations this repo
#           added, the shell rc block, the credential bridge, and (with
#           --skills) the skills named in the manifests.
# Kept:     every agent itself, your credentials, your provider/model/agent
#           settings, any MCP server you configured yourself, and every config
#           key this repository never wrote.
#
#   ./uninstall.sh            config, commands and rules
#   ./uninstall.sh --skills   also remove the manifest skills
#   ./uninstall.sh --yes      no confirmation prompt
#   ./uninstall.sh --dry-run  show what would be removed

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/common.sh"

REMOVE_SKILLS=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skills)  REMOVE_SKILLS=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) printf 'Usage: ./uninstall.sh [--skills] [--yes] [--dry-run]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done
export DRY_RUN VERBOSE

banner "AI Dev Uninstall"
info "Your agents, credentials and personal settings are left untouched."
[ "$REMOVE_SKILLS" = "1" ] && info "Skills listed in skills/*.conf will also be removed."
is_dry_run && warn "Dry run — nothing will be removed"

if [ "$ASSUME_YES" != "1" ] && ! is_dry_run; then
  printf '\n%s' "Continue? [y/N] "
  read -r reply
  case "$reply" in [yY]*) ;; *) info "Aborted."; exit "$EX_OK" ;; esac
fi

# --------------------------------------------------------------- adapters ----
for agent in $(adapter_list); do
  label="$(adapter_run "$agent" label)"
  adapter_run "$agent" detect >/dev/null 2>&1 || continue
  section "$label"
  if is_dry_run; then
    adapter_run "$agent" plan | while IFS='|' read -r kind a b _; do
      case "$kind" in
        LINK)  plan_action REMOVE "$(tilde "$b")" ;;
        BLOCK) plan_action REMOVE "managed block in $(tilde "$a")" ;;
      esac
    done
  else
    adapter_run "$agent" remove
  fi
done

# --------------------------------------------------------------- commands ----
section "Commands"
while IFS='|' read -r name _; do
  [ -n "$name" ] || continue
  p="$BIN_DIR/$name"
  if [ -f "$p" ] && grep -q "$WRAPPER_MARKER" "$p" 2>/dev/null; then
    if is_dry_run; then plan_action REMOVE "$(tilde "$p")"
    else rm -f "$p"; ok "Removed $(tilde "$p")"; fi
  elif [ -e "$p" ]; then
    warn "$(tilde "$p") was not created by this repository — left in place"
  else
    info "$name not installed"
  fi
done < <(ai_dev_commands)

# Commands from the previous generation of this repository, if still around.
for name in $LEGACY_COMMANDS; do
  p="$BIN_DIR/$name"
  # Only ever remove a wrapper this project generated: the marker is the proof.
  [ -f "$p" ] || continue
  grep -q "# opencode-bootstrap" "$p" 2>/dev/null || continue
  if is_dry_run; then plan_action REMOVE "$(tilde "$p")"
  else rm -f "$p"; ok "Removed $(tilde "$p")"; fi
done

# ------------------------------------------------------------ shell config ---
section "Shell config"
while IFS= read -r RC; do
  [ -f "$RC" ] || continue
  for pair in "$BLOCK_BEGIN|$BLOCK_END" "$LEGACY_BLOCK_BEGIN|$LEGACY_BLOCK_END"; do
    b="${pair%%|*}"; e="${pair##*|}"
    grep -qF "$b" "$RC" 2>/dev/null || continue
    if is_dry_run; then plan_action REMOVE "managed block in $(tilde "$RC")"
    else remove_block "$RC" "$b" "$e"; ok "Removed managed block from $(tilde "$RC")"; fi
  done
done < <(candidate_rc_files)

# ------------------------------------------------------------ local state ----
section "Local state"
if [ -d "$LOCAL_STATE_DIR" ]; then
  if is_dry_run; then plan_action REMOVE "$(tilde "$LOCAL_STATE_DIR")  (includes the credential bridge)"
  else rm -rf "$LOCAL_STATE_DIR"; ok "Removed $(tilde "$LOCAL_STATE_DIR")"; fi
else
  info "Nothing at $(tilde "$LOCAL_STATE_DIR")"
fi

# -------------------------------------------------------------- git hooks ----
section "Git hooks"
if command_exists git && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ "$(git -C "$REPO_DIR" config --local --get core.hooksPath 2>/dev/null || true)" = ".githooks" ]; then
    if is_dry_run; then plan_action UNSET "git core.hooksPath"
    else git -C "$REPO_DIR" config --unset core.hooksPath || true; ok "core.hooksPath unset"; fi
  else
    info "core.hooksPath was not set by this repository"
  fi
else
  info "Not a git clone"
fi

# ----------------------------------------------------------------- skills ----
section "Skills"
if [ "$REMOVE_SKILLS" != "1" ]; then
  info "Skills kept (pass --skills to remove them)"
elif ! command_exists npx; then
  warn "npx not found — skills left installed"
else
  for f in "$REPO_DIR"/skills/*.conf; do
    case "$f" in *profiles.conf) continue ;; esac
    [ -f "$f" ] || continue
    while IFS='|' read -r _ skill; do
      skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
      [ -n "$skill" ] || continue
      if is_dry_run; then plan_action REMOVE "skill: $skill"; continue; fi
      if npx -y skills@latest remove -g -s "$skill" -y >/dev/null 2>&1; then ok "$skill"
      else warn "$skill could not be removed"; fi
    done < <(read_manifest "$f")
  done
fi

printf '\n'
ok "Uninstall complete"
hint "Config backups, if any, are at $(tilde "${OPENCODE_CONFIG_DIR}").backup-*"
exit "$EX_OK"

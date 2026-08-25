#!/usr/bin/env bash
# check.sh — health check for the local installation, with self-repair.
#
# Installed as the `ai-dev-check` command.
#
#   ai-dev-check              check, and repair what is safe to repair
#   ai-dev-check --no-repair  report only, change nothing
#   ai-dev-check --dry-run    show the repairs that would be made
#
# What "safe to repair" means here, exactly:
#   yes — recreating a symlink this repository owns, recreating one of its own
#         ~/.local/bin wrappers, re-setting core.hooksPath, chmod +x on its own
#         scripts, creating one of its own directories
#   no  — anything inside a user's agent config, anything holding credentials,
#         anything that is a real file rather than a link this repo created
#
# Exit: 0 healthy or fully repaired, 2 problems remain, 3 a dependency is missing.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

REPAIR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --no-repair) REPAIR=0; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    -h|--help)   printf 'Usage: ai-dev-check [--no-repair] [--dry-run] [--verbose]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done
export DRY_RUN VERBOSE

PROBLEMS=0
REPAIRED=0
problem() { fail "$1"; PROBLEMS=$((PROBLEMS + 1)); [ -n "${2:-}" ] && hint "Fix: $2"; return 0; }
repaired() { fixed "$1"; REPAIRED=$((REPAIRED + 1)); return 0; }

# A repair is attempted only when repairs are enabled; otherwise the problem
# stands and is counted, so --no-repair is a truthful audit.
can_repair() { [ "$REPAIR" = "1" ]; }

banner "AI Dev Check"

# ----------------------------------------------------------- repository -----
section "Repository"
ok "Root  ${C_DIM}$REPO_DIR${C_RESET}"
for required in bootstrap.sh doctor.sh update.sh rules/global.md mcp/mcps.json skills/profiles.conf; do
  if [ -e "$REPO_DIR/$required" ]; then
    ok "$required"
  else
    problem "$required is missing" "re-clone the repository"
  fi
done
for d in adapters scripts/lib scripts/setup scripts/git scripts/context .githooks; do
  if [ -d "$REPO_DIR/$d" ]; then ok "$d/"
  else problem "$d/ is missing" "re-clone the repository"; fi
done

# Directories this repository creates on the local machine.
for d in "$BIN_DIR" "$LOCAL_STATE_DIR"; do
  if [ -d "$d" ]; then
    ok "$(tilde "$d")"
  elif can_repair; then
    ensure_directory "$d" && repaired "created $(tilde "$d")"
  else
    problem "$(tilde "$d") is missing" "./bootstrap.sh"
  fi
done

# -------------------------------------------------------------- symlinks ----
section "Symlinks"
for agent in $(adapter_list); do
  label="$(adapter_run "$agent" label)"
  adapter_run "$agent" detect >/dev/null 2>&1 || { info "$label not installed — skipped"; continue; }
  while IFS='|' read -r kind a b desc; do
    case "$kind" in
      LINK)
        state="$(link_state "$a" "$b")"
        case "$state" in
          ok) ok "$label: $desc" ;;
          conflict)
            warn "$label: $desc — $(tilde "$b") is a real file, left alone"
            hint "Move it aside and re-run if you want this repository to manage it" ;;
          *)
            fail "$label: $desc  ${C_DIM}($state)${C_RESET}"
            if can_repair; then
              case "$(ensure_symlink "$a" "$b")" in
                created|repaired) repaired "relinked $(tilde "$b")" ;;
                would-*)          plan_action RELINK "$(tilde "$b")"; PROBLEMS=$((PROBLEMS + 1)) ;;
                *)                PROBLEMS=$((PROBLEMS + 1)) ;;
              esac
            else
              PROBLEMS=$((PROBLEMS + 1))
            fi ;;
        esac ;;
      BLOCK)
        # BLOCK and CFG rows carry the description in the third field, so it
        # arrives in $b rather than $desc.
        # Generated text blocks are verified by the adapter itself, which knows
        # what the content should be; check.sh only reports the file's presence.
        if [ -f "$a" ]; then ok "$label: $b  ${C_DIM}$(tilde "$a")${C_RESET}"
        else info "$label: $b — $(tilde "$a") not created yet"; fi ;;
      CFG)
        if [ -f "$a" ]; then ok "$label: $b  ${C_DIM}$(tilde "$a")${C_RESET}"
        else problem "$label: $b — $(tilde "$a") missing" "./bootstrap.sh"; fi ;;
    esac
  done < <(adapter_run "$agent" plan)
done

# ------------------------------------------------------------- commands -----
section "Commands"
while IFS='|' read -r name target; do
  [ -n "$name" ] || continue
  p="$BIN_DIR/$name"
  if [ ! -e "$p" ]; then
    fail "$name missing"
    if can_repair; then
      if "$REPO_DIR/scripts/setup/install-commands.sh" --no-shell-rc >/dev/null 2>&1; then
        repaired "reinstalled $name"
      else
        PROBLEMS=$((PROBLEMS + 1))
      fi
    else
      PROBLEMS=$((PROBLEMS + 1))
    fi
  elif [ ! -x "$p" ]; then
    fail "$name is not executable"
    if can_repair && ! is_dry_run; then chmod +x "$p" && repaired "chmod +x $(tilde "$p")"
    else PROBLEMS=$((PROBLEMS + 1)); fi
  elif grep -q "$WRAPPER_MARKER" "$p" 2>/dev/null && ! grep -qF "REPO=\"$REPO_DIR\"" "$p" 2>/dev/null; then
    # The classic broken case: the repository was moved or re-cloned elsewhere
    # and the wrapper still points at the old path.
    fail "$name points at a different repository"
    if can_repair; then
      if "$REPO_DIR/scripts/setup/install-commands.sh" --no-shell-rc >/dev/null 2>&1; then
        repaired "repointed $name at $REPO_DIR"
      else
        PROBLEMS=$((PROBLEMS + 1))
      fi
    else
      PROBLEMS=$((PROBLEMS + 1))
    fi
  else
    ok "$name"
  fi
done < <(ai_dev_commands)

if path_has_dir "$BIN_DIR"; then
  ok "$(tilde "$BIN_DIR") on PATH"
else
  warn "$(tilde "$BIN_DIR") is not on PATH in this shell"
  hint "Open a new shell, or: source $(login_shell_rc 2>/dev/null || printf '%s' "$HOME/.bashrc")"
fi

# ------------------------------------------------------------ git hooks -----
section "Git Hooks"
if ! command_exists git; then
  warn "git not installed — hooks cannot be checked"
elif ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  info "Not a git clone — hooks not applicable"
else
  current="$(git -C "$REPO_DIR" config --local --get core.hooksPath 2>/dev/null || true)"
  if [ "$current" = ".githooks" ]; then
    ok "core.hooksPath"
  else
    fail "core.hooksPath is '${current:-unset}'"
    if can_repair; then
      if is_dry_run; then
        plan_action CONFIGURE "git core.hooksPath = .githooks"; PROBLEMS=$((PROBLEMS + 1))
      else
        git -C "$REPO_DIR" config core.hooksPath .githooks && repaired "core.hooksPath = .githooks"
      fi
    else
      PROBLEMS=$((PROBLEMS + 1))
    fi
  fi
  for hook in pre-commit commit-msg; do
    h="$REPO_DIR/.githooks/$hook"
    if [ ! -f "$h" ]; then
      problem "$hook is missing" "re-clone the repository"
    elif [ -x "$h" ]; then
      ok "$hook"
    else
      fail "$hook is not executable"
      if can_repair && ! is_dry_run; then chmod +x "$h" && repaired "chmod +x $hook"
      else PROBLEMS=$((PROBLEMS + 1)); fi
    fi
  done
fi

# ------------------------------------------------------------- manifests ----
section "Manifests"
if [ -f "$REPO_DIR/mcp/mcps.json" ]; then
  if validate_json "$REPO_DIR/mcp/mcps.json"; then ok "mcp/mcps.json"
  else problem "mcp/mcps.json does not parse" "fix the JSON syntax"; fi
fi
for f in "$REPO_DIR"/skills/*.conf; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # A manifest line must be owner/repo|skill; profiles.conf is name|list.
  bad="$(read_manifest "$f" | grep -vc '|' || true)"
  if [ "${bad:-0}" -eq 0 ]; then ok "skills/$name"
  else problem "skills/$name has $bad line(s) without a '|' separator" "check the manifest format"; fi
done

# --------------------------------------------------------- config parse -----
section "Config"
checked=0
for agent in $(adapter_list); do
  adapter_run "$agent" detect >/dev/null 2>&1 || continue
  label="$(adapter_run "$agent" label)"
  cfg="$(adapter_run "$agent" paths | sed -n 's/^CONFIG_FILE=//p')"
  [ -n "$cfg" ] && [ -f "$cfg" ] || continue
  checked=$((checked + 1))
  case "$cfg" in
    *.toml)
      rc=0; validate_toml "$cfg" || rc=$?
      case "$rc" in
        0) ok "$label  ${C_DIM}$(basename "$cfg") parses${C_RESET}" ;;
        2) info "$label  ${C_DIM}no TOML parser available — skipped${C_RESET}" ;;
        *) problem "$label: $(tilde "$cfg") does not parse as TOML" "restore from $(tilde "$cfg").ai-dev-backup-*" ;;
      esac ;;
    *.jsonc)
      if validate_jsonc "$cfg"; then ok "$label  ${C_DIM}$(basename "$cfg") parses${C_RESET}"
      else problem "$label: $(tilde "$cfg") does not parse" "restore from $(tilde "$(dirname "$cfg")").backup-*"; fi ;;
    *)
      rc=0; validate_json "$cfg" || rc=$?
      case "$rc" in
        0) ok "$label  ${C_DIM}$(basename "$cfg") parses${C_RESET}" ;;
        2) info "$label  ${C_DIM}no JSON parser available — skipped${C_RESET}" ;;
        *) problem "$label: $(tilde "$cfg") does not parse as JSON" "restore from a backup" ;;
      esac ;;
  esac
done
for y in "$REPO_DIR"/.github/workflows/*.yml; do
  [ -f "$y" ] || continue
  rc=0; validate_yaml "$y" || rc=$?
  case "$rc" in
    0) ok "$(repo_relative "$y")" ;;
    2) debug "no YAML parser available for $y" ;;
    *) problem "$(repo_relative "$y") does not parse as YAML" "fix the workflow file" ;;
  esac
done
[ "$checked" -eq 0 ] && info "No agent config files found yet"

# --------------------------------------------------- broken symlink sweep ---
section "Broken links"
sweep_dirs="$BIN_DIR $LOCAL_STATE_DIR $SKILLS_HOME"
for agent in $(adapter_list); do
  m="$(adapter_run "$agent" paths | sed -n 's/^MANAGED_DIR=//p')"
  [ -n "$m" ] && sweep_dirs="$sweep_dirs $m"
done
broken_found=0
for d in $sweep_dirs; do
  [ -d "$d" ] || continue
  # -type l plus an existence test is the portable form of GNU's -xtype l.
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    [ -e "$link" ] && continue
    broken_found=$((broken_found + 1))
    fail "broken: $(tilde "$link")"
    # Only links inside a directory this repository owns are removed; a broken
    # link anywhere else is somebody else's to decide about.
    case "$link" in
      "$LOCAL_STATE_DIR"/*|*"/$MANAGED_NAME/"*)
        if can_repair && ! is_dry_run; then rm -f "$link"; repaired "removed the dead link"
        elif can_repair; then plan_action REMOVE "$(tilde "$link")"; PROBLEMS=$((PROBLEMS + 1))
        else PROBLEMS=$((PROBLEMS + 1)); fi ;;
      "$SKILLS_HOME"/*|"$BIN_DIR"/*)
        hint "Left in place. Run ai-dev-sync to reinstall what owns it."
        PROBLEMS=$((PROBLEMS + 1)) ;;
      *) PROBLEMS=$((PROBLEMS + 1)) ;;
    esac
  done < <(find "$d" -type l 2>/dev/null)
done
[ "$broken_found" -eq 0 ] && ok "None"

# ---------------------------------------------------------------- status ----
section "Status"
if [ "$PROBLEMS" -eq 0 ] && [ "$REPAIRED" -eq 0 ]; then
  ok "Environment healthy"
  printf '\n'; exit "$EX_OK"
elif [ "$PROBLEMS" -eq 0 ]; then
  ok "Environment healthy  ${C_DIM}($REPAIRED repaired)${C_RESET}"
  printf '\n'; exit "$EX_OK"
else
  fail "$PROBLEMS problem(s) remain${REPAIRED:+, $REPAIRED repaired}"
  [ "$REPAIR" = "0" ] && hint "Run without --no-repair to fix what is safely fixable"
  printf '\n'; exit "$EX_CONFIG"
fi

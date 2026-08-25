#!/usr/bin/env bash
# audit.sh — the deep inspection. Everything verify.sh checks, plus the things
# that only go wrong slowly: duplicated configs that have diverged, orphans
# left by an older version of this repository, wrong file permissions, and
# credentials that made it into git history.
#
# Installed as the `ai-dev-audit` command.
#
#   ai-dev-audit             report to the terminal and to state/audit-last.txt
#   ai-dev-audit --no-report don't write the report file
#
# Read-only. It never repairs anything — that is check.sh's job, and keeping
# them apart means an audit can be trusted to tell you what is actually there.
#
# The report goes to state/, which is gitignored: it describes one machine and
# would be meaningless — and mildly identifying — in the repository.
#
# Exit: 0 clean, 5 findings, 4 a credential problem, 2 a repository problem.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

WRITE_REPORT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-report) WRITE_REPORT=0; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    -h|--help)   printf 'Usage: ai-dev-audit [--no-report]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

FINDINGS=0
SECURITY=0
REPO_PROBLEMS=0
finding()  { warn "$1"; FINDINGS=$((FINDINGS + 1)); return 0; }
security() { fail "$1"; SECURITY=$((SECURITY + 1)); return 0; }
broken()   { fail "$1"; REPO_PROBLEMS=$((REPO_PROBLEMS + 1)); return 0; }

banner "Audit"
info "$(now_stamp)  ·  $(os_describe)"

# --------------------------------------------------------------- 1. drift ---
section "Config drift"
rc=0
verify_out="$("$REPO_DIR/scripts/context/verify.sh" --quiet 2>&1)" || rc=$?
case "$rc" in
  0) ok "Local machine matches the repository" ;;
  "$EX_DRIFT")
    finding "Drift detected — run ai-dev-verify for the detail"
    printf '%s\n' "$verify_out" | grep '^⚠' | head -8 | sed 's/^/  /' ;;
  *) broken "verify.sh reported a repository problem (exit $rc)"
     printf '%s\n' "$verify_out" | grep '^✗' | head -8 | sed 's/^/  /' ;;
esac

# ----------------------------------------------------- 2. broken symlinks ---
section "Symlinks"
sweep_dirs="$BIN_DIR $LOCAL_STATE_DIR $SKILLS_HOME"
for agent in $(adapter_list); do
  m="$(adapter_run "$agent" paths 2>/dev/null | sed -n 's/^MANAGED_DIR=//p')"
  [ -n "$m" ] && sweep_dirs="$sweep_dirs $m"
  c="$(adapter_run "$agent" paths 2>/dev/null | sed -n 's/^CONFIG_DIR=//p')"
  [ -n "$c" ] && [ -d "$c/skills" ] && sweep_dirs="$sweep_dirs $c/skills"
done
broken_links=0
for d in $sweep_dirs; do
  [ -d "$d" ] || continue
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    [ -e "$link" ] && continue
    finding "broken symlink: $(tilde "$link")  ${C_DIM}→ $(readlink "$link" 2>/dev/null)${C_RESET}"
    broken_links=$((broken_links + 1))
  done < <(find "$d" -type l 2>/dev/null)
done
[ "$broken_links" -eq 0 ] && ok "No broken symlinks"

# ------------------------------------------------------------- 3. secrets ---
section "Secrets"
rc=0
secret_out="$("$REPO_DIR/scripts/git/preflight.sh" --secrets-only 2>&1)" || rc=$?
if [ "$rc" = "0" ]; then
  ok "No credentials in tracked files"
else
  security "Credential findings in tracked files"
  printf '%s\n' "$secret_out" | grep '^✗' | head -10 | sed 's/^/  /'
fi

# Anything gitignored but present is fine; anything tracked is not.
if [ -f "$REPO_DIR/.env" ]; then
  if command_exists git && git -C "$REPO_DIR" ls-files --error-unmatch .env >/dev/null 2>&1; then
    security ".env is tracked by git"
    hint "git rm --cached .env  and rotate every key it holds"
  else
    mode="$(file_mode "$REPO_DIR/.env" 2>/dev/null || echo '')"
    case "$mode" in
      600|400) ok ".env present, gitignored, mode $mode" ;;
      *)       finding ".env is mode $mode — tighten it: chmod 600 .env" ;;
    esac
  fi
else
  info "No .env file"
fi

# ---------------------------------------------------- 4. duplicate config ---
section "Duplicate config"
dupes=0
SRC_HASH="$(hash_file "$REPO_DIR/rules/global.md" 2>/dev/null || echo '')"
for agent in $(adapter_list); do
  adapter_run "$agent" detect >/dev/null 2>&1 || continue
  label="$(adapter_run "$agent" label)"
  managed="$(adapter_run "$agent" paths | sed -n 's/^MANAGED_DIR=//p')"
  [ -n "$managed" ] && [ -f "$managed/global.md" ] || continue
  # A symlink is the intended shape and can never diverge. A real copy can.
  if [ -L "$managed/global.md" ]; then
    ok "$label: rules linked, cannot diverge"
  else
    h="$(hash_file "$managed/global.md" 2>/dev/null || echo '')"
    if [ -n "$SRC_HASH" ] && [ "$h" = "$SRC_HASH" ]; then
      finding "$label: rules are a copy, not a link — they will drift"
    else
      finding "$label: rules copy has diverged from rules/global.md"
    fi
    dupes=$((dupes + 1))
  fi
done
# More than one clone of this repository on the same machine is the other way
# configs quietly diverge.
clone_mismatch=0
while IFS='|' read -r name _; do
  [ -n "$name" ] || continue
  p="$BIN_DIR/$name"
  [ -f "$p" ] || continue
  t="$(sed -n 's/^REPO="\(.*\)"$/\1/p' "$p" | head -1)"
  [ -n "$t" ] && [ "$t" != "$REPO_DIR" ] && clone_mismatch=$((clone_mismatch + 1))
done < <(ai_dev_commands)
if [ "$clone_mismatch" -gt 0 ]; then
  finding "$clone_mismatch command(s) point at a different clone of this repository"
  hint "Run ./bootstrap.sh from the clone you intend to keep"
fi
[ "$dupes" -eq 0 ] && [ "$clone_mismatch" -eq 0 ] && ok "No duplicated configuration"

# -------------------------------------------------------------- 5. orphans --
section "Orphans"
orphans=0
# Directories and commands from the previous, OpenCode-only generation.
for legacy in "$OPENCODE_CONFIG_DIR/$LEGACY_MANAGED_NAME" "$CLAUDE_HOME/$LEGACY_MANAGED_NAME"; do
  if [ -d "$legacy" ]; then
    finding "leftover from the previous layout: $(tilde "$legacy")"
    hint "Safe to delete once ai-dev-check reports healthy"
    orphans=$((orphans + 1))
  fi
done
for name in $LEGACY_COMMANDS; do
  if [ -f "$BIN_DIR/$name" ]; then
    finding "superseded command still installed: $name"
    hint "Removed automatically by ./bootstrap.sh"
    orphans=$((orphans + 1))
  fi
done
while IFS= read -r rc_file; do
  [ -f "$rc_file" ] || continue
  if grep -qF "$LEGACY_BLOCK_BEGIN" "$rc_file" 2>/dev/null; then
    finding "superseded shell block in $(tilde "$rc_file")"
    orphans=$((orphans + 1))
  fi
done < <(candidate_rc_files)
# Backups pile up; they are harmless but worth knowing about.
backup_count="$(ls -d "${OPENCODE_CONFIG_DIR}".backup-* 2>/dev/null | wc -l | tr -d ' ' || true)"
[ "${backup_count:-0}" -gt 0 ] && info "$backup_count OpenCode config backup(s) kept"
[ "$orphans" -eq 0 ] && ok "No orphaned files"

# ---------------------------------------------------------- 6. permissions --
section "Permissions"
perm_problems=0
# Library files are sourced, never executed, so scripts/lib is skipped on
# purpose: an executable bit there would be the anomaly, not its absence.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in "$REPO_DIR"/scripts/lib/*) continue ;; esac
  if [ ! -x "$f" ]; then
    finding "not executable: $(repo_relative "$f")"
    perm_problems=$((perm_problems + 1))
  fi
done < <(find "$REPO_DIR/scripts" "$REPO_DIR/adapters" -name '*.sh' -type f 2>/dev/null; \
         ls "$REPO_DIR"/*.sh 2>/dev/null; \
         find "$REPO_DIR/.githooks" -type f 2>/dev/null)
if [ -f "$ENV_BRIDGE" ]; then
  mode="$(file_mode "$ENV_BRIDGE")"
  if [ "$mode" = "600" ]; then ok "credential bridge is 600"
  else finding "credential bridge is mode $mode, expected 600"; perm_problems=$((perm_problems + 1)); fi
fi
[ "$perm_problems" -eq 0 ] && ok "All scripts executable, credentials restricted"

# ----------------------------------------------------------- 7. git hooks ---
section "Git hooks"
if command_exists git && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  hp="$(git -C "$REPO_DIR" config --local --get core.hooksPath 2>/dev/null || true)"
  if [ "$hp" = ".githooks" ]; then ok "core.hooksPath = .githooks"
  else finding "core.hooksPath is '${hp:-unset}' — hooks are not running"; fi
  if [ -d "$REPO_DIR/.git/hooks" ]; then
    live="$(find "$REPO_DIR/.git/hooks" -type f ! -name '*.sample' 2>/dev/null | wc -l | tr -d ' ')"
    [ "${live:-0}" -gt 0 ] && finding "$live hook(s) in .git/hooks shadow the versioned ones"
  fi
  for hook in pre-commit commit-msg; do
    if [ -x "$REPO_DIR/.githooks/$hook" ]; then ok "$hook"
    else finding "$hook missing or not executable"; fi
  done
else
  info "Not a git clone"
fi

# ----------------------------------------------------------- 8. manifests ---
section "Manifests"
manifest_problems=0
for f in "$REPO_DIR"/skills/*.conf; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  [ "$name" = "profiles.conf" ] && continue
  dupes="$(read_manifest "$f" | tr -d '[:space:]' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    finding "skills/$name has duplicate entries: $(printf '%s' "$dupes" | tr '\n' ' ')"
    manifest_problems=$((manifest_problems + 1))
  fi
  while IFS='|' read -r repo skill; do
    repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
    skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
    if [ -z "$repo" ] || [ -z "$skill" ]; then
      finding "skills/$name has a malformed line (needs owner/repo|skill)"
      manifest_problems=$((manifest_problems + 1))
      continue
    fi
    case "$repo" in
      */*) ;;
      *) finding "skills/$name: '$repo' is not an owner/repo source"
         manifest_problems=$((manifest_problems + 1)) ;;
    esac
  done < <(read_manifest "$f")
done
# Every profile must name manifests that exist.
while IFS='|' read -r profile list; do
  profile="$(printf '%s' "$profile" | tr -d '[:space:]')"
  [ -n "$profile" ] || continue
  for m in $(printf '%s' "$list" | tr ',' ' '); do
    m="$(printf '%s' "$m" | tr -d '[:space:]')"
    [ -n "$m" ] || continue
    if [ ! -f "$REPO_DIR/skills/$m.conf" ]; then
      finding "profile '$profile' references missing manifest: $m.conf"
      manifest_problems=$((manifest_problems + 1))
    fi
  done
done < <(read_manifest "$REPO_DIR/skills/profiles.conf")
if [ -f "$REPO_DIR/mcp/mcps.json" ]; then
  if validate_json "$REPO_DIR/mcp/mcps.json"; then ok "mcp/mcps.json"
  else broken "mcp/mcps.json does not parse"; fi
fi
[ "$manifest_problems" -eq 0 ] && ok "Skill manifests well-formed"

# ------------------------------------------------------------------ report --
section "Result"
STATUS="clean"
if [ "$SECURITY" -gt 0 ]; then STATUS="security"
elif [ "$REPO_PROBLEMS" -gt 0 ]; then STATUS="repository"
elif [ "$FINDINGS" -gt 0 ]; then STATUS="findings"; fi

case "$STATUS" in
  clean)      ok "No problems found" ;;
  findings)   warn "$FINDINGS finding(s)" ;;
  repository) fail "$REPO_PROBLEMS repository problem(s), $FINDINGS finding(s)" ;;
  security)   fail "$SECURITY security problem(s) — deal with these first" ;;
esac
printf '%s\n' "${C_DIM}Audit completed: $(now_stamp)${C_RESET}"

if [ "$WRITE_REPORT" = "1" ]; then
  ensure_directory "$STATE_DIR" || true
  report="$STATE_DIR/audit-last.txt"
  {
    printf 'ai-dev-bootstrap audit\n'
    printf 'when:     %s\n' "$(now_stamp)"
    printf 'host os:  %s\n' "$(os_describe)"
    printf 'repo:     %s\n' "$REPO_DIR"
    printf 'status:   %s\n' "$STATUS"
    printf 'findings: %s\n' "$FINDINGS"
    printf 'security: %s\n' "$SECURITY"
    printf 'repo problems: %s\n' "$REPO_PROBLEMS"
  } > "$report"
  hint "Report: $(repo_relative "$report")  ${C_DIM}(gitignored)${C_RESET}"
fi
printf '\n'

case "$STATUS" in
  clean)      exit "$EX_OK" ;;
  security)   exit "$EX_SECURITY" ;;
  repository) exit "$EX_CONFIG" ;;
  *)          exit "$EX_DRIFT" ;;
esac

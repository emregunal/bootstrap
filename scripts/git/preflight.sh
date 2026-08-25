#!/usr/bin/env bash
# preflight.sh — the safety gate every commit and push goes through.
#
#   ./scripts/git/preflight.sh            full check, before a push
#   ./scripts/git/preflight.sh --staged   only what is staged (the pre-commit hook)
#
# Checks, in order: git state, merge-conflict markers, secrets, dangerous
# files, shell syntax, JSON validity, repository integrity.
#
# Exit: 0 safe, 4 a security problem (secret or credential file), 1 anything
# else. A non-zero exit is what stops the commit.
#
# Nothing here writes to the repository or the machine. It is a read-only gate.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

STAGED_ONLY=0
SKIP_INTEGRITY=0
SECRETS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --staged)         STAGED_ONLY=1; SKIP_INTEGRITY=1; shift ;;
    --no-integrity)   SKIP_INTEGRITY=1; shift ;;
    --secrets-only)   SECRETS_ONLY=1; SKIP_INTEGRITY=1; shift ;;
    --verbose)        VERBOSE=1; shift ;;
    -h|--help)        printf 'Usage: preflight.sh [--staged] [--secrets-only] [--no-integrity] [--verbose]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

PATTERNS="$REPO_DIR/scripts/lib/secret-patterns.conf"

# A match that looks like one of these is documentation, not a credential.
# Deliberately matched against the captured text only, never the whole line:
# filtering a whole line because it mentions "example" would hide a real key
# sitting next to an example URL.
PLACEHOLDER='(\{env:|\{install:|\$\{|\$[A-Za-z_]|<[^>]*>|x{4,}|X{4,}|[Yy]our[-_ ]|YOUR[-_]|[Ee]xample|EXAMPLE|changeme|CHANGEME|placeholder|PLACEHOLDER|redacted|REDACTED|\*{4,}|\.\.\.|dummy|sample|:(password|passwd|pass|secret|token)@|test[-_]?(key|token|secret))'

# Files whose whole point is to contain pattern-shaped text.
is_allowlisted() {
  case "$1" in
    .env.example|*/.env.example) return 0 ;;
    scripts/lib/secret-patterns.conf|*/secret-patterns.conf) return 0 ;;
    scripts/git/preflight.sh|*/scripts/git/preflight.sh) return 0 ;;
  esac
  return 1
}

PROBLEMS=0
SECURITY=0
problem()  { fail "$1"; PROBLEMS=$((PROBLEMS + 1)); return 0; }
security() { fail "$1"; SECURITY=$((SECURITY + 1)); return 0; }

banner "Preflight"

command_exists git || die "$EX_DEPS" "git is required"
git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "$EX_FAIL" "Not a git repository: $REPO_DIR"
cd "$REPO_DIR"

# ------------------------------------------------------------- git state ----
section "Git state"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
STAGED_FILES="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)"
UNSTAGED_COUNT="$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')"
UNTRACKED_COUNT="$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
STAGED_COUNT="$(printf '%s' "$STAGED_FILES" | grep -c . || true)"

ok "Branch  ${C_DIM}$BRANCH${C_RESET}"
if [ "$STAGED_COUNT" -gt 0 ]; then ok "$STAGED_COUNT file(s) staged"
else info "Nothing staged"; fi
[ "$UNSTAGED_COUNT" -gt 0 ]  && info "$UNSTAGED_COUNT file(s) modified but not staged"
[ "$UNTRACKED_COUNT" -gt 0 ] && info "$UNTRACKED_COUNT untracked file(s)"

# Which files this run examines: staged content in --staged mode, the whole
# tracked tree otherwise.
if [ "$STAGED_ONLY" = "1" ]; then
  FILES="$STAGED_FILES"
  SCOPE="staged"
else
  FILES="$(git ls-files 2>/dev/null || true)"
  SCOPE="tracked"
fi

# Reads a file's content for the scope in play: from the index when staged,
# from the working tree otherwise.
content_of() {
  if [ "$STAGED_ONLY" = "1" ]; then git show ":$1" 2>/dev/null || true
  else cat "$1" 2>/dev/null || true; fi
}

is_binary() {
  case "$1" in
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.gz|*.tar|*.woff|*.woff2|*.ttf|*.otf|*.mp4|*.webp) return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------- merge conflicts ----
section "Merge conflicts"
conflicts=0
for f in $FILES; do
  is_binary "$f" && continue
  # Both the opening and closing marker must be present. A bare row of "=" is
  # a markdown heading underline far more often than it is a conflict.
  body="$(content_of "$f")"
  if printf '%s\n' "$body" | grep -qE '^<{7}( |$)' && printf '%s\n' "$body" | grep -qE '^>{7}( |$)'; then
    problem "Conflict markers in $f"
    conflicts=$((conflicts + 1))
  fi
done
[ "$conflicts" -eq 0 ] && ok "None"

# ------------------------------------------------------------ secret scan ---
section "Secret scan"
if [ ! -f "$PATTERNS" ]; then
  problem "Pattern file missing: $(repo_relative "$PATTERNS")"
else
  hits=0
  for f in $FILES; do
    is_binary "$f" && continue
    is_allowlisted "$f" && { debug "allowlisted: $f"; continue; }
    body="$(content_of "$f")"
    [ -n "$body" ] || continue
    while IFS='|' read -r id sev desc re; do
      [ -n "${id:-}" ] || continue
      case "$id" in '#'*) continue ;; esac
      # The matched text is filtered, then discarded. It is never printed:
      # a preflight report that echoes the secret defeats its own purpose.
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        lineno="${m%%:*}"
        text="${m#*:}"
        # -e is required: several patterns start with a character grep would
        # otherwise read as an option.
        matched="$(printf '%s\n' "$text" | grep -oE -e "$re" 2>/dev/null | head -1)"
        [ -n "$matched" ] || continue
        printf '%s' "$matched" | grep -qE "$PLACEHOLDER" && continue
        hits=$((hits + 1))
        if [ "$sev" = "low" ]; then
          warn "$f:$lineno  $desc  ${C_DIM}[$id]${C_RESET}"
        else
          security "$f:$lineno  $desc  ${C_DIM}[$id]${C_RESET}"
        fi
      done < <(printf '%s\n' "$body" | grep -nE -e "$re" 2>/dev/null || true)
    done < "$PATTERNS"
  done
  if [ "$hits" -eq 0 ]; then
    ok "No credentials found in $SCOPE files"
  else
    hint "Remove the value, put it in .env (gitignored), and reference it as {env:VAR}"
  fi
fi

# --------------------------------------------------------- dangerous files --
section "Credential files"
DANGEROUS='^(.*/)?(\.env|\.env\..*|credentials\.json|secrets\.json|auth\.json|\.netrc|id_rsa|id_ed25519|id_ecdsa|.*\.pem|.*\.key|.*\.p12|.*\.pfx)$'
dangerous_hits=0
for f in $STAGED_FILES; do
  case "$f" in *.env.example) continue ;; esac
  if printf '%s' "$f" | grep -qE "$DANGEROUS"; then
    security "$f must never be committed"
    dangerous_hits=$((dangerous_hits + 1))
  fi
done
# Also catch one already in history, which .gitignore cannot undo.
for f in $(git ls-files 2>/dev/null || true); do
  case "$f" in *.env.example) continue ;; esac
  if printf '%s' "$f" | grep -qE "$DANGEROUS"; then
    security "$f is tracked by git — it should not be"
    hint "git rm --cached '$f'  and rotate whatever it contained"
    dangerous_hits=$((dangerous_hits + 1))
  fi
done
[ "$dangerous_hits" -eq 0 ] && ok "None staged or tracked"

# The remaining sections are correctness checks rather than security ones.
# audit.sh runs this script with --secrets-only and does its own.
if [ "$SECRETS_ONLY" = "1" ]; then
  section "Result"
  if [ "$SECURITY" -gt 0 ]; then
    fail "$SECURITY security problem(s)"; printf '\n'; exit "$EX_SECURITY"
  fi
  ok "No credential problems"; printf '\n'; exit "$EX_OK"
fi

# ----------------------------------------------------------- shell syntax ---
section "Shell syntax"
shell_files=""
for f in $FILES; do
  case "$f" in
    *.sh) shell_files="$shell_files $f" ;;
    .githooks/*) shell_files="$shell_files $f" ;;
  esac
done
if [ -z "$shell_files" ]; then
  info "No shell files in scope"
else
  bad=0
  for f in $shell_files; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then debug "syntax ok: $f"
    else problem "Syntax error in $f"; bash -n "$f" 2>&1 | head -3 | sed 's/^/    /'; bad=$((bad + 1)); fi
  done
  [ "$bad" -eq 0 ] && ok "$(printf '%s' "$shell_files" | wc -w | tr -d ' ') file(s) parse"
fi

# ------------------------------------------------------- json validation ----
section "JSON validation"
json_files=""
for f in $FILES; do
  case "$f" in *.json) json_files="$json_files $f" ;; esac
done
if [ -z "$json_files" ]; then
  info "No JSON files in scope"
else
  bad=0
  for f in $json_files; do
    [ -f "$f" ] || continue
    rc=0; validate_json "$f" || rc=$?
    case "$rc" in
      0) debug "json ok: $f" ;;
      2) warn "No JSON parser available — $f not validated" ;;
      *) problem "Invalid JSON: $f"; bad=$((bad + 1)) ;;
    esac
  done
  [ "$bad" -eq 0 ] && ok "$(printf '%s' "$json_files" | wc -w | tr -d ' ') file(s) parse"
fi

# --------------------------------------------------------------- integrity --
section "Repository integrity"
if [ "$SKIP_INTEGRITY" = "1" ]; then
  info "Skipped in this mode  ${C_DIM}(run ai-dev-check separately)${C_RESET}"
elif [ -x "$REPO_DIR/scripts/setup/check.sh" ]; then
  if "$REPO_DIR/scripts/setup/check.sh" --no-repair >/dev/null 2>&1; then
    ok "Local installation healthy"
  else
    warn "ai-dev-check reports problems — not blocking the commit"
    hint "Run: ai-dev-check"
  fi
else
  warn "check.sh not found"
fi

# ------------------------------------------------------------------ result --
section "Result"
if [ "$SECURITY" -gt 0 ]; then
  fail "$SECURITY security problem(s) — DO NOT COMMIT"
  printf '\n'
  exit "$EX_SECURITY"
elif [ "$PROBLEMS" -gt 0 ]; then
  fail "$PROBLEMS problem(s) found"
  printf '\n'
  exit "$EX_FAIL"
else
  ok "SAFE TO COMMIT"
  printf '\n'
  exit "$EX_OK"
fi

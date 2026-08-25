#!/usr/bin/env bash
# commit.sh — commit what is staged, once preflight says it is safe.
#
#   ./scripts/git/commit.sh "feat: add backend skills"
#   ./scripts/git/commit.sh "fix: repair symlink check" --push
#   ./scripts/git/commit.sh "docs: readme" --dry-run
#
# Deliberate omissions:
#   - never runs `git add .`; you choose what goes in, this only commits it
#   - never stages a file you did not stage yourself
#   - never pushes unless --push is given, and re-runs preflight before it does
#
# Exit: 0 committed, 4 preflight found a security problem, 1 anything else.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

MESSAGE=""
PUSH=0
SKIP_PREFLIGHT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --push)          PUSH=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --verbose)       VERBOSE=1; shift ;;
    --no-preflight)  SKIP_PREFLIGHT=1; shift ;;
    -h|--help)       printf 'Usage: commit.sh "message" [--push] [--dry-run]\n'; exit 0 ;;
    -*)              die "$EX_FAIL" "Unknown option: $1" ;;
    *)               if [ -z "$MESSAGE" ]; then MESSAGE="$1"
                     else die "$EX_FAIL" "Unexpected argument: $1"; fi
                     shift ;;
  esac
done

command_exists git || die "$EX_DEPS" "git is required"
cd "$REPO_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || die "$EX_FAIL" "Not a git repository: $REPO_DIR"

[ -n "$MESSAGE" ] || die "$EX_FAIL" "A commit message is required:  ./scripts/git/commit.sh \"feat: ...\""

banner "Commit"

# ---------------------------------------------------------- staged check ----
STAGED="$(git diff --cached --name-only 2>/dev/null || true)"
if [ -z "$STAGED" ]; then
  fail "Nothing staged for commit."
  hint "Use git add <files> first."
  MODIFIED="$(git diff --name-only 2>/dev/null || true)"
  if [ -n "$MODIFIED" ]; then
    printf '\n%s\n' "${C_DIM}Modified but unstaged:${C_RESET}"
    printf '%s\n' "$MODIFIED" | sed 's/^/  /'
  fi
  exit "$EX_FAIL"
fi

section "Staged"
git diff --cached --name-status | sed 's/^/  /'

# --------------------------------------------------------------- preflight --
if [ "$SKIP_PREFLIGHT" = "1" ]; then
  warn "Preflight skipped (--no-preflight)"
else
  printf '\n'
  rc=0
  "$REPO_DIR/scripts/git/preflight.sh" --staged || rc=$?
  case "$rc" in
    0) ;;
    "$EX_SECURITY")
      fail "Preflight found a security problem — nothing was committed"
      exit "$EX_SECURITY" ;;
    *)
      fail "Preflight failed — nothing was committed"
      exit "$EX_FAIL" ;;
  esac
fi

# ------------------------------------------------------------------ commit --
section "Commit"
if is_dry_run; then
  plan_action COMMIT "$MESSAGE"
  [ "$PUSH" = "1" ] && plan_action PUSH "$(git rev-parse --abbrev-ref HEAD)"
  exit "$EX_OK"
fi

# --no-verify would be wrong here: the hook re-runs preflight, which is cheap
# in --staged mode and is the same gate a plain `git commit` gets.
if git commit -m "$MESSAGE"; then
  ok "Committed  ${C_DIM}$(git rev-parse --short HEAD)${C_RESET}"
else
  die "$EX_FAIL" "git commit failed"
fi

section "History"
git --no-pager log --oneline -5 | sed 's/^/  /'

# -------------------------------------------------------------------- push --
if [ "$PUSH" != "1" ]; then
  printf '\n'
  info "Not pushed. Push with:  ./scripts/git/commit.sh \"...\" --push   or   git push"
  exit "$EX_OK"
fi

section "Push"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# A push publishes; it gets the full check, not the fast staged-only one.
rc=0
"$REPO_DIR/scripts/git/preflight.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "$EX_SECURITY" ]; then
  fail "Full preflight found a security problem — NOT pushed"
  hint "Run ./scripts/git/preflight.sh to see it"
  exit "$EX_SECURITY"
elif [ "$rc" != "0" ]; then
  warn "Full preflight reported problems — pushing anyway would publish them"
  hint "Run ./scripts/git/preflight.sh, fix, then: git push"
  exit "$EX_FAIL"
fi
ok "Full preflight clean"

if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git push
else
  info "No upstream branch — setting one"
  git push -u origin "$BRANCH"
fi
ok "Pushed  ${C_DIM}$BRANCH${C_RESET}"
exit "$EX_OK"

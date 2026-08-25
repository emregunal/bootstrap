#!/usr/bin/env bash
# logging.sh — every line this repository prints goes through here.
# Sourced, never executed. Depends on nothing else.
#
# Output rules that the rest of the repo relies on:
#   - human output goes to stdout, diagnostics to stderr
#   - colour is dropped when stdout is not a terminal, so logs and CI stay clean
#   - secret values are never printed, not even with --verbose (see redact)

[ -n "${_AI_DEV_LOGGING_LOADED:-}" ] && return 0
_AI_DEV_LOGGING_LOADED=1

# --------------------------------------------------------------- colours ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

# ---------------------------------------------------------------- output ----
banner() {
  printf '%s\n' "${C_CYAN}────────────────────────────────────────${C_RESET}"
  printf '%s\n' " ${C_BOLD}$1${C_RESET}"
  printf '%s\n' "${C_CYAN}────────────────────────────────────────${C_RESET}"
}
section() { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }
step()    { printf '\n%s\n' "${C_BOLD}[$1] $2${C_RESET}"; }

ok()      { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
fail()    { printf '%s\n' "${C_RED}✗${C_RESET} $*"; }
warn()    { printf '%s\n' "${C_YELLOW}⚠${C_RESET} $*"; }
info()    { printf '%s\n' "${C_DIM}·${C_RESET} $*"; }
hint()    { printf '%s\n' "  ${C_DIM}$*${C_RESET}"; }

# Aliases required by the shared-library contract; ok/fail are the older
# spellings and both are used across the repo.
success() { ok "$@"; }
error()   { fail "$@"; }

# A repaired problem is neither a pass nor a failure — it gets its own mark so
# `check.sh` output makes clear that something *was* wrong a moment ago.
fixed()   { printf '%s\n' "  ${C_GREEN}→${C_RESET} ${C_DIM}$*${C_RESET}"; }

# die exits with EX_FAIL unless the caller set a code: die 3 "message"
die() {
  local code=1
  case "${1:-}" in ''|*[!0-9]*) ;; *) code="$1"; shift ;; esac
  fail "$*"
  exit "$code"
}

# --------------------------------------------------------------- verbose ----
# DEBUG=1 in the environment and --verbose on the command line are equivalent;
# scripts set VERBOSE from their own argument parsing.
VERBOSE="${VERBOSE:-${DEBUG:-0}}"
debug() { [ "${VERBOSE:-0}" = "1" ] || return 0; printf '%s\n' "${C_DIM}  debug: $*${C_RESET}" >&2; }

# --------------------------------------------------------------- dry run ----
# One place decides how a planned change is rendered, so --dry-run output looks
# the same whichever script produced it.
#   plan_action LINK "~/.local/bin/ai-dev-doctor"
plan_action() {
  local verb="$1"; shift
  printf '%s\n' "${C_BLUE}WOULD ${verb}${C_RESET}  $*"
}

# ----------------------------------------------------------- redaction ------
# Anything that might carry a credential goes through this before it is shown.
# Keeps enough of the string to identify which key is meant, never enough to
# use it. Applies in --verbose too: there is no mode that prints a secret.
redact() {
  local v="${1:-}"
  local n=${#v}
  if [ "$n" -eq 0 ]; then printf '(empty)'; return 0; fi
  if [ "$n" -le 8 ]; then printf '********'; return 0; fi
  printf '%s…%s' "${v:0:3}" "$(printf '%*s' 6 '' | tr ' ' '*')"
}

# Collapse a $HOME-prefixed path to ~ so output stays readable and does not
# publish the account name in shared logs.
tilde() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    "$HOME")   printf '~' ;;
    *)         printf '%s' "$1" ;;
  esac
}

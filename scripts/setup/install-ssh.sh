#!/usr/bin/env bash
# install-ssh.sh — check that SSH to GitHub is usable, and help set up the
# parts that are safe to automate.
#
#   ./scripts/setup/install-ssh.sh              check only
#   ./scripts/setup/install-ssh.sh --fix-perms  correct ~/.ssh permissions
#   ./scripts/setup/install-ssh.sh --add-host   add the github.com Host block
#
# What this script will never do, by design:
#   - generate a private key
#   - modify, move or delete an existing key
#   - print, log or copy a private key anywhere
#   - upload anything to GitHub
# Key generation stays a deliberate, human act; the exact command is printed
# for you to run yourself.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

FIX_PERMS=0
ADD_HOST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix-perms) FIX_PERMS=1; shift ;;
    --add-host)  ADD_HOST=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --verbose)   VERBOSE=1; shift ;;
    -h|--help)   printf 'Usage: install-ssh.sh [--fix-perms] [--add-host] [--dry-run]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
PROBLEMS=0
problem() { fail "$1"; PROBLEMS=$((PROBLEMS + 1)); return 0; }

banner "SSH"

command_exists ssh || die "$EX_DEPS" "ssh is not installed"

# ------------------------------------------------------------- directory -----
section "Directory"
if [ -d "$SSH_DIR" ]; then
  ok "$(tilde "$SSH_DIR")"
elif [ "$FIX_PERMS" = "1" ] && ! is_dry_run; then
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  ok "Created $(tilde "$SSH_DIR") (700)"
else
  # A plain run reports; it does not create. Creating ~/.ssh is a change to the
  # user's home directory and needs the same explicit flag as any other.
  warn "$(tilde "$SSH_DIR") does not exist"
  hint "Create it with: ./scripts/setup/install-ssh.sh --fix-perms"
fi

# ----------------------------------------------------------- permissions -----
section "Permissions"
if [ -d "$SSH_DIR" ]; then
  mode="$(file_mode "$SSH_DIR")"
  if [ "$mode" = "700" ]; then
    ok "$(tilde "$SSH_DIR") is 700"
  else
    fail "$(tilde "$SSH_DIR") is $mode, must be 700"
    if [ "$FIX_PERMS" = "1" ] && ! is_dry_run; then chmod 700 "$SSH_DIR"; fixed "set to 700"
    else PROBLEMS=$((PROBLEMS + 1)); hint "Fix with: --fix-perms"; fi
  fi
  # Private keys must be 600. A private key is identified by its matching .pub,
  # and the file itself is never opened.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    kmode="$(file_mode "$key")"
    kname="$(basename "$key")"
    case "$kmode" in
      600|400) ok "$kname is $kmode" ;;
      *)
        fail "$kname is $kmode — a private key must be 600"
        if [ "$FIX_PERMS" = "1" ] && ! is_dry_run; then chmod 600 "$key"; fixed "set to 600"
        else PROBLEMS=$((PROBLEMS + 1)); hint "Fix with: --fix-perms"; fi ;;
    esac
  done < <(find "$SSH_DIR" -maxdepth 1 -type f ! -name '*.pub' ! -name 'known_hosts*' ! -name 'config' 2>/dev/null)
fi

# ------------------------------------------------------------------ keys -----
section "Keys"
found_key=0
if [ -d "$SSH_DIR" ]; then
  while IFS= read -r pub; do
    [ -n "$pub" ] || continue
    found_key=1
    # Only the public key is read, and only its type and comment are shown —
    # never the key material.
    ktype="$(awk '{print $1}' "$pub" 2>/dev/null)"
    kcomment="$(awk '{print $3}' "$pub" 2>/dev/null)"
    ok "$(basename "$pub")  ${C_DIM}$ktype ${kcomment:-}${C_RESET}"
  done < <(find "$SSH_DIR" -maxdepth 1 -name '*.pub' -type f 2>/dev/null)
fi
if [ "$found_key" = "0" ]; then
  warn "No SSH key found"
  hint "Create one yourself — this script will not do it for you:"
  hint "  ssh-keygen -t ed25519 -C \"your-email@example.com\""
  hint "  cat ~/.ssh/id_ed25519.pub    then add it at https://github.com/settings/keys"
fi

# ----------------------------------------------------------- known_hosts -----
section "GitHub host key"
if [ -f "$SSH_DIR/known_hosts" ] && ssh-keygen -F github.com -f "$SSH_DIR/known_hosts" >/dev/null 2>&1; then
  ok "github.com is in known_hosts"
else
  warn "github.com is not in known_hosts — the first connection will prompt"
  hint "Add it after checking the fingerprint against https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints:"
  hint "  ssh-keyscan github.com >> ~/.ssh/known_hosts"
fi

# ---------------------------------------------------------------- config -----
section "SSH config"
if [ -f "$SSH_CONFIG" ] && grep -qE '^[[:space:]]*Host[[:space:]]+github\.com' "$SSH_CONFIG" 2>/dev/null; then
  ok "A Host block for github.com already exists"
elif [ "$ADD_HOST" = "1" ]; then
  block="$(cat <<BLOCK
Host github.com
  HostName github.com
  User git
  AddKeysToAgent yes
  IdentitiesOnly yes
BLOCK
)"
  case "$(printf '%s' "$block" | ensure_block "$SSH_CONFIG")" in
    created)      chmod 600 "$SSH_CONFIG"; ok "Added a github.com Host block to $(tilde "$SSH_CONFIG")" ;;
    updated)      ok "Refreshed the github.com Host block" ;;
    current)      ok "Host block already current" ;;
    would-*)      plan_action UPDATE "$(tilde "$SSH_CONFIG")  (github.com Host block)" ;;
  esac
  hint "IdentitiesOnly is on; add 'IdentityFile ~/.ssh/your_key' if you use more than one key"
else
  info "No github.com Host block  ${C_DIM}(optional — add one with --add-host)${C_RESET}"
fi

# ---------------------------------------------------------- connectivity -----
section "Connectivity"
if [ "$found_key" = "0" ]; then
  info "Skipped — no key to authenticate with"
else
  # BatchMode stops ssh from prompting; the "successfully authenticated"
  # response comes back on exit code 1, which is GitHub's normal reply.
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
  case "$out" in
    *"successfully authenticated"*)
      user="$(printf '%s' "$out" | sed -n 's/^Hi \([^!]*\)!.*/\1/p')"
      ok "Authenticated to GitHub${user:+  ${C_DIM}as $user${C_RESET}}" ;;
    *"Permission denied"*)
      problem "GitHub refused the key"
      hint "Add the public key at https://github.com/settings/keys" ;;
    *"Host key verification failed"*)
      problem "Host key verification failed"
      hint "ssh-keyscan github.com >> ~/.ssh/known_hosts" ;;
    *)
      warn "Could not verify the connection"
      hint "$(printf '%s' "$out" | head -1)" ;;
  esac
fi

section "Result"
if [ "$PROBLEMS" -eq 0 ]; then
  ok "SSH looks fine"
  printf '\n'; exit "$EX_OK"
fi
fail "$PROBLEMS problem(s)"
printf '\n'
exit "$EX_CONFIG"

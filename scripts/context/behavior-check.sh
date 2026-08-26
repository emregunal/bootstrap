#!/usr/bin/env bash
# behavior-check.sh — tests that the automation *behaves*, not that its files
# exist. Every assertion runs something and checks what came back.
#
#   ./scripts/context/behavior-check.sh            read-only tests
#   ./scripts/context/behavior-check.sh --mutate   also the sandboxed install
#   ./scripts/context/behavior-check.sh --verbose  show each assertion
#
# Read-only is the default and it means it: the tests below either call things
# that do not write, or write inside a mktemp directory that is deleted
# afterwards. --mutate adds the tests that run the real installers — still
# never against your home directory, but against a throwaway HOME, which is a
# stronger claim and so it is opt-in.
#
# Exit: 0 all passed, 1 something failed.

set -Eeuo pipefail
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

MUTATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate)  MUTATE=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) printf 'Usage: behavior-check.sh [--mutate] [--verbose]\n'; exit 0 ;;
    *) die "$EX_FAIL" "Unknown option: $1" ;;
  esac
done

PASS=0
FAIL=0
CURRENT=""

t() { CURRENT="$1"; }
pass() { PASS=$((PASS + 1)); ok "$CURRENT${1:+  ${C_DIM}$1${C_RESET}}"; }
nope() { FAIL=$((FAIL + 1)); fail "$CURRENT"; [ -n "${1:-}" ] && printf '%s\n' "    ${C_DIM}$1${C_RESET}"; return 0; }

# assert_eq EXPECTED ACTUAL [context]
assert_eq() {
  if [ "$1" = "$2" ]; then pass "${3:-}"
  else nope "expected '$1', got '$2'"; fi
}

TMPROOT="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT INT TERM

banner "Behaviour Tests"
info "Sandbox: $TMPROOT"

# ---------------------------------------------------------- manifest parser --
section "Manifest parser"

t "read_manifest strips comments and blank lines"
cat > "$TMPROOT/m.conf" <<'EOF'
# a comment

owner/repo|skill-one    # trailing comment
owner/repo|skill-two

EOF
assert_eq "2" "$(read_manifest "$TMPROOT/m.conf" | wc -l | tr -d ' ')"

t "read_manifest keeps the pipe fields intact"
assert_eq "owner/repo|skill-one" "$(read_manifest "$TMPROOT/m.conf" | head -1)"

t "manifests_for_profile resolves a composite profile"
assert_eq "backend database" "$(manifests_for_profile backend | tr '\n' ' ' | sed 's/ $//')"

t "manifests_for_profile accepts a bare manifest name"
assert_eq "frontend" "$(manifests_for_profile frontend | tr '\n' ' ' | sed 's/ $//')"

t "manifests_for_profile rejects an unknown profile"
if manifests_for_profile no-such-profile >/dev/null 2>&1; then nope "it accepted a bogus profile"; else pass; fi

t "every profile names manifests that exist"
missing=""
while IFS='|' read -r p list; do
  [ -n "$p" ] || continue
  for m in $(printf '%s' "$list" | tr ',' ' '); do
    [ -f "$REPO_DIR/skills/$m.conf" ] || missing="$missing $p:$m"
  done
done < <(read_manifest "$REPO_DIR/skills/profiles.conf")
[ -z "$missing" ] && pass || nope "missing:$missing"

# ------------------------------------------------------- platform detection --
section "Platform detection"

t "os_name returns a known platform"
case "$(os_name)" in Linux|WSL|macOS) pass "$(os_name)" ;; *) nope "got '$(os_name)'" ;; esac

t "resolve_path follows a chain of symlinks"
mkdir -p "$TMPROOT/real"
echo hi > "$TMPROOT/real/file"
ln -s "$TMPROOT/real/file" "$TMPROOT/link1"
ln -s "$TMPROOT/link1" "$TMPROOT/link2"
# The expectation is canonicalised with cd -P rather than written out, because
# on macOS /var is itself a symlink to /private/var: resolve_path resolves the
# directory too, and it is right to.
assert_eq "$(cd -P "$TMPROOT/real" && pwd)/file" "$(resolve_path "$TMPROOT/link2")"

t "link_target reports the recorded target, not the final file"
assert_eq "$TMPROOT/link1" "$(link_target "$TMPROOT/link2")"

t "hash_file agrees with itself and differs on different content"
h1="$(hash_file "$TMPROOT/real/file")"
echo bye > "$TMPROOT/real/file2"
h2="$(hash_file "$TMPROOT/real/file2")"
if [ -n "$h1" ] && [ "$h1" != "$h2" ]; then pass; else nope "h1='$h1' h2='$h2'"; fi

t "sed_inplace edits without changing the file mode"
printf 'alpha\n' > "$TMPROOT/sedme"; chmod 640 "$TMPROOT/sedme"
sed_inplace 's/alpha/beta/' "$TMPROOT/sedme"
if [ "$(cat "$TMPROOT/sedme")" = "beta" ] && [ "$(file_mode "$TMPROOT/sedme")" = "640" ]; then pass
else nope "content='$(cat "$TMPROOT/sedme")' mode=$(file_mode "$TMPROOT/sedme")"; fi

t "file_mode returns octal permissions"
assert_eq "640" "$(file_mode "$TMPROOT/sedme")"

# ------------------------------------------------------- symlink primitives --
section "Symlink primitives"

S="$TMPROOT/sym"; mkdir -p "$S"
echo src > "$S/src"; echo other > "$S/other"

t "link_state reports missing"
assert_eq "missing" "$(link_state "$S/src" "$S/l")"

t "ensure_symlink creates the link"
assert_eq "created" "$(ensure_symlink "$S/src" "$S/l")"

t "ensure_symlink is idempotent"
assert_eq "current" "$(ensure_symlink "$S/src" "$S/l")"

t "link_state detects a link pointing elsewhere"
ln -sf "$S/other" "$S/l"
assert_eq "wrong" "$(link_state "$S/src" "$S/l")"

t "ensure_symlink repairs a wrong target"
assert_eq "repaired" "$(ensure_symlink "$S/src" "$S/l")"

t "link_state detects a broken link"
mv "$S/src" "$S/src.moved"
assert_eq "broken" "$(link_state "$S/src" "$S/l")"
mv "$S/src.moved" "$S/src"

t "ensure_symlink refuses to replace a real file"
echo mine > "$S/realfile"
rc=0; out="$(ensure_symlink "$S/src" "$S/realfile")" || rc=$?
if [ "$out" = "conflict" ] && [ "$rc" != "0" ] && [ "$(cat "$S/realfile")" = "mine" ]; then pass "file left intact"
else nope "out='$out' rc=$rc content='$(cat "$S/realfile")'"; fi

t "dry run creates nothing"
assert_eq "would-create" "$(DRY_RUN=1 ensure_symlink "$S/src" "$S/dryl")"
t "dry run really created nothing"
if [ -e "$S/dryl" ]; then nope "the link exists"; else pass; fi

# ----------------------------------------------------------- managed blocks --
section "Managed blocks"

B="$TMPROOT/block"; mkdir -p "$B"
printf 'first\nsecond\n' > "$B/rc"

t "ensure_block adds a block"
assert_eq "created" "$(printf 'export A=1' | ensure_block "$B/rc")"

t "ensure_block is idempotent"
assert_eq "current" "$(printf 'export A=1' | ensure_block "$B/rc")"

t "ensure_block rewrites in place instead of appending"
printf 'export A=2' | ensure_block "$B/rc" >/dev/null
printf 'export A=3' | ensure_block "$B/rc" >/dev/null
assert_eq "1" "$(grep -c "$BLOCK_BEGIN" "$B/rc" | tr -d ' ')"

t "ensure_block preserves the lines around it"
if head -2 "$B/rc" | tr '\n' ' ' | grep -q 'first second'; then pass; else nope "$(head -3 "$B/rc" | tr '\n' '/')"; fi

t "remove_block leaves the rest of the file alone"
remove_block "$B/rc"
assert_eq "first second" "$(tr '\n' ' ' < "$B/rc" | sed 's/ *$//')"

t "block_state detects stale content"
printf 'export A=1' | ensure_block "$B/rc" >/dev/null
assert_eq "stale" "$(printf 'export A=9' | block_state "$B/rc")"

# ---------------------------------------------------------- config adapters --
section "Config adapters"

for agent in $(adapter_list); do
  t "$agent adapter reports a label"
  label="$(adapter_run "$agent" label 2>/dev/null || true)"
  [ -n "$label" ] && pass "$label" || nope "no label"

  t "$agent adapter emits absolute paths"
  bad="$(adapter_run "$agent" paths 2>/dev/null | grep -E '_(DIR|FILE)=' | grep -v '=/' || true)"
  [ -z "$bad" ] && pass || nope "relative path: $bad"

  t "$agent adapter plan is well-formed"
  badrow="$(adapter_run "$agent" plan 2>/dev/null | grep -vE '^(LINK|BLOCK|CFG)\|' || true)"
  [ -z "$badrow" ] && pass || nope "bad row: $badrow"

  t "$agent adapter plan targets absolute paths"
  badtarget="$(adapter_run "$agent" plan 2>/dev/null | cut -d'|' -f2 | grep -v '^/' || true)"
  [ -z "$badtarget" ] && pass || nope "$badtarget"

  t "$agent adapter rejects an unknown subcommand"
  if adapter_run "$agent" definitely-not-a-subcommand >/dev/null 2>&1; then nope "it accepted one"; else pass; fi
done

t "adapter verify output uses the documented statuses"
badstatus=""
for agent in $(adapter_list); do
  adapter_run "$agent" detect >/dev/null 2>&1 || continue
  out="$(adapter_run "$agent" verify 2>/dev/null || true)"
  b="$(printf '%s\n' "$out" | grep -v '^$' | cut -d'|' -f1 | grep -vE '^(OK|MISS|DRIFT|WARN|SKIP)$' || true)"
  [ -n "$b" ] && badstatus="$badstatus $agent:$b"
done
[ -z "$badstatus" ] && pass || nope "$badstatus"

# --------------------------------------------------------------- MCP render --
section "MCP rendering"

MANIFEST="$REPO_DIR/mcp/mcps.json"

t "manifest lists servers"
n="$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST" | wc -l | tr -d ' ')"
[ "$n" -gt 0 ] && pass "$n servers" || nope "none listed"

t "claude rendering produces valid JSON for every server"
badjson=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  j="$(CONTEXT7_API_KEY=t GITHUB_TOKEN=t MCP_FILESYSTEM_ROOT=/tmp node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target claude --server "$name" 2>/dev/null || true)"
  printf '%s' "$j" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s)})' 2>/dev/null || badjson="$badjson $name"
done < <(node "$REPO_DIR/scripts/lib/mcp-render.mjs" list --manifest "$MANIFEST")
[ -z "$badjson" ] && pass || nope "invalid JSON for:$badjson"

t "codex rendering produces parseable TOML"
CONTEXT7_API_KEY=t GITHUB_TOKEN=t MCP_FILESYSTEM_ROOT=/tmp \
  node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target codex > "$TMPROOT/render.toml"
rc=0; validate_toml "$TMPROOT/render.toml" || rc=$?
case "$rc" in
  0) pass ;;
  2) pass "no TOML parser — skipped" ;;
  *) nope "$(head -5 "$TMPROOT/render.toml")" ;;
esac

t "install-time placeholders are resolved, runtime ones are not"
out="$(MCP_FILESYSTEM_ROOT=/sentinel/path node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target claude --server filesystem)"
if printf '%s' "$out" | grep -q '/sentinel/path' && ! printf '%s' "$out" | grep -q '{install:'; then pass
else nope "$out"; fi

t "status reports a missing required variable"
out="$(env -u GITHUB_TOKEN node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server github)"
assert_eq "missing:GITHUB_TOKEN" "$out"

t "status reports ok when nothing is required"
assert_eq "ok" "$(node "$REPO_DIR/scripts/lib/mcp-render.mjs" status --manifest "$MANIFEST" --server playwright)"

# A header whose placeholder cannot be resolved must be dropped, not written
# empty: `Authorization: Bearer ` is a malformed credential where no header at
# all means anonymous access.
t "an unresolvable header is omitted rather than left empty"
out="$(env -u CONTEXT7_API_KEY node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target claude --server context7)"
if printf '%s' "$out" | grep -q 'Bearer *"'; then nope "empty bearer written: $out"
else pass "no header"; fi

t "a resolvable header is still written"
out="$(CONTEXT7_API_KEY=example-key-value node "$REPO_DIR/scripts/lib/mcp-render.mjs" render --manifest "$MANIFEST" --target claude --server context7)"
printf '%s' "$out" | grep -q 'Bearer example-key-value' && pass || nope "$out"

# ------------------------------------------------- config ownership ----------
# The promise uninstall.sh makes is that a server the user configured stays
# theirs. That has to survive repeated syncs: the bug this guards against was
# recording a user-owned server as ours, so the *second* run overwrote it.
section "Config ownership"

OWN="$TMPROOT/own"
mkdir -p "$OWN"
cat > "$OWN/cfg.json" <<'EOF'
{ "mcp": { "context7": { "type": "local", "command": ["users","own","server"] } }, "theme": "dark" }
EOF
for _ in 1 2; do
  node "$REPO_DIR/scripts/lib/merge-config.mjs" apply \
    --config "$OWN/cfg.json" --mcp "$MANIFEST" --state "$OWN/state.json" \
    --servers context7,playwright >/dev/null 2>&1 || true
done

t "a user-owned MCP server survives two syncs untouched"
out="$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcp.context7.command||[]))' "$OWN/cfg.json")"
assert_eq '["users","own","server"]' "$out"

t "a user-owned server is never recorded as ours"
out="$(node -e 'process.stdout.write(String((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcp||[]).includes("context7")))' "$OWN/state.json")"
assert_eq "false" "$out"

t "a server we do own is still applied alongside it"
out="$(node -e 'process.stdout.write(String((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcp||[]).includes("playwright")))' "$OWN/state.json")"
assert_eq "true" "$out"

t "the user's unrelated config keys are preserved"
out="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).theme||"")' "$OWN/cfg.json")"
assert_eq "dark" "$out"

# ---------------------------------------------- credential bridge ------------
# install-mcps.sh writes the bridge under `set -e`. A trailing test that fails
# used to take the whole script — and so the last step of bootstrap.sh — with
# it, which is exactly what happens on a fresh machine with no .env at all.
section "Credential bridge"

t "install-mcps survives an environment with no keys set"
BR="$TMPROOT/bridge"
rc=0
env -u GITHUB_TOKEN -u CONTEXT7_API_KEY AI_DEV_LOCAL_STATE="$BR" \
  "$REPO_DIR/scripts/setup/install-mcps.sh" --agent __none__ >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc"

t "the bridge is written even when no credential exists"
[ -f "$BR/env.sh" ] && pass || nope "no bridge at $BR/env.sh"

t "the bridge holds no empty exports"
if [ -f "$BR/env.sh" ] && grep -qE '^export [A-Z_]+=$' "$BR/env.sh"; then nope "empty export written"
else pass; fi

# ------------------------------------------------------------ secret scanner --
section "Secret scanner"

# A throwaway git repository containing a copy of this one, so preflight runs
# against planted files without ever touching the real working tree.
SR="$TMPROOT/scanrepo"
mkdir -p "$SR"
( cd "$REPO_DIR" && tar cf - --exclude=.git --exclude=node_modules --exclude=state . ) | ( cd "$SR" && tar xf - )
( cd "$SR" && git init -q . && git config user.email t@example.com && git config user.name t )

# The fake credentials below are assembled from fragments on purpose. Written
# out whole they would be real matches for the very patterns being tested, and
# this file would then trip the scanner it exists to verify — which is exactly
# the failure mode a self-testing security check has to avoid.
FAKE_PAT="gh""p_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
FAKE_KEY="-----BEGIN OPENSSH PRIV""ATE KEY-----"
{ printf '%s\n' "$FAKE_PAT"; printf '%s\n' "$FAKE_KEY"; } > "$SR/planted.txt"
cat > "$SR/harmless.txt" <<'EOF'
Authorization: Bearer {env:CONTEXT7_API_KEY}
GITHUB_TOKEN=
password=<your-password>
token=${GITHUB_TOKEN}
EOF
( cd "$SR" && git add -A >/dev/null 2>&1 )

t "preflight blocks a planted credential with exit 4"
rc=0; ( cd "$SR" && ./scripts/git/preflight.sh --staged >"$TMPROOT/pf1.log" 2>&1 ) || rc=$?
assert_eq "4" "$rc"

t "the planted token is reported"
grep -q 'GitHub personal access token' "$TMPROOT/pf1.log" && pass || nope "not reported"

t "the planted private key is reported"
grep -q 'Private key block' "$TMPROOT/pf1.log" && pass || nope "not reported"

t "placeholders are not reported"
if grep -q 'harmless.txt' "$TMPROOT/pf1.log"; then nope "false positive in harmless.txt"; else pass; fi

t "the secret value itself is never printed"
if grep -qF "$FAKE_PAT" "$TMPROOT/pf1.log"; then nope "the token was echoed"; else pass; fi

t "preflight passes once the planted file is gone"
( cd "$SR" && rm -f planted.txt && git add -A >/dev/null 2>&1 )
rc=0; ( cd "$SR" && ./scripts/git/preflight.sh --staged >"$TMPROOT/pf2.log" 2>&1 ) || rc=$?
assert_eq "0" "$rc"

t "a staged .env is refused"
printf '%s\n' "SEC""RET=abcdefghijklmnop" > "$SR/.env"
( cd "$SR" && git add -f .env >/dev/null 2>&1 )
rc=0; ( cd "$SR" && ./scripts/git/preflight.sh --staged >"$TMPROOT/pf3.log" 2>&1 ) || rc=$?
assert_eq "4" "$rc"
( cd "$SR" && git rm -q --cached .env >/dev/null 2>&1 && rm -f .env )

# -------------------------------------------------------------------- hooks --
section "Git hooks"

t "commit-msg accepts a conventional subject"
printf 'feat: add a thing\n' > "$TMPROOT/msg"
if "$REPO_DIR/.githooks/commit-msg" "$TMPROOT/msg" >/dev/null 2>&1; then pass; else nope "rejected a valid message"; fi

t "commit-msg rejects a non-conventional subject"
printf 'did some stuff\n' > "$TMPROOT/msg"
if "$REPO_DIR/.githooks/commit-msg" "$TMPROOT/msg" >/dev/null 2>&1; then nope "accepted it"; else pass; fi

t "commit-msg rejects an empty message"
printf '\n' > "$TMPROOT/msg"
if "$REPO_DIR/.githooks/commit-msg" "$TMPROOT/msg" >/dev/null 2>&1; then nope "accepted an empty message"; else pass; fi

t "commit-msg allows a merge message"
printf 'Merge branch main\n' > "$TMPROOT/msg"
if "$REPO_DIR/.githooks/commit-msg" "$TMPROOT/msg" >/dev/null 2>&1; then pass; else nope "rejected a merge"; fi

t "commit-msg can be switched off"
printf 'whatever\n' > "$TMPROOT/msg"
if COMMIT_MESSAGE_CHECK=false "$REPO_DIR/.githooks/commit-msg" "$TMPROOT/msg" >/dev/null 2>&1; then pass; else nope "the opt-out did not work"; fi

t "a real commit is blocked by the pre-commit hook"
( cd "$SR" && git config core.hooksPath .githooks )
printf '%s\n' "gh""p_Z9y8X7w6V5u4T3s2R1q0P9o8N7m6L5k4J3i2" > "$SR/oops.txt"
( cd "$SR" && git add oops.txt >/dev/null 2>&1 )
rc=0; ( cd "$SR" && git commit -m "feat: try to commit a secret" >"$TMPROOT/hook.log" 2>&1 ) || rc=$?
if [ "$rc" != "0" ]; then pass "commit refused"; else nope "the commit went through"; fi

t "the same commit succeeds once the secret is removed"
( cd "$SR" && git rm -q --cached oops.txt >/dev/null 2>&1 && rm -f oops.txt && git add -A >/dev/null 2>&1 )
rc=0; ( cd "$SR" && git commit -m "feat: a clean commit" >"$TMPROOT/hook2.log" 2>&1 ) || rc=$?
assert_eq "0" "$rc"

# ------------------------------------------------------------- exit codes ----
section "Exit codes"

t "verify exits 5 on drift"
# A sandboxed HOME has none of the links, so drift is guaranteed.
rc=0
env HOME="$TMPROOT/emptyhome" XDG_CONFIG_HOME="$TMPROOT/emptyhome/.config" \
    XDG_DATA_HOME="$TMPROOT/emptyhome/.local/share" \
    OPENCODE_CONFIG_DIR="$TMPROOT/emptyhome/.config/opencode" \
    OPENCODE_DATA_DIR="$TMPROOT/emptyhome/.local/share/opencode" \
    CLAUDE_HOME="$TMPROOT/emptyhome/.claude" CODEX_HOME="$TMPROOT/emptyhome/.codex" \
    SKILLS_HOME="$TMPROOT/emptyhome/.agents/skills" BIN_DIR="$TMPROOT/emptyhome/.local/bin" \
    AI_DEV_LOCAL_STATE="$TMPROOT/emptyhome/.config/ai-dev-bootstrap" \
    "$REPO_DIR/scripts/context/verify.sh" --quiet >/dev/null 2>&1 || rc=$?
assert_eq "5" "$rc"

t "check exits 2 when problems remain and repairs are off"
rc=0
env HOME="$TMPROOT/emptyhome" XDG_CONFIG_HOME="$TMPROOT/emptyhome/.config" \
    XDG_DATA_HOME="$TMPROOT/emptyhome/.local/share" \
    OPENCODE_CONFIG_DIR="$TMPROOT/emptyhome/.config/opencode" \
    CLAUDE_HOME="$TMPROOT/emptyhome/.claude" CODEX_HOME="$TMPROOT/emptyhome/.codex" \
    SKILLS_HOME="$TMPROOT/emptyhome/.agents/skills" BIN_DIR="$TMPROOT/emptyhome/.local/bin" \
    AI_DEV_LOCAL_STATE="$TMPROOT/emptyhome/.config/ai-dev-bootstrap" \
    "$REPO_DIR/scripts/setup/check.sh" --no-repair >/dev/null 2>&1 || rc=$?
assert_eq "2" "$rc"

t "detect-local-install --path prints this repository"
assert_eq "$REPO_DIR" "$("$REPO_DIR/scripts/context/detect-local-install.sh" --path)"

t "--help exits 0 everywhere"
badhelp=""
for s in bootstrap.sh update.sh doctor.sh uninstall.sh \
         scripts/setup/setup.sh scripts/setup/check.sh scripts/setup/install-ssh.sh \
         scripts/setup/install-skills.sh scripts/setup/install-mcps.sh \
         scripts/setup/install-adapters.sh scripts/setup/install-commands.sh \
         scripts/setup/install-hooks.sh \
         scripts/git/preflight.sh scripts/git/commit.sh \
         scripts/context/verify.sh scripts/context/audit.sh \
         scripts/context/detect-local-install.sh scripts/context/behavior-check.sh; do
  "$REPO_DIR/$s" --help >/dev/null 2>&1 || badhelp="$badhelp $s"
done
[ -z "$badhelp" ] && pass || nope "--help failed for:$badhelp"

t "an unknown option is rejected"
badopt=""
for s in scripts/setup/check.sh scripts/context/verify.sh scripts/context/audit.sh scripts/git/preflight.sh; do
  "$REPO_DIR/$s" --definitely-not-an-option >/dev/null 2>&1 && badopt="$badopt $s"
done
[ -z "$badopt" ] && pass || nope "accepted a bogus option:$badopt"

# ---------------------------------------------------------------- dry runs ---
section "Dry runs"

# A pristine HOME, snapshotted before and after, is the only honest way to
# assert that --dry-run really changes nothing.
SBOX="$TMPROOT/dryhome"
mkdir -p "$SBOX/.config" "$SBOX/.local/bin" "$SBOX/.claude" "$SBOX/.codex"
sandbox_env() {
  env HOME="$SBOX" \
      XDG_CONFIG_HOME="$SBOX/.config" XDG_DATA_HOME="$SBOX/.local/share" \
      OPENCODE_CONFIG_DIR="$SBOX/.config/opencode" OPENCODE_DATA_DIR="$SBOX/.local/share/opencode" \
      CLAUDE_HOME="$SBOX/.claude" CODEX_HOME="$SBOX/.codex" \
      SKILLS_HOME="$SBOX/.agents/skills" BIN_DIR="$SBOX/.local/bin" \
      AI_DEV_LOCAL_STATE="$SBOX/.config/ai-dev-bootstrap" \
      SHELL=/bin/bash "$@"
}
snapshot() { find "$SBOX" 2>/dev/null | sort; }

before="$(snapshot)"
t "bootstrap --dry-run changes nothing in a sandboxed HOME"
sandbox_env "$REPO_DIR/bootstrap.sh" --dry-run --skip-skills >"$TMPROOT/dry.log" 2>&1 || true
after="$(snapshot)"
if [ "$before" = "$after" ]; then pass
else nope "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5 | tr '\n' ' ')"; fi

t "bootstrap --dry-run reports what it would do"
grep -q 'WOULD' "$TMPROOT/dry.log" && pass || nope "no WOULD lines in the output"

t "update --dry-run changes nothing"
before="$(snapshot)"
sandbox_env "$REPO_DIR/update.sh" --dry-run --no-pull >"$TMPROOT/dry2.log" 2>&1 || true
after="$(snapshot)"
[ "$before" = "$after" ] && pass || nope "the sandbox changed"

t "check --dry-run changes nothing"
before="$(snapshot)"
sandbox_env "$REPO_DIR/scripts/setup/check.sh" --dry-run >"$TMPROOT/dry3.log" 2>&1 || true
after="$(snapshot)"
[ "$before" = "$after" ] && pass || nope "the sandbox changed"

t "uninstall --dry-run changes nothing"
before="$(snapshot)"
sandbox_env "$REPO_DIR/uninstall.sh" --dry-run >"$TMPROOT/dry4.log" 2>&1 || true
after="$(snapshot)"
[ "$before" = "$after" ] && pass || nope "the sandbox changed"

t "audit --no-report writes no report"
rm -f "$STATE_DIR/audit-last.txt"
"$REPO_DIR/scripts/context/audit.sh" --no-report >/dev/null 2>&1 || true
if [ -f "$STATE_DIR/audit-last.txt" ]; then nope "it wrote one anyway"; else pass; fi

# --------------------------------------------------------- sandbox install ---
if [ "$MUTATE" = "1" ]; then
  section "Sandboxed install"
  # Skills and MCP are skipped: both need the network, and neither is what this
  # test is about. What it proves is that the link/command/hook layer converges.
  t "setup runs to completion in a throwaway HOME"
  rc=0
  sandbox_env "$REPO_DIR/scripts/setup/setup.sh" --skip-skills --skip-mcp --no-shell-rc \
    >"$TMPROOT/install.log" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then pass
  else nope "exit $rc — $(tail -3 "$TMPROOT/install.log" | tr '\n' ' ')"; fi

  t "the OpenCode rules link was created and points at the repo"
  l="$SBOX/.config/opencode/$MANAGED_NAME/global.md"
  if [ -L "$l" ] && [ "$(link_target "$l")" = "$REPO_DIR/rules/global.md" ]; then pass
  else nope "state: $(link_state "$REPO_DIR/rules/global.md" "$l")"; fi

  t "the Claude Code rules link was created"
  l="$SBOX/.claude/rules/ai-dev-global.md"
  if [ -L "$l" ] && [ "$(link_target "$l")" = "$REPO_DIR/rules/global.md" ]; then pass
  else nope "state: $(link_state "$REPO_DIR/rules/global.md" "$l")"; fi

  t "the Codex rules block was written into AGENTS.md"
  if [ -f "$SBOX/.codex/AGENTS.md" ] && grep -q 'ai-dev-bootstrap' "$SBOX/.codex/AGENTS.md"; then pass
  else nope "no block in AGENTS.md"; fi

  t "all five commands were installed and are executable"
  missing_cmd=""
  while IFS='|' read -r name _; do
    [ -n "$name" ] || continue
    [ -x "$SBOX/.local/bin/$name" ] || missing_cmd="$missing_cmd $name"
  done < <(ai_dev_commands)
  [ -z "$missing_cmd" ] && pass || nope "missing:$missing_cmd"

  t "the wrappers point back at this repository"
  if grep -q "REPO=\"$REPO_DIR\"" "$SBOX/.local/bin/ai-dev-doctor"; then pass
  else nope "$(grep '^REPO=' "$SBOX/.local/bin/ai-dev-doctor" || true)"; fi

  t "the real HOME was untouched"
  # The one thing this whole sandbox exists to guarantee.
  if [ -e "$HOME/.config/opencode/$MANAGED_NAME/global.md" ] && [ ! -L "$HOME/.config/opencode/$MANAGED_NAME/global.md" ]; then
    nope "something appeared in the real HOME"
  else pass; fi

  # Timestamped backups are excluded: creating one when the config actually
  # changed is the intended behaviour, not drift. The separate test below is
  # what proves they stop being created once the state has settled.
  live_state() { find "$SBOX" \( -type f -o -type l \) 2>/dev/null | grep -v '\.backup-' | sort; }

  t "a second run changes no live state (idempotency)"
  snap1="$(live_state)"
  sandbox_env "$REPO_DIR/scripts/setup/setup.sh" --skip-skills --skip-mcp --no-shell-rc \
    >"$TMPROOT/install2.log" 2>&1 || true
  snap2="$(live_state)"
  if [ "$snap1" = "$snap2" ]; then pass
  else nope "$(diff <(printf '%s\n' "$snap1") <(printf '%s\n' "$snap2") | head -5 | tr '\n' ' ')"; fi

  t "backups stop accumulating once the config has settled"
  b1="$(find "$SBOX/.config" -maxdepth 1 -name 'opencode.backup-*' 2>/dev/null | wc -l | tr -d ' ')"
  sandbox_env "$REPO_DIR/scripts/setup/setup.sh" --skip-skills --skip-mcp --no-shell-rc \
    >"$TMPROOT/install3.log" 2>&1 || true
  b2="$(find "$SBOX/.config" -maxdepth 1 -name 'opencode.backup-*' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$b1" "$b2" "$b2 backup(s), unchanged"

  t "the rc block is written exactly once across three runs"
  sandbox_env "$REPO_DIR/scripts/setup/install-commands.sh" >/dev/null 2>&1 || true
  sandbox_env "$REPO_DIR/scripts/setup/install-commands.sh" >/dev/null 2>&1 || true
  sandbox_env "$REPO_DIR/scripts/setup/install-commands.sh" >/dev/null 2>&1 || true
  n="$(grep -c "$BLOCK_BEGIN" "$SBOX/.bashrc" 2>/dev/null | tr -d ' ' || echo 0)"
  assert_eq "1" "$n"

  t "a deliberately broken link is repaired by check"
  rm -f "$SBOX/.claude/rules/ai-dev-global.md"
  ln -s "$SBOX/nowhere" "$SBOX/.claude/rules/ai-dev-global.md"
  sandbox_env "$REPO_DIR/scripts/setup/check.sh" >"$TMPROOT/repair.log" 2>&1 || true
  l="$SBOX/.claude/rules/ai-dev-global.md"
  if [ "$(link_target "$l" 2>/dev/null)" = "$REPO_DIR/rules/global.md" ]; then pass "self-healed"
  else nope "still $(readlink "$l" 2>/dev/null)"; fi

  t "a deleted command is reinstalled by check"
  rm -f "$SBOX/.local/bin/ai-dev-doctor"
  sandbox_env "$REPO_DIR/scripts/setup/check.sh" >"$TMPROOT/repair2.log" 2>&1 || true
  [ -x "$SBOX/.local/bin/ai-dev-doctor" ] && pass "self-healed" || nope "not restored"

  t "check reports healthy after repairing"
  rc=0
  sandbox_env "$REPO_DIR/scripts/setup/check.sh" >"$TMPROOT/repair3.log" 2>&1 || rc=$?
  if [ "$rc" = "0" ]; then pass
  else nope "exit $rc — $(grep '^✗' "$TMPROOT/repair3.log" | head -3 | tr '\n' ' ')"; fi

  t "uninstall removes the links it created"
  sandbox_env "$REPO_DIR/uninstall.sh" --yes >"$TMPROOT/uninstall.log" 2>&1 || true
  left=""
  [ -L "$SBOX/.claude/rules/ai-dev-global.md" ] && left="$left claude-rules"
  [ -e "$SBOX/.local/bin/ai-dev-doctor" ] && left="$left ai-dev-doctor"
  [ -d "$SBOX/.config/ai-dev-bootstrap" ] && left="$left local-state"
  [ -z "$left" ] && pass || nope "left behind:$left"
else
  section "Sandboxed install"
  info "skipped — pass --mutate to run the install tests in a throwaway HOME"
fi

# ----------------------------------------------------------------- summary ---
section "Summary"
printf '%s\n' "${C_GREEN}$PASS passed${C_RESET}"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "${C_RED}$FAIL failed${C_RESET}"
  printf '\n'
  exit "$EX_FAIL"
fi
printf '%s\n' "0 failed"
printf '\n'
exit "$EX_OK"

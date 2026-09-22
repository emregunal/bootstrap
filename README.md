# ai-dev-bootstrap

Personal **AI Development Environment Manager**.

Keeps skills, MCP servers, global agent rules and helper commands for
OpenCode, Claude Code and Codex in a single repository; installs them on a new
machine with one command, verifies the installation and repairs itself when
something breaks.

```bash
git clone https://github.com/emregunal/bootstrap.git ~/ai-dev-bootstrap
cd ~/ai-dev-bootstrap
./bootstrap.sh
```

WSL Ubuntu and Linux are the primary targets; macOS is fully supported. Native
Windows Git Bash is recognized and the basic install/health commands work;
because of Windows' POSIX symlink and file-mode limitations, WSL is recommended
for full behavior.

---

## Table of contents

- [Core idea](#core-idea)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Installing on a new machine (step by step)](#installing-on-a-new-machine-step-by-step)
- [Using it in a new project](#using-it-in-a-new-project)
- [Global commands](#global-commands)
- [Scripts: purpose, call graph, read-only / mutating](#scripts)
- [Adapter system](#adapter-system)
- [Skill management](#skill-management)
- [MCP management](#mcp-management)
- [Global rules](#global-rules)
- [Secret safety](#secret-safety)
- [Git hooks](#git-hooks)
- [Commit and push workflow](#commit-and-push-workflow)
- [Self-healing: what it repairs, what it does not](#self-healing)
- [Dry-run and verbose](#dry-run-and-verbose)
- [Exit code standard](#exit-code-standard)
- [Testing](#testing)
- [CI](#ci)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)

---

## Core idea

```
GitHub repository  =  desired configuration (desired state)
Local machine      =  runtime state + credentials
```

GitHub knows: which skills get installed, which MCP servers are defined,
which rules apply, which config is expected.

GitHub **never** knows: API keys, OAuth tokens, private SSH keys, database
passwords, session credentials.

This separation is the single rule that governs the whole repository.
`preflight.sh`, `.gitignore`, `.githooks/pre-commit` and the secret job in CI
enforce it mechanically — it is not left to good intentions.

---

## Architecture

```
                        GitHub
                   ai-dev-bootstrap
                          │
              ┌───────────┼───────────┐
              │           │           │
           Skills        MCP        Rules
        skills/*.conf  mcps.json  rules/global.md
              │           │           │
              └───────────┼───────────┘
                          │
                      Adapters
              adapters/<agent>/adapter.sh
              ┌───────────┼───────────┐
              ▼           ▼           ▼
          OpenCode   Claude Code    Codex
              │           │           │
              └───────────┼───────────┘
                          │
                    Local machine
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
     check.sh         verify.sh         audit.sh
     (repairs)       (only looks)     (deep audit)
                          │
                     self-healing
```

The knowledge of how each agent is configured lives **only** in its own
adapter. Adding a new agent means writing `adapters/<name>/adapter.sh`; no
other file changes.

---

## Repository layout

```text
ai-dev-bootstrap/
├── bootstrap.sh              # installer (execs scripts/setup/setup.sh)
├── update.sh                 # ai-dev-sync
├── doctor.sh                 # ai-dev-doctor
├── uninstall.sh              # reverts what was installed
├── .env.example              # secret template (the real .env is never committed)
├── .gitattributes            # keeps text files LF on Windows checkouts
├── .gitignore
│
├── rules/
│   └── global.md             # the single rules file distributed to all agents
│
├── skills/
│   ├── profiles.conf         # profile → manifest mapping
│   ├── frontend.conf
│   ├── backend.conf
│   ├── database.conf
│   ├── devops.conf
│   ├── testing.conf
│   ├── security.conf
│   ├── ecc.conf              # ECC's full skill catalog
│   ├── caveman.conf          # Caveman skill bundle
│   └── research.conf         # up-to-date research skills
│
├── mcp/
│   └── mcps.json             # MCP server manifest (single source)
│
├── config/
│   ├── shared/               # symlinked into every agent
│   ├── opencode/             # OpenCode only
│   ├── claude/               # Claude Code only
│   └── codex/                # Codex only
│
├── adapters/
│   ├── opencode/adapter.sh
│   ├── claude-code/adapter.sh
│   └── codex/adapter.sh
│
├── scripts/
│   ├── lib/
│   │   ├── common.sh              # paths, exit codes, symlink/block primitives
│   │   ├── logging.sh             # all output goes through here
│   │   ├── platform.sh            # Linux / WSL / macOS / Windows differences
│   │   ├── merge-config.mjs       # surgically edits the OpenCode config
│   │   ├── mcp-render.mjs         # manifest → agent dialect translation
│   │   └── secret-patterns.conf   # secret scanning patterns
│   │
│   ├── setup/
│   │   ├── setup.sh               # main orchestrator
│   │   ├── check.sh               # health check + self-heal (ai-dev-check)
│   │   ├── install-adapters.sh    # rules + config fragments
│   │   ├── install-commands.sh    # ~/.local/bin wrappers + PATH
│   │   ├── install-hooks.sh       # core.hooksPath
│   │   ├── install-skills.sh      # skill installation
│   │   ├── install-mcps.sh        # credential bridge + MCP
│   │   └── install-ssh.sh         # SSH/GitHub helper
│   │
│   ├── git/
│   │   ├── preflight.sh           # commit/push safety gate
│   │   └── commit.sh              # safe commit workflow
│   │
│   └── context/
│       ├── verify.sh              # drift detection (ai-dev-verify)
│       ├── audit.sh               # deep audit (ai-dev-audit)
│       ├── behavior-check.sh      # behavior tests
│       └── detect-local-install.sh# detects the install location
│
├── .githooks/
│   ├── pre-commit
│   └── commit-msg
│
├── .github/workflows/
│   └── validate.yml
│
└── state/                    # machine-specific output — in .gitignore
    └── .gitkeep
```

---

## Installing on a new machine (step by step)

### 1. System dependencies

**WSL Ubuntu / Debian / Ubuntu:**

```bash
sudo apt update
sudo apt install -y git curl build-essential

# Node.js LTS
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# verify
git --version && node --version && npm --version && npx --version
```

**macOS:**

```bash
xcode-select --install          # for git (skips if already present)
brew install node
```

Required: `git`, `node`, `npm`, `npx`. If any is missing, `bootstrap.sh`
stops with exit code **3** and prints the full install command.

### 2. Install at least one AI agent

You do not need all three; **at least one** must be present. An agent that is
not installed is skipped silently.

```bash
# OpenCode
curl -fsSL https://opencode.ai/install | bash

# Claude Code
curl -fsSL https://claude.ai/install.sh | bash

# Codex
npm install -g @openai/codex
```

Verify:

```bash
opencode --version ; claude --version ; codex --version
```

### 3. Clone the repository

```bash
git clone https://github.com/emregunal/bootstrap.git ~/ai-dev-bootstrap
cd ~/ai-dev-bootstrap
```

> Directory name and location are up to you. No script hard-codes a path;
> everything derives from the symlink-resolving detection in
> `scripts/lib/common.sh`. If you move the repo later, `ai-dev-check` notices
> and repairs the wrappers.

### 4. Prepare secrets (optional but recommended)

`.env` **is not in the repository** and never will be. It is created by hand
on every machine:

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

| Variable | Required | Purpose |
|---|---|---|
| `CONTEXT7_API_KEY` | no | Raises the Context7 rate limit; works without a key too |
| `GITHUB_TOKEN` | yes, for the GitHub MCP | If missing the server is written as `enabled: false`, no error |
| `MCP_FILESYSTEM_ROOT` | no | Root directory of the Filesystem MCP (default `$HOME`) |

Installation completes without a `.env`. Servers that need a key are
configured but cannot authenticate; `ai-dev-doctor` shows this as a
**warning**, not an error.

### 5. Try first, then install

See what would happen without changing anything:

```bash
./bootstrap.sh --dry-run
```

The output consists of `WOULD CREATE`, `WOULD LINK`, `WOULD INSTALL`,
`WOULD CONFIGURE` lines. In this mode not a single file is written — this
behavior is tested in `behavior-check.sh` with a snapshot comparison.

Then install for real:

```bash
./bootstrap.sh
```

If you only want a specific profile:

```bash
./bootstrap.sh --profile frontend
```

### 6. Reload the shell

```bash
exec $SHELL -l
# or
source ~/.bashrc     # ~/.zshrc if you use zsh
```

This step is required: this is when `~/.local/bin` enters your PATH and the
credential bridge (`~/.config/ai-dev-bootstrap/env.sh`) enters the shell
environment.

### 7. Verify

```bash
ai-dev-doctor
```

Expected last line: `✓ Everything checks out`.

Deeper check:

```bash
ai-dev-doctor --full     # check + verify + audit + behavior tests
```

### 8. (Optional) SSH and GitHub

```bash
./scripts/setup/install-ssh.sh
```

This script **never generates or modifies private keys**. It checks that
`~/.ssh` exists, its permissions, existing public keys, the `known_hosts`
state and the GitHub connection. If you want to generate a key it prints the
command for you:

```bash
ssh-keygen -t ed25519 -C "you@example.com"
cat ~/.ssh/id_ed25519.pub          # add it at https://github.com/settings/keys
```

Fixing permissions and creating `~/.ssh` require explicit flags:

```bash
./scripts/setup/install-ssh.sh --fix-perms --add-host
```

### The whole installation in one block

```bash
# 1. dependencies (steps 1 and 2 above)
# 2. repo
git clone https://github.com/emregunal/bootstrap.git ~/ai-dev-bootstrap
cd ~/ai-dev-bootstrap

# 3. secrets
cp .env.example .env && chmod 600 .env && $EDITOR .env

# 4. preview + install
./bootstrap.sh --dry-run
./bootstrap.sh

# 5. shell
exec $SHELL -l

# 6. verification
ai-dev-doctor
```

---

## Using it in a new project

This repository works at the **machine level**. After installation, every
project you open inherits the following with no extra steps:

- the rules in `rules/global.md` (in effect in all three agents)
- the installed skills (under `~/.agents/skills`, symlinked into the agent directories)
- the defined MCP servers

When starting a new project:

```bash
mkdir ~/dev/new-project && cd ~/dev/new-project
git init

# start the agent — global rules and skills are loaded automatically
opencode      # or: claude / codex
```

**If you want project-specific additions:** the global rules are the baseline
default; the project's own `AGENTS.md` / `CLAUDE.md` takes precedence. In
other words, creating an `AGENTS.md` at the project root does not override the
global rules, it layers on top of them.

**If you want to use this repository's security tooling in another project**
there are two ways:

```bash
# 1) Call it directly (it scans its own repo, so run it from inside that repo)
cd ~/dev/new-project
~/ai-dev-bootstrap/scripts/git/preflight.sh --secrets-only

# 2) Install it as that project's hook
cd ~/dev/new-project
mkdir -p .githooks
cat > .githooks/pre-commit <<'EOF'
#!/usr/bin/env bash
exec ~/ai-dev-bootstrap/scripts/git/preflight.sh --staged
EOF
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
```

> Note: `preflight.sh` resolves its own repository root through `common.sh`
> and `cd`s there. To scan another project, copy it into that project or write
> a thin wrapper as shown above.

---

## Global commands

After installation, five commands land in `~/.local/bin`. They are not
symlinks but **wrappers**: they store the repository path inside themselves,
so they work from whichever directory you call them and give a clear error if
the repo has moved (`ai-dev-check` repairs this automatically).

| Command | What it does | Modifies the system |
|---|---|---|
| `ai-dev-doctor` | Full health report (check + verify) | **no** |
| `ai-dev-doctor --full` | + audit + behavior tests | **no** |
| `ai-dev-check` | Checks and repairs what is safe to repair | **yes** (only its own files) |
| `ai-dev-verify` | Reports the drift between the repo and the machine | **no** |
| `ai-dev-audit` | Deep audit + `state/audit-last.txt` report | **no** |
| `ai-dev-sync` | Pulls the repo and re-applies everything | **yes** |

---

## Scripts

### Purpose of each `.sh` file

| File | Purpose | Read-only? |
|---|---|---|
| `bootstrap.sh` | Entry point; `exec`s into `setup.sh` | mutates |
| `update.sh` | `git pull --ff-only` + re-applies the whole installation | mutates |
| `doctor.sh` | check + verify (+ audit + tests with `--full`) | **read-only** |
| `uninstall.sh` | Reverts everything that was installed | mutates |
| `scripts/setup/setup.sh` | 8-step installation orchestration | mutates |
| `scripts/setup/check.sh` | Health check + safe self-heal | mutates (repair) |
| `scripts/setup/install-adapters.sh` | Rules + config fragment for each agent | mutates |
| `scripts/setup/install-commands.sh` | `~/.local/bin` wrappers + rc block | mutates |
| `scripts/setup/install-hooks.sh` | `git config core.hooksPath .githooks` | mutates |
| `scripts/setup/install-skills.sh` | Skill installation via the `skills` CLI | mutates |
| `scripts/setup/install-mcps.sh` | Credential bridge + MCP into the adapters | mutates |
| `scripts/setup/install-ssh.sh` | SSH status; report only without flags | **read-only** (without flags) |
| `scripts/git/preflight.sh` | Safety gate: secrets, conflicts, syntax | **read-only** |
| `scripts/git/commit.sh` | preflight → commit → (optional) push | mutates (git) |
| `scripts/context/verify.sh` | Drift detection | **read-only** |
| `scripts/context/audit.sh` | Deep audit + report file | **read-only** (+report) |
| `scripts/context/behavior-check.sh` | Behavior tests | **read-only** (except `--mutate`) |
| `scripts/context/detect-local-install.sh` | Resolves the repo root and install location | **read-only** |
| `scripts/lib/common.sh` | Paths, exit codes, symlink/block primitives | sourced |
| `scripts/lib/logging.sh` | `info/success/warn/error/die/section` + redaction | sourced |
| `scripts/lib/platform.sh` | Wrappers for `readlink -f`, `sed -i`, `stat`, `sha256sum` | sourced |
| `adapters/*/adapter.sh` | Agent-specific install/verification | mutates (`apply`) |
| `.githooks/pre-commit` | Runs `preflight.sh --staged` | **read-only** |
| `.githooks/commit-msg` | Commit message quality check | **read-only** |

### Call graph

```
bootstrap.sh
   └── scripts/setup/setup.sh
         ├── install-adapters.sh ──► adapters/*/adapter.sh apply
         ├── install-commands.sh
         ├── install-hooks.sh
         ├── install-skills.sh
         ├── install-mcps.sh ──────► adapters/*/adapter.sh mcp-apply
         └── check.sh

update.sh (ai-dev-sync)
   ├── git pull --ff-only
   ├── install-adapters.sh
   ├── install-commands.sh
   ├── install-hooks.sh
   ├── install-skills.sh
   ├── install-mcps.sh
   ├── verify.sh
   └── check.sh

doctor.sh (ai-dev-doctor)
   ├── check.sh --no-repair
   ├── verify.sh
   └── with --full: audit.sh + behavior-check.sh

commit.sh
   └── preflight.sh --staged
         ├── merge conflict scan
         ├── secret scan
         ├── shell syntax (bash -n)
         └── JSON validation

audit.sh
   ├── verify.sh --quiet
   ├── preflight.sh --secrets-only
   ├── symlink sweep
   ├── permissions
   └── manifest validation

check.sh
   └── adapters/*/adapter.sh plan   (list of symlinks to repair)
```

There are no circular dependencies. `scripts/lib/*` calls nothing; adapters
depend only on `lib`; orchestrators depend on adapters and `lib`.

### Read-only scripts

`doctor.sh`, `verify.sh`, `preflight.sh`, `detect-local-install.sh`,
`behavior-check.sh` (default), `install-ssh.sh` (without flags),
`check.sh --no-repair`, `audit.sh` (only writes `state/audit-last.txt`).

### Scripts that modify the system

`bootstrap.sh`, `setup.sh`, `update.sh`, `install-*.sh`, `check.sh`
(default, repair mode), `commit.sh`, `uninstall.sh`,
`adapter.sh apply|mcp-apply|remove`, `behavior-check.sh --mutate`
(only inside a temporary `HOME`).

---

## Adapter system

Every adapter implements the same eight subcommands:

| Subcommand | What it returns |
|---|---|
| `label` | Human-readable name |
| `detect` | Whether the agent is installed (exit 0/1) |
| `paths` | `KEY=VALUE` lines |
| `plan` | `LINK\|src\|dest\|description` / `BLOCK\|file\|description` |
| `apply` | Installs the rules + config fragments |
| `mcp-apply` | Installs the MCP servers |
| `verify` | `OK\|MISS\|DRIFT\|WARN\|SKIP` lines, exit 5 if there is drift |
| `remove` | Reverts what it installed |

The `plan` output is declarative: `check.sh` reads this list and repairs
broken symlinks, `verify.sh` reads the same list and reports, `uninstall.sh`
reads the same list and cleans up. One source, three consumers.

### What gets written to each agent

| Agent | Rules | MCP |
|---|---|---|
| **OpenCode** | `~/.config/opencode/ai-dev-bootstrap/global.md` (symlink) + an entry in the config's `instructions` array | Merged into the `mcp` block; secrets are resolved **at runtime** as `{env:VAR}` |
| **Claude Code** | `~/.claude/rules/ai-dev-global.md` (symlink) — the file is not edited, the link itself is the integration point | Via `claude mcp add-json -s user`; `~/.claude.json` is never touched by hand |
| **Codex** | A marked block inside `~/.codex/AGENTS.md` (Codex does not support includes) | A marked `[mcp_servers.*]` block inside `~/.codex/config.toml`; the TOML is validated after writing and **rolled back** if broken |

### Adding a new agent

```bash
mkdir -p adapters/new-agent
cp adapters/claude-code/adapter.sh adapters/new-agent/adapter.sh
$EDITOR adapters/new-agent/adapter.sh
```

You do not need to change any other file — `adapter_list()` scans the
directory.

---

## Skill management

Format: `owner/repo|skill-name`. To install every skill in a repository, use
`*` instead of `skill-name`.

```conf
# skills/frontend.conf
anthropics/skills|frontend-design
vercel-labs/agent-skills|vercel-react-best-practices
affaan-m/ECC|*
```

`skill-name` must match the `name:` field in the skill's `SKILL.md`; this is
not always the same as the folder name.

Profiles live in `skills/profiles.conf`:

```conf
frontend|frontend
backend|backend,database
ecc|ecc
caveman|caveman
research|research
full|frontend,backend,database,devops,testing,security,ecc,caveman,research
```

```bash
./bootstrap.sh --profile backend      # backend + database
./bootstrap.sh --profile ecc          # the whole ECC skill catalog
./bootstrap.sh --profile caveman      # the whole Caveman skill bundle
./bootstrap.sh --profile research     # research skills such as last30days
ai-dev-sync --profile frontend
ai-dev-sync --refresh-skills          # re-download installed ones as well
```

Skills are kept once under `~/.agents/skills`; the `skills` CLI symlinks them
into each agent's own directory. That is why a single installation covers all
three agents. Broken symlinks are reported by `ai-dev-check`.

---

## MCP management

Single manifest: `mcp/mcps.json`. It is written in the OpenCode schema (the
richest of the three); `scripts/lib/mcp-render.mjs` translates it into the
other dialects.

```json
{
  "servers": {
    "context7": {
      "optionalEnv": ["CONTEXT7_API_KEY"],
      "config": {
        "type": "remote",
        "url": "https://mcp.context7.com/mcp",
        "enabled": true,
        "headers": { "Authorization": "Bearer {env:CONTEXT7_API_KEY}" }
      }
    }
  }
}
```

**Two kinds of placeholder:**

| Placeholder | When it is resolved | Used for |
|---|---|---|
| `{env:VAR}` | By OpenCode **at runtime** | Secrets — the value is never written to any config file |
| `{install:VAR}` | During installation | Machine-specific paths, ports |

**Two metadata fields:**

- `requiresEnv` — the server cannot run without this variable. In OpenCode it
  is written as `enabled: false`; in Claude Code and Codex the server is not
  added at all. Once you provide the key and run `ai-dev-sync`, it activates.
- `optionalEnv` — the server works without the key too (anonymous / lower
  rate limit). It is never disabled, only a warning is emitted.

A missing key **is not an error**; installation completes.

To add a new server, add an entry under `servers` — nothing else changes.

---

## Global rules

`rules/global.md` is the single source and the same content goes to all three
agents. This is the file to edit; the copies in the agent directories are
generated.

```bash
$EDITOR rules/global.md
ai-dev-sync
```

Because OpenCode and Claude Code use symlinks, it takes effect the moment you
save the file. In Codex the block is re-rendered; `ai-dev-check` notices the
content difference and refreshes the block (this repair is risk-free, since it
only touches the marked region it wrote itself).

You can distribute extra content per agent by dropping additional files into
`config/shared/` and `config/<agent>/`; see `config/README.md` for details.

---

## Secret safety

Five layers:

**1. `.gitignore`** — `.env`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`,
`credentials.json`, `secrets.json`, `auth.json`, `.netrc` and all backup
files.

**2. Secret scanner** (`scripts/lib/secret-patterns.conf`) — GitHub PATs,
OpenAI/Anthropic-style keys, Google API keys, Slack tokens, AWS access keys,
Context7 keys, private key blocks, literal Bearer tokens, credential
assignments carrying a value, connection strings with embedded credentials.

The patterns look for the **shape** of a credential, not its prefix: a bare
`sk-` in plain text is not a finding, `sk-` followed by twenty key characters
is. Matched text is additionally passed through a placeholder allowlist —
`{env:VAR}`, `$VAR`, `<your-token>` and the empty assignments in
`.env.example` never produce a finding.

> When a finding is reported **the value is never printed**; only `file:line`
> and the pattern name are shown. No mode, including `--verbose`, prints
> secrets.

**3. Dangerous file check** — staged and tracked files are scanned by name;
if a file such as `.env` has made it into git, it is reported with a
`git rm --cached` suggestion.

**4. Credential bridge** — the values in `.env` are written to
`~/.config/ai-dev-bootstrap/env.sh` with **mode 600** and sourced by the login
shell. That way OpenCode resolves `{env:VAR}` from its own process
environment; the key is never written to any config file.

> The user-scope MCP definitions of Claude Code and Codex have no runtime
> placeholder support. For these two agents the key is resolved at install
> time and written to the **local** config file. The script warns about this
> explicitly and keeps `config.toml` at 600. These files never enter the
> repository.

**5. Git hooks + CI** — `preflight.sh --staged` on every commit,
`preflight.sh --secrets-only` plus a tracked-credential-file check in CI on
every push.

---

## Git hooks

`.git/hooks` cannot be committed, so the hooks are versioned under
`.githooks/` and git is pointed there:

```bash
git config core.hooksPath .githooks
```

`scripts/setup/install-hooks.sh` runs this line; `bootstrap.sh` and
`ai-dev-sync` do it automatically, and `ai-dev-check` puts it back if it
breaks.

The path is given **relative**; git resolves it from the working tree root,
so the setting survives moving the repo.

### pre-commit

Runs `preflight.sh --staged`: staged content only, no network access, no
heavy integrity scan. A critical finding blocks the commit.

### commit-msg

Performs a Conventional Commit check: `feat fix docs style refactor perf test
build ci chore revert`. Merge/revert/fixup messages are exempt. A long subject
produces a warning but does not block.

To turn it off:

```bash
git config ai-dev.commitMessageCheck false     # permanent
COMMIT_MESSAGE_CHECK=false git commit -m "..."  # one-off
```

To skip all hooks in an emergency: `git commit --no-verify`.

---

## Commit and push workflow

```bash
git add <the-files-you-want>
./scripts/git/commit.sh "feat: add backend skills"
```

Flow: staged check → preflight → commit → log.

- `git add .` is **never** run; you decide what to stage.
- If nothing is staged it says `Nothing staged for commit.` and stops.
- If preflight finds a secret, no commit is made, exit **4**.

Push:

```bash
./scripts/git/commit.sh "feat: ..." --push
```

With `--push`, the **full** preflight runs again after the commit (not
staged, all tracked files). If it is not clean, no push is made.

---

## Self-healing

`ai-dev-check` performs only **risk-free** repairs:

| Repairs | Does not repair |
|---|---|
| Missing/broken/wrongly targeted symlinks (that it owns) | A path where a real file sits — only warns |
| A deleted `~/.local/bin` wrapper | A wrapper the user wrote themselves |
| A wrapper pointing at another clone | User config or credentials |
| The `core.hooksPath` setting | MCP servers the user added |
| Its own script that lost its executable bit | `.env` or `auth.json` |
| Dead symlinks inside its own managed directory | Dead symlinks outside the managed directory (reports them) |
| Its own missing directories | The agents' own files |

To look without repairing:

```bash
ai-dev-check --no-repair     # report only
ai-dev-check --dry-run       # show what it would repair
```

---

## Dry-run and verbose

Every script that supports `--dry-run` touches no file:

```bash
./bootstrap.sh --dry-run
./update.sh --dry-run
./scripts/setup/check.sh --dry-run
./uninstall.sh --dry-run
```

This behavior is tested: `behavior-check.sh` creates a temporary `HOME`,
compares the before/after file listing and fails the test if it finds a single
difference.

Verbose:

```bash
./bootstrap.sh --verbose
DEBUG=1 ai-dev-check
```

Even in verbose mode, secret values are not printed.

---

## Exit code standard

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error |
| 2 | Config problem (unparseable file, missing structure) |
| 3 | Missing dependency |
| 4 | Security / preflight problem |
| 5 | Drift found |

CI and the git hooks branch on these codes. Example:

```bash
ai-dev-verify
case $? in
  0) echo "in sync" ;;
  5) ai-dev-sync ;;
  *) echo "needs a look" ;;
esac
```

---

## Testing

```bash
./scripts/context/behavior-check.sh            # read-only behavior tests
./scripts/context/behavior-check.sh --mutate   # + full install in a temporary HOME
./doctor.sh --full                             # everything
```

The `--mutate` tests run the real installers, but against a **disposable
`HOME` directory**: that your real home directory is untouched is itself
verified as one of the tests. What is tested includes the symlink primitives,
block idempotency, the adapter contracts, the validity of the MCP render
outputs, that the secret scanner both catches secrets and produces no false
positives, that the hooks block a real commit, exit codes, that dry-runs change
nothing, that installation is idempotent, and that a deliberately broken link
is repaired.

Shell syntax and lint:

```bash
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;
shellcheck -x -S warning $(find . -name '*.sh' -not -path './.git/*') .githooks/*
```

If ShellCheck is not installed, nothing is blocked.

---

## CI

`.github/workflows/validate.yml` runs five jobs:

| Job | What it checks |
|---|---|
| `shell` | `bash -n`, ShellCheck (warning level), every script's `--help` |
| `manifests` | JSON/YAML parse, skill manifest format, profile integrity, validity of the MCP render for every target |
| `security` | Secret scan over tracked files, credential file check |
| `behaviour` | Behavior tests (read-only) + that dry-run does not modify `HOME` |
| `macos` | The same tests on macOS (bash 3.2 + BSD userland compatibility) |

CI asks for no credentials and modifies no real user home directory.

---

## Troubleshooting

**`ai-dev-doctor: command not found`**

```bash
exec $SHELL -l          # PATH has not been reloaded yet
echo $PATH | tr ':' '\n' | grep '.local/bin'
```

**I moved the repo, the commands broke**

```bash
cd /new/location/ai-dev-bootstrap
./bootstrap.sh          # rewrites the wrappers for the new path
# or just:
./scripts/setup/check.sh
```

**`ai-dev-verify` shows drift**

```bash
ai-dev-verify           # shows what drifted
ai-dev-sync             # applies the repo state to the machine
```

**An MCP server says "disabled"**

The `requiresEnv` variable is missing:

```bash
grep GITHUB_TOKEN .env  # empty?
$EDITOR .env
ai-dev-sync
```

**The commit is blocked but there is no secret (false positive)**

```bash
./scripts/git/preflight.sh --staged     # shows which file:line it is
```

If it really is a false positive, either turn the value into a placeholder
(`<your-token>`, `{env:VAR}`) or narrow the pattern in
`scripts/lib/secret-patterns.conf`. Last resort: `git commit --no-verify`.

**The Codex config.toml got corrupted**

The TOML is validated after writing and rolled back automatically if broken.
If you still want to revert by hand:

```bash
ls ~/.codex/config.toml.ai-dev-backup-*
cp ~/.codex/config.toml.ai-dev-backup-<date> ~/.codex/config.toml
```

**The OpenCode config got corrupted**

```bash
ls -d ~/.config/opencode.backup-*
cp ~/.config/opencode.backup-<date>/opencode.json ~/.config/opencode/
```

A backup is always taken before the first write; the last 10 backups are kept.

---

## Uninstalling

```bash
./uninstall.sh --dry-run     # see what would be removed first
./uninstall.sh               # config, commands, rules, hook setting
./uninstall.sh --skills      # + the skills in the manifests
```

Removed: the `~/.local/bin/ai-dev-*` wrappers, each agent's managed
directory, the MCP entries and rules registrations this repo added, the shell
rc block, the credential bridge, the `core.hooksPath` setting.

Preserved: the agents themselves, your credentials, your provider/model/agent
settings, the MCP servers you added yourself, and every config key this repo
never wrote.

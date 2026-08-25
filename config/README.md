# config/

Optional files distributed to the agents alongside `rules/global.md`.

| Directory | Goes to |
|---|---|
| `config/shared/` | every detected agent |
| `config/opencode/` | OpenCode only |
| `config/claude/` | Claude Code only |
| `config/codex/` | Codex only |

Drop a file into one of these and it is symlinked into that agent's managed
directory on the next `ai-dev-sync`. No script needs to be told about it:
`config_fragment_links()` in `scripts/lib/common.sh` enumerates the directory,
and the adapters, `check.sh` and `verify.sh` all consume the same list.

Because they are symlinks, editing the file in the repository changes what the
agent sees immediately — there is no second copy to drift.

`README.md` and `.gitkeep` are skipped. Nothing here is required; all four
directories can stay empty.

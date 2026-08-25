# Global Agent Rules

Managed by [opencode-bootstrap](https://github.com/) — edit `config/AGENTS.md`
in the repository and run `opencode-sync`, not this installed copy.

These are baseline defaults. A project's own `AGENTS.md` takes precedence.

## Before changing anything

- Read the surrounding code first. Match its conventions, naming and structure
  instead of introducing your own.
- Check the framework and dependency versions actually in use (`package.json`,
  lockfile, `composer.json`, `requirements.txt`) before writing code against an
  API. Do not assume the latest version.
- Prefer current official documentation over recalled knowledge for library
  APIs, configuration and CLI flags.
- If the project has a design system, component library or utility layer, use
  it. Do not hand-roll a parallel one.

## While changing things

- Do not rewrite working code that was not part of the request.
- Do not add a dependency unless it is genuinely needed and nothing already in
  the project covers it. Say why when you do.
- Keep changes scoped to what was asked. Note adjacent problems; do not
  silently fix them.

## Secrets

- Never commit API keys, tokens, passwords or credentials.
- Never overwrite or delete a `.env` file. Add new keys to `.env.example`.
- Do not print real credential values in output or logs.

## Finishing

- Test the change. Run the project's own test or lint command if one exists.
- Report failures plainly, with the actual error output. Never present
  untested work as verified.
- If part of a task is blocked, finish the rest and say exactly what was left
  out and why.

## Skills

Relevant skills are installed globally and discoverable by name. Use one when
it matches the task at hand — frontend and UI work, database and SQL, Docker
and deployment, testing, debugging, security review. Do not run every skill on
every task; pick what fits.

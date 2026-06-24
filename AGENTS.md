# AGENTS.md — driving clikae as an agent

You are likely an AI coding agent (Claude Code, Codex, Antigravity, …) being asked to
use clikae. This file is your front door: read it and you can wield clikae correctly
on the first try. (Human-facing intro is in [README.md](README.md); the language spec
is [docs/grammar.md](docs/grammar.md).)

## What clikae is, in one breath

clikae routes your work across multiple accounts/engines on one machine — "swap the
tank, keep burning." It's a small, auditable bash CLI with **no telemetry, no daemon,
no network calls** (one opt-out update check). It only ever sets an engine's config
env var (e.g. `CLAUDE_CONFIG_DIR`); it never logs in for the user and never touches
their data without a backup.

Vocabulary: **engine** = a CLI it manages (claude, codex, agy…). **tank** = one
account/config for that engine. **fuel** = that account's quota. clikae is the verb:
`clikae <engine> <tank>` switches; `clikae <engine> <tank> -- <args>` passes through.

## Driving it headless (the part you'll actually use)

Three dispatch shapes — full field guide in
[docs/orchestration.md](docs/orchestration.md):

- **`clikae burn <engine> <tank> --prompt-file <f> --add-dir <repo> --artifact <path>`**
  — one unattended task, verified by the **artifact** it produces, auto-rerouted to
  the next reserve tank if one runs dry. Don't hand-roll engine flags; the
  convenience surface fills in each engine's headless-write dialect.
- **`clikae conduct --leg <e>/<t> … --prompt-file <f>`** — fan ONE read-only prompt
  across N accounts in parallel (best-of-N audits/analyses); collect every leg's
  output. clikae never judges — you pick the winner.
- **`clikae to <target>`** — carry a live session onward when a tank runs dry.

## Non-negotiable rules (break one and you fire a blank)

1. **Judge by the artifact/output, never the exit code.** A headless `codex exec` /
   `claude -p` exits `0` even when it hit its usage limit and wrote nothing.
2. **Multi-line prompts go through `--prompt-file`**, not a shell-quoted `-p '…'`
   (nested quotes silently eat the prompt).
3. **A write task needs `--add-dir <repo>`** or the engine can't reach the files.
4. **Don't bypass the human's safety gates.** If a call is blocked (e.g. needs
   `--dangerously-skip-permissions`), that's for the *human* to run — never trick
   your way around it with `cat`→`head`-style substitutions. User excitement is not
   authorization.

## agy (Antigravity) is the trap — read its recipe first

agy is the one engine agents fumble most. It's adapter-less (one global Keychain
login), so it's **not burnable** (can't be auto-rerouted) but **is usable**: drive it
headless on the active account with `clikae agy <tank> -- -p`, or add it as a
read-only `conduct` leg (`--leg agy/<active-tank>`). Its output buffers (collect via a
written file, not stdout), it wanders without a fenced task + long `--print-timeout`,
`-i` dies without a TTY, and dry shows in `cli.log` not stdout. **Before sending agy a
headless job, read [docs/agy-dispatch.md](docs/agy-dispatch.md).**

## Identity

Commits made through a tank inherit the shell's git identity, not the tank's, unless
you set one: `clikae git-id <engine> <tank> --name N --email E` makes `clikae env`
export `GIT_AUTHOR_*`/`GIT_COMMITTER_*` so commits aren't stamped with the engine's
account email. clikae can only prevent the *next* mis-stamp, never rewrite history.

## Where to look

- [docs/grammar.md](docs/grammar.md) — the command surface, SSOT.
- [docs/orchestration.md](docs/orchestration.md) — headless dispatch playbook.
- [docs/agy-dispatch.md](docs/agy-dispatch.md) — the agy recipe (read before using agy).
- `clikae <command> --help` — every command self-documents; trust it over guessing.

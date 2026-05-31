# Using clikae

Every command takes a `<cli>` (a tool with an adapter — run `clikae adapters`)
and a `<profile>` (a name you choose; `A-Z a-z 0-9 . _ -` are allowed).

Run `clikae help <command>` for the full per-command reference.

## Quick tour

```bash
# Create a profile for Claude Code, and add the matching shell alias
clikae init claude work --alias

# Pick up the new alias in the current shell
source ~/.zshrc            # or your rc file

# Use it
claude-work

# Generate a macOS launcher you can double-click from ~/Applications
clikae app claude work

# See what you've got
clikae list
#   CLI          PROFILE
#   claude       work
clikae list -p             # also print the profile directory paths

# Run a profile without an alias
clikae run claude work
clikae run claude work -- --help     # args after -- go straight to the CLI

# Tear it all down (profile dir + alias + .app, asks to confirm)
clikae remove claude work
```

## Commands

| Command | What it does |
|---|---|
| `init <cli> <profile> [--alias]` | Create the profile directory; with `--alias`, also write a shell alias. |
| `alias <cli> <profile> [--name <n>]` | Write (or replace) a shell alias. Default name `<cli>-<profile>`. |
| `app <cli> <profile> [--terminal <app>] [--force] [--out <dir>]` | Generate a macOS `.app` launcher (default `~/Applications`). macOS only. `--terminal`: `terminal` (default), `iterm2`, `ghostty`. |
| `run <cli> <profile> [-- args...]` | Run the CLI with the profile applied, no alias needed. |
| `relay <cli> [<from>] <to> [-- args...]` | Hand the current session to another profile and continue on its quota. |
| `handoff <cli> [<profile>] [--out <file>] [--summarizer <cmd>]` | Write a portable handoff brief from the current session for another model/vendor to pick up. |
| `watch <cli> [<profile>] [--auto] [--to <target>]` | Watch a session and fall through to the next pool tank when it runs dry. |
| `pool [list] [--json]` / `pool add\|remove <target>` | Manage the fuel pool — the ordered tanks `watch` falls through to. `--json` emits a JSON array ({position, target, cli, profile}) for scripts and the GUI. |
| `list [-p\|--paths] [--json]` | List all profiles, with the logged-in account where the adapter can tell. `--json` emits machine-readable output ({cli, profile, account, path}) for scripts and the GUI. |
| `status [<cli>] [--json]` | Show which profile each CLI is on **in this shell**. `--json` emits machine-readable output (one object per CLI with a `state` enum) for scripts and the GUI. |
| `rename <cli> <old> <new> [--force]` | Rename a profile (moves the dir, rewrites the alias, carries the login). |
| `remove <cli> <profile> [--force] [--keep-data]` | Remove dir + alias + `.app`. `--keep-data` keeps the directory. |
| `migrate [<cli>] [--dry-run] [--force] [--keep-login]` | Adopt a hand-rolled config-dir + alias setup. |
| `info [--json]` | Show install paths, platform, adapters, and profile count. `--json` emits a single object ({version, installRoot, profileStore, shellRc, platform, adapters, profiles}) for scripts and the GUI. |
| `adapters` | List supported CLIs with descriptions. |

## Shells

`clikae` auto-detects your shell from `$SHELL` and writes the alias to the right
rc file: **zsh** (`~/.zshrc`), **bash** (`~/.bash_profile` on macOS, else
`~/.bashrc`), and **fish** (`~/.config/fish/config.fish`). For fish it emits fish
syntax — `alias <name> 'env VAR=val <binary>'` — because fish has no inline
`VAR=val cmd`; the result behaves identically. `clikae remove` cleans up the
block in any of them.

## Migrating an existing setup

Already juggling accounts by hand — say a `~/.claude-acct-a` / `~/.claude-acct-b`
pair with aliases in your `~/.zshrc`? `clikae migrate` adopts that into clikae:

```bash
clikae migrate --dry-run   # preview: which dirs move where, which aliases change
clikae migrate             # do it (asks to confirm first)
```

It scans your shell rc for aliases that set the CLI's config env var and invoke
the CLI. For each one it:

1. moves the referenced config directory under `~/.clikae/profiles/<cli>/<p>/`,
2. rewrites the alias into clikae's managed sentinel block.

The rc file is backed up to `<rc>.clikae.bak.<timestamp>` first, and an existing
clikae profile is never overwritten. Pass a CLI name (`clikae migrate gh`) to
migrate a different tool's aliases. Default is `claude`.

> ⚠️ **Don't migrate a config dir that's currently in use.** `migrate` *moves*
> the directory, so if a process is running against it right now (e.g. you run
> `clikae migrate` from inside the very `claude` session whose
> `CLAUDE_CONFIG_DIR` points at the dir being moved), you pull the directory out
> from under that live process — it can fail to write, or recreate an empty dir
> at the old path and leave you with two half-states. Run `migrate` from a fresh
> shell with no instance of that CLI active. `--dry-run` is always safe.
>
> As of v0.4, `migrate` guards against the most common form of this: if
> `$CLAUDE_CONFIG_DIR` (or whichever env var the adapter uses) currently points
> at a directory slated to move, it refuses and tells you to retry from a fresh
> shell. The guard is not bypassed by `--force` — it protects your data, it
> isn't a confirmation prompt.

> 🔑 **macOS + claude: expect a one-time re-login per migrated profile.** On
> macOS, Claude Code keeps its login token in the **login Keychain**, not inside
> `CLAUDE_CONFIG_DIR` — and the keychain entry is keyed by the config-dir path.
> Because `migrate` moves the dir to a new path, claude no longer finds the token
> and asks you to log in once for each migrated profile. Your data is intact;
> only the saved login doesn't follow the move. To avoid the re-login, pass
> `--keep-login`, which copies the saved token from the old path's keychain entry
> to the new one (macOS only; it never reads or transmits the token anywhere — it
> stays in your Keychain). macOS may prompt you to allow keychain access.

## Relaying a session when you hit a usage limit

This is clikae's origin story: you keep a second account precisely because one
account's quota runs out mid-task. `clikae relay` lets you swap to the other
account — like swapping a fuel tank — and **keep the same conversation going** on
the fresh quota.

```bash
# You're working as profile `a` and just hit its limit. From the same project
# directory, hand the conversation to profile `b` and carry on:
clikae relay claude b           # from = whatever this shell is on, to = b
clikae relay claude a b         # or name both ends explicitly
```

For Claude Code, relay finds the **current directory's** most recent transcript
under the source profile, copies it into the target profile, and runs
`claude --resume <id>` there — so the conversation continues, but every new turn
burns the target profile's quota. The source profile is left completely untouched
(relay copies, never moves), so you can always go back to it.

- The source profile is auto-detected from this shell's `$CLAUDE_CONFIG_DIR` when
  you give only the target; name both ends if it can't be detected.
- If there's no transcript to carry (e.g. a directory you've never used Claude
  in), relay just starts a fresh session under the target profile.
- Other CLIs have no conversation to carry, so for them `relay` simply starts the
  CLI under the target profile.

> Carry-over relies on Claude Code's on-disk transcript layout
> (`<config-dir>/projects/<slug>/<id>.jsonl`) and `--resume`. It's verified
> against current Claude Code; if a future version changes that layout, relay
> falls back to a fresh start rather than doing anything destructive.

## Handing off to another model or vendor

`relay` keeps the *same* conversation on another **account of the same CLI**. But
sometimes the next tank is a different *model* or *vendor* (a cheaper one to do
the dirty work, or simply the one that still has quota), and there's no shared
transcript format to resume. The portable answer is a **handoff brief**: a short
note — what you're doing, what's done, what's next — that any assistant can read
to pick up where you left off.

```bash
# Write a brief from the current directory's most recent claude session:
clikae handoff claude                      # uses this shell's profile
clikae handoff claude work --out HANDOFF.md # name the profile, save to a file
```

By default you get a **raw extract** (session metadata + your recent prompts),
clearly labelled as raw — dependency-free, but not a real summary. For a proper
brief, point clikae at a **local or cheap model** so writing the brief costs
nothing on the tank that just ran dry:

```bash
export CLIKAE_HANDOFF_SUMMARIZER='llm -m my-local-model'   # any command works
clikae handoff claude                                       # model writes the brief
```

The summarizer command receives, on stdin, an instruction line followed by the
tail of the session transcript, and writes the brief to stdout. Anything that
reads stdin and writes stdout works — a local LLM CLI, an on-device model
wrapper, etc. If it produces nothing, clikae falls back to the raw extract so a
handoff is never lost. `handoff` is **read-only**: it never touches the session
or any profile.

### Handing off in one step with `--to`

Add `--to <target>` and clikae writes the brief *and* starts the next tank with
it as the opening prompt — the actual "switch model / vendor" move:

```bash
clikae handoff claude --to codex/work    # dry Claude → continue on Codex
clikae handoff claude a --to claude/b    # hand off to another Claude account
clikae handoff claude --to antigravity   # hand off to Google's Antigravity (agy)
```

A target is one of:

- **`<cli>/<profile>`** — another account of a *switchable* CLI (currently
  `claude` and `codex` know how to start from a brief). New turns burn that
  profile's quota.
- **`antigravity`** — a *handoff target*: a single-account vendor you can hand off
  *to* but can't profile-switch, because its CLI (`agy`) hardcodes `~/.gemini`
  with no config-dir override. `--to antigravity` starts `agy -i` with the brief.
  Such targets live in `lib/targets/`.

`--out` still works alongside `--to` if you also want the brief saved to a file.

- The brief is tied to `$PWD` (like `relay`): it summarises the conversation for
  the directory you're standing in.
- Tune how much transcript is fed/scanned with `$CLIKAE_HANDOFF_LINES` (default
  `60`).

## Ambient relay: notice a dry tank and switch (`watch` + `pool`)

Instead of switching by hand, let clikae watch for the moment a tank runs dry and
fall through to the next one. First, set up your **fuel pool** — the tanks to use,
in priority order:

```bash
clikae pool add claude/a       # most preferred
clikae pool add claude/b
clikae pool add codex/work
clikae pool add antigravity     # last resort
clikae pool list
clikae pool list --json         # machine-readable, for scripts / the GUI
```

Then watch the current session:

```bash
clikae watch claude            # offer to switch when it looks dry
clikae watch claude --auto     # switch automatically (asks once for consent)
clikae watch claude --to codex/work   # ignore the pool; go straight here
```

When it detects a dry tank it hands off to the next pool entry (the one after the
profile you're on) via `clikae handoff`. By default it **asks first**; `--auto`
switches automatically after a **one-time consent** (remembered in
`$CLIKAE_HOME/auto-relay-consent` — delete that file to revoke), and always tells
you what it did.

> **Honest caveat.** An interactive CLI hitting its usage limit doesn't exit,
> returns no code, and fires no hook — so the only thing clikae can watch is what
> the limit writes into the session transcript, and **that exact marker isn't
> confirmed yet** (you can't force a real limit without burning a tank). The match
> pattern is a best guess. Confirm/tune it the first time you actually get limited:
>
> ```bash
> clikae watch claude --check          # would the pattern fire on this session?
> CLIKAE_LIMIT_PATTERN='…' clikae watch claude   # override the match
> ```
>
> If you discover the real marker, set `$CLIKAE_LIMIT_PATTERN` (and please tell the
> project so the default can be fixed).

## Seeing which profile you're on

```bash
clikae status            # every CLI that has a profile
clikae status claude     # just one

#   CLI          ACTIVE       ACCOUNT          SOURCE
#   claude       cver         hi@cver.net      CLAUDE_CONFIG_DIR=…/profiles/claude/cver
#   aws          (default)    -                AWS_PROFILE unset — system default
```

`status` reads the **live** value of each adapter's env var in the current shell
and resolves it back to a clikae profile. It's a per-shell view: another terminal
(or one launched from a different `clikae app`) can be on a different profile.
`(default)` means the env var is unset (the CLI's own default); `(external)`
means it points somewhere that isn't a clikae profile. The ACCOUNT column shows
the logged-in account when the adapter can tell.

## Naming your profiles

Name profiles however makes sense to you — `work`, `personal`, a client name, or
the account email. You don't have to remember what a bare `a`/`b` meant: both
`list` and `status` show the logged-in **account** when the adapter can read it.

Changed your mind about a name? `clikae rename` moves the directory, rewrites the
managed alias, and — for claude on macOS — carries the saved Keychain login
across so you don't have to log in again:

```bash
clikae rename claude a cver        # a → cver; login + alias follow
```

It refuses if the new name is taken or if that CLI is currently using the profile
in this shell (run it from a fresh shell). A pre-existing `.app` launcher is left
alone but flagged — recreate it with `clikae app claude cver`.

## How it works

For each profile, `clikae`:

1. Creates `~/.clikae/profiles/<cli>/<profile>/` — the directory the CLI's env
   var (e.g. `CLAUDE_CONFIG_DIR`) points at.
2. (`alias`) Appends a sentinel-wrapped block to your shell rc:
   ```
   # >>> clikae:claude.work >>>
   alias claude-work='CLAUDE_CONFIG_DIR="/Users/you/.clikae/profiles/claude/work" claude'
   # <<< clikae:claude.work <<<
   ```
   The sentinels make safe, exact removal possible.
3. (`app`, macOS) Generates an AppleScript-compiled `.app` that opens a terminal,
   runs the env-var-prefixed CLI, and sets the window title to `claude (work)`
   so you can tell windows apart. The terminal is **Terminal.app** by default;
   `--terminal iterm2` and `--terminal ghostty` target those instead (set
   `$CLIKAE_TERMINAL` to change the default). Terminal.app and iTerm2 are driven
   by AppleScript; Ghostty has no window-opening CLI on macOS, so its launcher
   goes through `open -na Ghostty.app --args … -e …`.

No daemons, no global state, no network calls. You can read every line.

## Supported CLIs

| CLI | Strategy | Env var |
|---|---|---|
| `claude` (Anthropic Claude Code) | `env-dir` | `CLAUDE_CONFIG_DIR` |
| `codex` (OpenAI Codex CLI) | `env-dir` | `CODEX_HOME` |
| `gh` (GitHub CLI) | `env-dir` | `GH_CONFIG_DIR` |
| `gcloud` (Google Cloud CLI) | `env-dir` | `CLOUDSDK_CONFIG` |
| `docker` (Docker CLI) | `env-dir` | `DOCKER_CONFIG` |
| `helm` | `env-dir` | `HELM_CONFIG_HOME` |
| `kubectl` | `env-file` | `KUBECONFIG` |
| `aws` (AWS CLI) | `env-var` | `AWS_PROFILE` |
| `az` (Azure CLI) | `env-dir` | `AZURE_CONFIG_DIR` |
| `npm` | `env-file` | `NPM_CONFIG_USERCONFIG` |
| `terraform` | `env-file` | `TF_CLI_CONFIG_FILE` |
| `pulumi` | `env-dir` | `PULUMI_HOME` |
| `vercel` (Vercel CLI) | `flag` | — (`--global-config <dir>`) |

The `flag` strategy is for CLIs with no config-directory env var: the profile
directory is injected as a command-line flag (e.g. vercel's `--global-config`)
in the generated alias / `.app` / `run` command instead of an exported variable.
Such a CLI shows `(n/a)` in `clikae status` (there's nothing in the environment
to read back).

Run `clikae adapters` to see them with descriptions. Adding your own is ~10
lines of bash — see [adding-an-adapter.md](adding-an-adapter.md).

> **Note on `aws`:** unlike the others, the AWS adapter doesn't isolate config
> into a separate directory — `AWS_PROFILE` selects a *named profile* from your
> existing `~/.aws/config`. So `clikae init aws work` expects a matching
> `[profile work]` entry to exist. See the comment at the top of
> `lib/adapters/aws.sh` for the alternative `env-file` approach.

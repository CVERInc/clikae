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
| `list [-p\|--paths]` | List all profiles, with the logged-in account where the adapter can tell. |
| `status [<cli>]` | Show which profile each CLI is on **in this shell**. |
| `rename <cli> <old> <new> [--force]` | Rename a profile (moves the dir, rewrites the alias, carries the login). |
| `remove <cli> <profile> [--force] [--keep-data]` | Remove dir + alias + `.app`. `--keep-data` keeps the directory. |
| `migrate [<cli>] [--dry-run] [--force] [--keep-login]` | Adopt a hand-rolled config-dir + alias setup. |
| `info` | Show install paths and profile counts. |
| `adapters` | List supported CLIs with descriptions. |

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

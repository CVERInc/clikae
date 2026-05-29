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
| `app <cli> <profile> [--force] [--out <dir>]` | Generate a macOS `.app` launcher (default `~/Applications`). macOS only. |
| `run <cli> <profile> [-- args...]` | Run the CLI with the profile applied, no alias needed. |
| `list [-p\|--paths]` | List all profiles across all CLIs. |
| `remove <cli> <profile> [--force] [--keep-data]` | Remove dir + alias + `.app`. `--keep-data` keeps the directory. |
| `migrate [<cli>] [--dry-run] [--force]` | Adopt a hand-rolled config-dir + alias setup. |
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
3. (`app`, macOS) Generates an AppleScript-compiled `.app` that opens Terminal,
   runs the env-var-prefixed CLI, and sets the window title to `claude (work)`
   so you can tell windows apart.

No daemons, no global state, no network calls. You can read every line.

## Supported CLIs

| CLI | Strategy | Env var |
|---|---|---|
| `claude` (Anthropic Claude Code) | `env-dir` | `CLAUDE_CONFIG_DIR` |
| `gh` (GitHub CLI) | `env-dir` | `GH_CONFIG_DIR` |
| `gcloud` (Google Cloud CLI) | `env-dir` | `CLOUDSDK_CONFIG` |
| `docker` (Docker CLI) | `env-dir` | `DOCKER_CONFIG` |
| `helm` | `env-dir` | `HELM_CONFIG_HOME` |
| `kubectl` | `env-file` | `KUBECONFIG` |
| `aws` (AWS CLI) | `env-var` | `AWS_PROFILE` |

Run `clikae adapters` to see them with descriptions. Adding your own is ~10
lines of bash — see [adding-an-adapter.md](adding-an-adapter.md).

> **Note on `aws`:** unlike the others, the AWS adapter doesn't isolate config
> into a separate directory — `AWS_PROFILE` selects a *named profile* from your
> existing `~/.aws/config`. So `clikae init aws work` expects a matching
> `[profile work]` entry to exist. See the comment at the top of
> `lib/adapters/aws.sh` for the alternative `env-file` approach.

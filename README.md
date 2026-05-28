# clikae · ｷﾘｶｴ

> CLI profile switcher. One tool to juggle multiple accounts / configs for any CLI that uses an environment variable for its settings.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.2-blue.svg)](CHANGELOG.md)

> ⚠️ **Unofficial.** `clikae` is a community tool. It is not affiliated with, endorsed by, or sponsored by any of the CLI vendors it integrates with. "Claude" is a trademark of Anthropic, PBC; other CLI names are trademarks of their respective owners.

---

## What it does

You probably have more than one account on at least one CLI tool. Two GitHub accounts (personal + work). Two `gcloud` configurations (client A + client B). Two Anthropic Claude subscriptions because one Max plan didn't have enough quota. And now you're juggling shell aliases, env vars, and `--profile` flags by hand, and you keep logging into the wrong one.

`clikae` is a small tool that:

1. Creates **isolated profile directories** for each CLI tool (one folder per (CLI, profile) pair).
2. Generates **shell aliases** (`claude-work`, `gh-personal`, …) you can paste into a new terminal.
3. On macOS, generates **double-clickable `.app` launchers** that open a Terminal window with the right env vars set and a custom window title so you can tell them apart.
4. Cleans up after itself when you're done with a profile.

It works for any CLI that respects an environment variable for its config location. It ships with built-in adapters for **Claude Code, GitHub CLI, gcloud, Docker, Helm, kubectl, and AWS**; new adapters are ~10 lines of bash (see [docs/adding-an-adapter.md](docs/adding-an-adapter.md)).

## Install

### From source (recommended until the Homebrew tap lands in v0.3)

```bash
git clone https://github.com/CVERInc/clikae.git
cd clikae
./install.sh                 # installs to ~/.local
# or:
PREFIX=/usr/local sudo ./install.sh
```

Make sure `~/.local/bin` (or `/usr/local/bin`) is on your `PATH`, then:

```bash
clikae help
```

### Homebrew (planned for v0.3)

```bash
brew install CVERInc/clikae/clikae
```

### `curl | bash`

```bash
curl -fsSL https://raw.githubusercontent.com/CVERInc/clikae/main/install.sh | bash
```

## Quick tour

```bash
# Create a profile for Claude Code, also add the matching shell alias
clikae init claude work --alias

# Generate a macOS launcher (double-click it from ~/Applications)
clikae app claude work

# See what you've got
clikae list
#   CLI          PROFILE
#   claude       work

# Run with a profile without using the alias
clikae run claude work

# Tear it all down (profile dir + alias + .app, with confirmation prompt)
clikae remove claude work
```

## Migrating an existing setup

Already juggling accounts by hand — say a `~/.claude-acct-a` / `~/.claude-acct-b`
pair with aliases in your `~/.zshrc`? `clikae migrate` adopts that into clikae:

```bash
clikae migrate --dry-run   # preview: which dirs move where, which aliases change
clikae migrate             # do it (asks to confirm first)
```

It moves each config directory under `~/.clikae/profiles/claude/<name>/`, rewrites
the aliases into clikae's managed blocks, backs up your rc file, and never
overwrites an existing profile. Pass a CLI name (`clikae migrate gh`) to migrate
a different tool's aliases.

## How it works

For each profile, `clikae`:

1. Creates `~/.clikae/profiles/<cli>/<profile>/`. This is the directory the CLI's env var (e.g. `CLAUDE_CONFIG_DIR`) points at.
2. (`alias` command) Appends a sentinel-wrapped block to your shell rc:
   ```
   # >>> clikae:claude.work >>>
   alias claude-work='CLAUDE_CONFIG_DIR="/Users/you/.clikae/profiles/claude/work" claude'
   # <<< clikae:claude.work <<<
   ```
   Sentinels make safe removal easy.
3. (`app` command, macOS) Generates an AppleScript-compiled `.app` that opens Terminal, runs the env-var-prefixed CLI, and sets the window's custom title to `claude (work)`.

That's it. No daemons, no global state, no surprises. You can read every line of every script.

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

Run `clikae adapters` to see them with descriptions.

Roadmap (PRs very welcome): `terraform`, `vercel`, `firebase`, `npm`, `az`. See [docs/adding-an-adapter.md](docs/adding-an-adapter.md).

> **Note on `aws`:** unlike the others, the AWS adapter doesn't isolate config into a separate directory — `AWS_PROFILE` selects a *named profile* from your existing `~/.aws/config`. So `clikae init aws work` expects a matching `[profile work]` entry to exist. See the comment at the top of `lib/adapters/aws.sh` for the alternative `env-file` approach.

## Roadmap

- **v0.1** — core CLI, claude adapter, macOS `.app` launchers, install script.
- **v0.2** *(current)* — 7 built-in adapters (claude, gh, gcloud, docker, helm, kubectl, aws), `bats-core` test suite + CI on Linux & macOS, `migrate` command for hand-rolled setups.
- **v0.3** — Homebrew tap, demo GIF / asciinema, polish docs, more built-in adapters.
- **v0.4** — Windows PowerShell module (alias generation only; no `.app`).
- **v1.0** — SwiftUI menu bar GUI for macOS (click-to-switch active profile).

## Contributing

PRs are very welcome — especially new adapters. Please read `docs/adding-an-adapter.md` first.

For non-trivial changes, open an issue to discuss the approach before sending a PR.

## License

[MIT](LICENSE)

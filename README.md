# clikae · ｷﾘｶｴ

> CLI profile switcher. One tool to juggle multiple accounts / configs for any CLI that uses an environment variable for its settings.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.2-blue.svg)](CHANGELOG.md)

> ⚠️ **Unofficial.** `clikae` is a community tool. It is not affiliated with, endorsed by, or sponsored by any of the CLI vendors it integrates with. "Claude" is a trademark of Anthropic, PBC; other CLI names are trademarks of their respective owners.

---

## What & why

You probably have more than one account on at least one CLI tool. Two GitHub accounts (personal + work). Two `gcloud` configurations (client A + client B). Two Anthropic Claude subscriptions because one Max plan didn't have enough quota. And now you're juggling shell aliases, env vars, and `--profile` flags by hand, and you keep logging into the wrong one.

`clikae` is a small, pure-bash tool that:

1. Creates **isolated profile directories** for each CLI tool (one folder per (CLI, profile) pair).
2. Generates **shell aliases** (`claude-work`, `gh-personal`, …) you can use in a new terminal.
3. On macOS, generates **double-clickable `.app` launchers** that open a Terminal window with the right env vars set and a custom window title so you can tell them apart.
4. Cleans up after itself when you're done with a profile.

It works for any CLI that respects an environment variable for its config location, ships with built-in adapters for **Claude Code, GitHub CLI, gcloud, Docker, Helm, kubectl, and AWS**, and adding a new one is ~10 lines of bash. No daemons, no global state, no network calls — every line is auditable.

## Install

```bash
brew install CVERInc/clikae/clikae
```

Or from source / `curl | bash` — see [docs/installation.md](docs/installation.md).

## 30 seconds

```bash
clikae init claude work --alias   # create profile + add `claude-work` alias
source ~/.zshrc                   # pick up the alias
claude-work                       # go
```

## Documentation

- **[Installation](docs/installation.md)** — from source, Homebrew (planned), `curl | bash`, PATH setup.
- **[Usage](docs/usage.md)** — full command reference, the `migrate` command, how it works, supported CLIs.
- **[Troubleshooting](docs/troubleshooting.md)** — aliases not loading, Gatekeeper on `.app`, AWS profiles, undoing rc edits.
- **[Adding an adapter](docs/adding-an-adapter.md)** — teach clikae a new CLI.

## Roadmap

- **v0.1** — core CLI, claude adapter, macOS `.app` launchers, install script.
- **v0.2** *(current)* — 7 built-in adapters (claude, gh, gcloud, docker, helm, kubectl, aws), `bats-core` test suite + CI on Linux & macOS, `migrate` command for hand-rolled setups.
- **v0.3** *(in progress)* — Homebrew tap ✅, split docs ✅, more built-in adapters.
- **v0.4** — Windows PowerShell module (alias generation only; no `.app`).
- **v1.0** — SwiftUI menu bar GUI for macOS (click-to-switch active profile).

## Contributing

PRs are very welcome — especially new adapters. Please read [docs/adding-an-adapter.md](docs/adding-an-adapter.md) first. For non-trivial changes, open an issue to discuss the approach before sending a PR.

## License

[MIT](LICENSE)

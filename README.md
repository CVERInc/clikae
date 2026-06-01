# clikae · ｷﾘｶｴ

> Switch any CLI between accounts. One tool to juggle multiple accounts / configs for any CLI that selects its settings from an environment variable.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.5-blue.svg)](CHANGELOG.md)

> ⚠️ **Unofficial.** `clikae` is a community tool. It is not affiliated with, endorsed by, or sponsored by any of the CLI vendors it integrates with. "Claude" is a trademark of Anthropic, PBC; other CLI names are trademarks of their respective owners.

---

## What & why

You probably have more than one account on at least one CLI tool. Two GitHub accounts (personal + work). Two `gcloud` configurations (client A + client B). Two Anthropic Claude subscriptions because one Max plan didn't have enough quota. And now you're juggling shell aliases, env vars, and `--profile` flags by hand, and you keep logging into the wrong one.

`clikae` is a small, pure-bash tool. The name is 切り替え — *switching* — so
**clikae is the verb**: `clikae <engine> <tank>` points an engine (a CLI like
claude, codex, gh) at one of your tanks (an account/config) and runs it. No verb
to memorise; the program name *is* the verb.

It:

1. Creates **isolated tank directories** for each engine (one folder per engine + tank).
2. Generates **shell aliases** (`claude-work`, `gh-personal`, …) you can use in a new terminal.
3. On macOS, generates **double-clickable `.app` launchers** that open a Terminal window with the right env vars set and a custom window title so you can tell them apart.
4. **Carries a live session to another tank** when one runs dry — `clikae to <tank>` keeps the same conversation going on the other account's quota (and `clikae to <other-engine>` hands a written brief across vendors).
5. Cleans up after itself when you're done with a tank.

It works for any CLI that selects its config via an environment variable (or a flag), ships with built-in adapters for **Claude Code, OpenAI Codex, GitHub CLI, gcloud, Docker, Helm, kubectl, AWS, Azure CLI, npm, Terraform, Pulumi, and Vercel** (plus opt-in multi-account for **Antigravity / agy**), and adding a new one is ~10 lines of bash. No daemons, no global state, no network calls — every line is auditable.

## Install

**Homebrew** (macOS / Linux):

```bash
brew install CVERInc/clikae/clikae
```

The `CVERInc/clikae/` prefix is the **tap** — clikae ships from its own tap repo,
not (yet) in homebrew-core, so the prefix is expected and normal (a fully
supported install, not a sign it's "unpublished").

**Or `curl | bash`** (no Homebrew needed — installs to `~/.local`):

```bash
curl -fsSL https://raw.githubusercontent.com/CVERInc/clikae/main/install.sh | bash
```

It's pure bash, so read it first if you'd rather not pipe to a shell — every line
is auditable. From-source and custom-`PREFIX` options:
[docs/installation.md](docs/installation.md).

> **Platform.** clikae is a **macOS / Linux** tool — it's bash, and that's the
> point ("every line is auditable"). A **PowerShell module** lives in
> [`powershell/`](powershell/) but is **community-contributed and unsupported**:
> it isn't part of the maintained grammar and its CI is informational only.
> Windows users very welcome to drive it — PRs appreciated.

## 30 seconds

```bash
clikae init claude work --alias   # create a tank (+ a `claude-work` alias)
clikae claude work                # switch to it and run — the bare verb
```

Hit a usage limit mid-task? Carry the same conversation to your other tank and
keep going on its quota:

```bash
clikae to personal                # carry the live session to tank `personal`
clikae to codex                   # or across engines (a written brief)
```

Type **`clikae`** any time to see all your tanks — which accounts you have per
engine, and which one each terminal is currently on:

```bash
clikae                            # your home dashboard (run `clikae doctor` for a health check)
```

## Documentation

- **[Installation](docs/installation.md)** — Homebrew, from source, `curl | bash`, PATH setup.
- **[Usage](docs/usage.md)** — full command reference, the `migrate` command, how it works, supported CLIs.
- **[Grammar](docs/grammar.md)** — the language clikae speaks: why it's a verb, engine/tank/fuel, `clikae to`, agy.
- **[Troubleshooting](docs/troubleshooting.md)** — aliases not loading, Gatekeeper on `.app`, AWS profiles, undoing rc edits.
- **[Claude on macOS](docs/claude-on-macos.md)** — why migrating asks you to log in again (Keychain), and why the startup screen can look different (it's not clikae).
- **[Adding an adapter](docs/adding-an-adapter.md)** — teach clikae a new CLI.

## Roadmap

- **v0.1** — core CLI, claude adapter, macOS `.app` launchers, install script.
- **v0.2** — 7 built-in adapters (claude, gh, gcloud, docker, helm, kubectl, aws), `bats-core` test suite + CI on Linux & macOS, `migrate` command for hand-rolled setups.
- **v0.3** — Homebrew tap, `migrate --keep-login` (carries the macOS Keychain token across a move), split docs.
- **v0.4** — Four more adapters (`az`, `npm`, `terraform`, `pulumi`; 11 total) and a `migrate` guard against moving an in-use config dir.
- **v0.5** *(in progress)* — the **fuel-tank grammar**: clikae becomes the verb (`clikae <engine> <tank>`), one `clikae to` for carrying a session onward (same engine resumes, another engine gets a brief), Antigravity/agy folded into the same verbs, and an engine/tank/fuel vocabulary throughout. See [docs/grammar.md](docs/grammar.md).
- **v1.0** *(planned)* — macOS menu bar app (`gui/ClikaeMenuBar`): tanks per engine, active one marked, click-to-launch, per-engine `to`. Build-verified AppKit skeleton; signed `.app` packaging next.

## Contributing

PRs are very welcome — especially new adapters. Please read [docs/adding-an-adapter.md](docs/adding-an-adapter.md) first. For non-trivial changes, open an issue to discuss the approach before sending a PR.

## License

[MIT](LICENSE)

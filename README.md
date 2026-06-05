# clikae · ｷﾘｶｴ

> **Your starting point for working with AI coding CLIs.** Type `clikae` and land on everything you were just doing — your recent sessions across every account and every engine (Claude Code, Codex, Gemini, Antigravity), each with a one-line recap of where you left off. Pick one and pick up where you were.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.5.11-blue.svg)](CHANGELOG.md)

> ⚠️ **Unofficial.** `clikae` is a community tool. It is not affiliated with, endorsed by, or sponsored by any of the CLI vendors it integrates with. "Claude" is a trademark of Anthropic, PBC; other CLI names are trademarks of their respective owners.

---

## What & why

You're juggling AI coding sessions across more than one account — two Claude subscriptions because one Max plan ran dry, a Codex login, maybe Antigravity too — in different terminals, on different projects, half of them unfinished. *Which one was that in? Which account? What was I even doing?* So you `/clear`, reopen, and re-explain the project to a fresh session.

`clikae` is the on-ramp that fixes it: type `clikae` and you land on your recent sessions across **every account and every engine**, newest first, each with a one-line **recap** of where you left off (read free from Claude's own session summary). Pick one, hit Enter, and you're back exactly where you were — right account, right session. _(It also cleanly switches any env-var CLI — gh, gcloud, kubectl, aws… — but AI coding CLIs are where it shines.)_

`clikae` is a small, pure-bash tool. The name is 切り替え — *switching* — so
**clikae is the verb**: `clikae <engine> <tank>` points an engine (a CLI like
claude, codex, gh) at one of your tanks (an account/config) and runs it. No verb
to memorise; the program name *is* the verb.

It:

1. Creates **isolated tank directories** for each engine (one folder per engine + tank).
2. Generates **shell aliases** (`claude-work`, `gh-personal`, …) you can use in a new terminal.
3. On macOS, generates **double-clickable `.app` launchers** that open a Terminal window with the right env vars set and a custom window title so you can tell them apart.
4. **Carries a live session to another tank** when one runs dry — `clikae to <tank>` keeps the same conversation going on the other account's quota (and `clikae to <other-engine>` hands a written brief across vendors, summarized **on-device** by a local model when you have one — `apfel`, `ollama`, or `llm` — so your session never leaves your machine, costs nothing, and works offline).
5. **Runs headless tasks across tanks** — `clikae burn <engine> <tank> --artifact <path> -- <cmd>` runs a task on a tank, verifies it by the **artifact** it produces (never the exit code — `codex exec` exits 0 even when it hit its limit), and re-fires it on the next tank if one runs dry. The headless sibling of `clikae to`.
6. Cleans up after itself when you're done with a tank.

It works for any CLI that selects its config via an environment variable (or a flag), ships with built-in adapters for **Claude Code, OpenAI Codex, GitHub CLI, gcloud, Docker, Helm, kubectl, AWS, Azure CLI, npm, Terraform, Pulumi, and Vercel** (plus real **per-account multi-tank for Antigravity / agy** — each tank carries its own Google login via the macOS Keychain), and adding a new one is ~10 lines of bash. No daemons, no global state, no network calls — every line is auditable.

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

Type **`clikae`** any time to land on your **home board**: your recent sessions
across every account and engine (newest first, each with a one-line recap), above
your tanks in a single **burn order** you can rearrange with `[` / `]`. Every tank
wears a traffic-light **fuel dot** — 🟢 ready · 🔴 dry (with the vendor's reset
time) · ○ no reading — so one glance tells you which account still has gas in it:

```bash
clikae                            # your home board (run `clikae doctor` for a health check)
```

## Documentation

- **[Installation](docs/installation.md)** — Homebrew, from source, `curl | bash`, PATH setup.
- **[Usage](docs/usage.md)** — full command reference, the `migrate` command, how it works, supported CLIs.
- **[Grammar](docs/grammar.md)** — the language clikae speaks: why it's a verb, engine/tank/fuel, `clikae to`, agy.
- **[Troubleshooting](docs/troubleshooting.md)** — aliases not loading, Gatekeeper on `.app`, AWS profiles, undoing rc edits.
- **[Expectations](docs/EXPECTATIONS.md)** — "is this a bug?" — behaviours that look surprising but are deliberate (the fuel dot, codex resume/time, agy's global switch, …).
- **[Claude on macOS](docs/claude-on-macos.md)** — why migrating asks you to log in again (Keychain), and why the startup screen can look different (it's not clikae).
- **[Adding an adapter](docs/adding-an-adapter.md)** — teach clikae a new CLI.

## Roadmap

- **v0.1** — core CLI, claude adapter, macOS `.app` launchers, install script.
- **v0.2** — 7 built-in adapters (claude, gh, gcloud, docker, helm, kubectl, aws), `bats-core` test suite + CI on Linux & macOS, `migrate` command for hand-rolled setups.
- **v0.3** — Homebrew tap, `migrate --keep-login` (carries the macOS Keychain token across a move), split docs.
- **v0.4** — Four more adapters (`az`, `npm`, `terraform`, `pulumi`; 11 total) and a `migrate` guard against moving an in-use config dir.
- **v0.5** — the **fuel-tank grammar**: clikae becomes the verb (`clikae <engine> <tank>`), one `clikae to` carries a session onward (same engine resumes, another engine gets a written brief), Antigravity/agy folded into the same verbs, an engine/tank/fuel vocabulary throughout. See [docs/grammar.md](docs/grammar.md).
- **v0.5.3** — the home board became a single, reorderable **burn order** (`[` / `]`); switch a tank by name alone (`clikae cver`); interface localisation (en-US / ja-JP / zh-TW, `clikae lang`); and a **BETA supervised launch** that carries you to the next tank automatically when you hit the limit (`clikae auto`, claude-only for now — feedback very welcome).
- **v0.5.4** — the board's status dot became a **fuel gauge, not a "you are here"**: 🟢 ready · 🔴 dry (the vendor's verbatim reset time) · ○ no reading (engines clikae can't read from disk, e.g. codex — never a guessed green), plus a **BETA** yellow that relays Claude's own weekly-usage notice. See [docs/DESIGN-board-fuel-dots.md](docs/DESIGN-board-fuel-dots.md).
- **v0.5.5** — **Antigravity / agy becomes real multi-account** (each tank carries its own Google login via the macOS Keychain); **codex sessions join the home board's Continue list** (true cross-engine resume); **`clikae burn`** runs a headless task on a tank and re-fires it on the next when one runs dry (verified by artifact, not exit code); and a **cross-shell in-use guard** so `rename`/`migrate`/`remove` won't move a tank a session in another terminal is still using.
- **v0.5.6** — hardened that in-use guard to be truly best-effort: a restricted `ps` (CI runners, locked-down hosts) no longer aborts `rename`/`migrate`/`remove`.
- **v0.5.7** — the board shows only **burnable fuel tanks** (tool-CLI tanks live in `clikae tanks`); **`clikae app --board`** makes a launcher for the menu, not one tank; **Ghostty launchers** use a trusted config file (no "Allow Ghostty to execute…" dialog) and are re-signed for Apple Silicon; and switching to a tank whose CLI isn't installed gives a **helpful install hint** instead of `exec: … not found`.
- **v0.5.11** — reliability + honesty polish: `clikae watch` starts dependably; `clikae to codex` says "fresh start" instead of promising a resume it can't do; auto-reroute won't dead-end on agy; `clikae tanks` shows an agy tank's real account; and a new **["is this a bug?" Expectations guide](docs/EXPECTATIONS.md)** for behaviours that look surprising but are deliberate. Plus doc corrections (the board's language key is `l`, not `h`).
- **v0.5.10** — **`burn` won't spend the quota you're using.** Its auto-reroute now skips a tank an interactive session is live on (`--allow-active` to override) and skips tanks that share an already-dry account — closing the original "燒爆" footgun (a headless job rerouting onto your live conversation's tank). Plus a clearer agy burn-refusal + a `clikae tanks` footnote that agy is interactive-only.
- **v0.5.9** — **a quiet "✨ update available" notice** on the board (codex-style: update now / skip / skip-this-version; auto-detects `brew` vs `curl`, throttled + opt-out via `CLIKAE_NO_UPDATE_CHECK`); **carry a session to another tank even when it's not dry** (a third Continue choice — a deliberate account switch that keeps the conversation); a **"· seen HH:MM" tag** on codex/agy reset times so a snapshot reset reads honestly (codex reports UTC headless); and `burn --timeout` now **discloses** it needs coreutils (plus the two world-class P1 fixes — see [docs/HANDOFF-world-class-gaps.md](docs/HANDOFF-world-class-gaps.md)).
- **v0.5.8** — **a dry tank carries you onward instead of dead-ending.** Pressing Enter on a Continue row whose tank is out of fuel now offers to **relay the session onto the next *fuelled* tank** — and the carry-onward selector became a **ring**: it circles the whole burn order (a tank earlier in your order is still a reserve), prefers a fuelled **same-engine** tank (a real resume), and skips any tank whose **account** is already exhausted (a sibling on the same login shares the dead quota). Plus **codex tanks can now show a red dot** — its exec-only limit is persisted so the board can read it later. See [docs/DESIGN-board-fuel-dots.md](docs/DESIGN-board-fuel-dots.md).
- **v1.0** *(planned)* — macOS menu bar app (`gui/ClikaeMenuBar`): tanks per engine, active one marked, click-to-launch, per-engine `to`. Build-verified AppKit skeleton; signed `.app` packaging next.

## Contributing

PRs are very welcome — especially new adapters. Please read [docs/adding-an-adapter.md](docs/adding-an-adapter.md) first. For non-trivial changes, open an issue to discuss the approach before sending a PR.

## License

[MIT](LICENSE)

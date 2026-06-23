# clikae

> Type `clikae` and land back on your recent sessions — across every account and engine (Claude Code, Codex, Antigravity), each with a one-line recap of where you left off. Pick one and keep going.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.6.0-blue.svg)](CHANGELOG.md)

🌐 [日本語](https://cver.net/ja-jp/oss/clikae) · [한국어](https://cver.net/ko-kr/oss/clikae) · [繁體中文](https://cver.net/zh-tw/oss/clikae)

> ⚠️ **Unofficial.** `clikae` is a community tool. It is not affiliated with, endorsed by, or sponsored by any of the CLI vendors it integrates with. "Claude" is a trademark of Anthropic, PBC; other CLI names are trademarks of their respective owners.

---

## What & why

You're juggling AI coding sessions across more than one account — two Claude subscriptions because one Max plan ran dry, a Codex login, maybe Antigravity too — in different terminals, on different projects, half of them unfinished. *Which one was that in? Which account? What was I even doing?* So you `/clear`, reopen, and re-explain the project to a fresh session.

`clikae` is the on-ramp that fixes it. The home board lists those sessions newest first, each with its one-line **recap** read free from Claude's own session summary; pick one, hit Enter, and you're back — right account, right session. _(It also cleanly switches any env-var CLI — gh, gcloud, kubectl, aws… — but AI coding CLIs are where it shines.)_

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
7. **Your connectors ride along.** A tank isolates the claude.ai login, so the MCP connectors configured on that account come with it — switch tank and the Stripe, Drive, or WordPress tools live in your session switch too. clikae doesn't manage MCP; this is per-account isolation paying off. One more thing that follows the person, not just model auth and memory.

It works for any CLI that selects its config via an environment variable (or a flag), ships with built-in adapters for **Claude Code, OpenAI Codex, GitHub CLI, gcloud, Docker, Helm, kubectl, AWS, Azure CLI, npm, Terraform, Pulumi, and Vercel** (plus real **per-account multi-tank for Antigravity / agy** — each tank carries its own Google login via the macOS Keychain), and adding a new one is ~10 lines of bash. No daemons, no global state, and exactly one opt-out network call (a throttled update check — `CLIKAE_NO_UPDATE_CHECK=1` silences it) — every line is auditable.

## Command your fleet — cost-aware, across vendors

Once you have more than one account on more than one engine, the home board
stops being a switcher and starts being a **control plane**: one person directing
a fleet of AI coding CLIs, each burning its **own** subscription quota, none of
them quietly eating the budget you're using for your main session. clikae knows
where each engine keeps its config and transcripts, how each one signals a usage
limit, and which tank still has fuel — so the arbitrage is two commands, not a
bag of `--resume` flags and environment-variable juggling:

- **Hit a wall, keep going — `clikae to`.** When the tank you're on runs dry,
  carry the *same live conversation* onto another tank's quota (a real
  `--resume`), or hand it across vendors as a written brief — Claude → Codex →
  Antigravity. The cross-vendor brief is summarized **on-device** by a local
  model when you have one (`apfel`, `ollama`, or `llm`), so the session never
  leaves your machine, costs nothing, and works offline.

- **Fan the grunt work out — `clikae burn`.** Run a long, headless task on a
  tank and verify it by the **artifact it produces** — never the exit code
  (`codex exec` exits `0` even when it hit its limit). When that tank runs dry,
  clikae **re-fires the same task on your next reserve tank automatically**,
  skipping any account that shares a dried login and never reaching for the tank
  your interactive session is live on. The expensive supervisor stays asleep;
  the cheap workers burn whichever account still has gas.

- **Spot a wall before it's a wall — `clikae watch`.** Tail a running engine,
  notice when it's about to go dry, and offer (or auto-carry) the session onward
  to the next tank in your burn order.

Both `to` and `burn` follow one rule — *aggregate, never mutate the source.* A
session or a memory slice is carried as a **copy**; the tank you came from is
left exactly as it was. No proxy, no daemon, no traffic interception — clikae
reshapes *where your state lives*, it never sits in the middle of your requests.

Driving this headless — or letting an **LLM agent** drive it (fanning a job across
accounts, best-of-N across vendors)? The **[orchestration playbook](docs/orchestration.md)**
is the field guide: when to use `burn` vs `conduct`, the rules that keep it honest
(judge by the artifact, never the exit code), the misconfigured-burn anti-pattern,
and how to see your fleet from inside a Claude Code session.

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

> **Platform.** clikae is a **macOS / Linux** tool — it's bash, and that's the point. A **PowerShell module** lives in
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
- **[Orchestration](docs/orchestration.md)** — driving clikae headless (or letting an agent drive it): `burn` vs `conduct`, the honesty rules, anti-patterns, seeing your fleet.
- **[Expectations](docs/EXPECTATIONS.md)** — "is this a bug?" — behaviours that look surprising but are deliberate (the fuel dot, codex resume/time, agy's global switch, …).
- **[Claude on macOS](docs/claude-on-macos.md)** — why migrating asks you to log in again (Keychain), and why the startup screen can look different (it's not clikae).
- **[Adding an adapter](docs/adding-an-adapter.md)** — teach clikae a new CLI.

## Milestones

- **v0.5 — the fuel-tank grammar.** clikae became the verb (`clikae <engine> <tank>`),
  `clikae to` carries a session onward (same engine resumes; another engine gets a
  written brief), and the engine/tank/fuel vocabulary landed throughout. See
  [docs/grammar.md](docs/grammar.md).
- **v0.5.4 — the fuel gauge.** The board's dot stopped meaning "you are here": 🟢 ready ·
  🔴 dry (the vendor's verbatim reset time) · ○ no reading — never a guessed green. See
  [docs/DESIGN-board-fuel-dots.md](docs/DESIGN-board-fuel-dots.md).
- **v0.5.5 — real multi-account agy, and `burn`.** Each Antigravity tank carries its own
  Google login via the macOS Keychain; `clikae burn` runs headless tasks across tanks,
  verified by the artifact they produce, never the exit code.
- **v0.5.12 — the quality punch-list hit empty.** State schema versioning landed; since
  then it's been polish. The full story, version by version: [CHANGELOG.md](CHANGELOG.md).
- **v0.6 — vertical orchestration.** `clikae conduct` (BETA) fans one prompt across N
  accounts in parallel, each running headless read-only on its own tank, and hands back
  every leg's output plus an honest captured/dry table — it doesn't pick the winner, you
  do. `clikae git-id` gives a tank its own commit identity so commits aren't stamped with
  the engine's account email; `clikae burn --prompt-file` / `--prompt` / `--add-dir` fill
  in each engine's headless-write flags for you. Patches since (0.6.1, 0.6.2) are
  correctness and string fixes — see [CHANGELOG.md](CHANGELOG.md).
- **v1.0 — someday.** A macOS menu bar app (`gui/ClikaeMenuBar`) exists as a
  build-verified skeleton; it ships when it earns it.

## Testing & quality

Pure bash, no runtime dependencies, held to a deliberate bar:

- **`bats-core` suite (300+ tests)**, run in **CI on macOS *and* Ubuntu** on every push/PR.
- **`shellcheck` clean** (zero warnings) across `bin/` and `lib/`.
- The **Homebrew formula is `brew audit`- and `brew test`-clean**; each release pins and verifies the tarball SHA‑256.
- Behaviour-critical paths — the `burn` headless runner, limit/dry detection, the in-use guard — have dedicated regression tests, several added straight from real dogfood failures.

Developed and hand-tested on **macOS**; Linux is covered by CI. **Linux / WSL / BSD field reports and PRs are very welcome** (see [Contributing](#contributing)) — the thing to watch is `clikae burn --artifact` behaviour.

## Contributing

PRs are very welcome — especially new adapters. Please read [docs/adding-an-adapter.md](docs/adding-an-adapter.md) first. For non-trivial changes, open an issue to discuss the approach before sending a PR.

## License

[MIT](LICENSE)

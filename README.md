# clikae (CLI-Kae / ｷﾘｶｴ)

> Type `clikae` and land back on your recent sessions — across every account and engine (Claude Code, Codex, Antigravity), each with a one-line recap of where you left off. Pick one and keep going.
>
> *"Kirikae" (切り替え, ki-ri-ka-e) is Japanese for "switching".*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-v0.12.0-blue.svg)](CHANGELOG.md)
[![Docs](https://img.shields.io/badge/docs-clikae.cver.net-2563eb.svg)](https://clikae.cver.net)

📖 **Docs:** [clikae.cver.net](https://clikae.cver.net) — humans read it, agents call `/mcp`.

🌐 [日本語](https://cver.net/ja-jp/oss/clikae) · [한국어](https://cver.net/ko-kr/oss/clikae) · [繁體中文](https://cver.net/zh-tw/oss/clikae)

> ⚠️ **Unofficial.** `clikae` is a community tool. It is not affiliated with, endorsed by, or sponsored by any of the CLI vendors it integrates with. "Claude" is a trademark of Anthropic, PBC; other CLI names are trademarks of their respective owners.

---

## What & why

You're running more AI coding sessions than you can hold in your head — a
handful of terminals across two or three engines, half of them mid-task.
*Which window was that in? Which account? What was I even doing?* So you
`/clear`, reopen, and re-explain the project to a fresh session.

`clikae` is the on-ramp that fixes it. Type `clikae` and the home board lists
your recent sessions newest first — **across every engine and account** — with
a one-line **recap** read free from the engine's own session summary where it
keeps one (Claude Code today; other engines show the session's opening title).
Pick one, hit Enter, and you're back: right account, right session, right
directory.

Underneath the board sits one idea. Your AI work has two halves. The model
half is rented — engine, capability, quota; the vendor's, and the vendors are
at war (good: you win). The other half is **yours**: who you are, what you
know, where you left off, what should leave no trace. Today that half is
locked inside each vendor's config directory, so switching engines means
amnesia. clikae is the thin, all-local layer that keeps **your half
portable** — swap the engine, keep everything that makes it yours.

Concretely:

1. **Sessions that survive.** The board and recap above; `clikae resume`
   reaches back to any past session by title, across every account and
   engine — no UUID copy-paste, no "which terminal was that".
2. **Identities that stay separate.** One isolated **tank** per account: its
   login, its MCP connectors riding along, its own git commit identity
   (`clikae git-id`, stamped into your shell by `clikae env`), its own memory. One person, several hats — a client's
   world never crosses into another's unless you opt in, and `clikae solo`
   walls a tank off from everything.
3. **Memory that outlives the engine.** `clikae memory share` points several
   of your tanks at ONE vendor-neutral markdown brain — a **Soul** you own,
   so no single model holds your working context hostage. Change engines;
   it still knows who you are and where the work stands.
4. **Sessions that leave no trace, when you choose.** `--ephemeral` runs a
   tank with throwaway memory: the session happens, the remembering doesn't.
5. **And yes: more than one account.** `clikae to` carries a live
   conversation onto another tank; `clikae burn` re-fires headless work on
   your reserve. Powerful, and partly in the vendors' terms gray zone — where
   the line is, in plain dated language:
   **[docs/terms-and-your-accounts.md](docs/terms-and-your-accounts.md)**.

It also cleanly switches any env-var CLI (gh, gcloud, kubectl, aws, …) — a
footnote, not the pitch. It works for any CLI that selects its config via an
environment variable (or a flag), ships with built-in adapters for **Claude
Code, OpenAI Codex, GitHub CLI, gcloud, Docker, Helm, kubectl, AWS, Azure
CLI, npm, Terraform, Pulumi, and Vercel** (plus real per-account multi-tank
for **Antigravity / agy**, each tank carrying its own Google login via the
macOS Keychain), and adding a new one is ~10 lines of bash. No daemons, no
proxy, no global state, exactly one opt-out network call (a throttled update
check — `CLIKAE_NO_UPDATE_CHECK=1` silences it). It's bash you can actually
read, and **MIT** — free to run, fork, or build into a commercial product or
paid client work.

## In practice

**Monday, eight unfinished threads.** You type `clikae`. The board lists the
weekend's sessions newest first; one recap reads *"fixing the auth redirect —
next: retry the callback test"*. Enter. You're back in that directory, that
account, that conversation — no re-explaining.

**Three clients, three worlds.** One tank per client: its login, its MCP
connectors, its memory, its own git commit identity (`clikae git-id`, applied
through `clikae env`). `clikae acme` and you're wearing that hat — nothing
crosses into another client's world unless you opt in. Switching clients is
one word, not a checklist.

**New model week.** A new engine drops and everyone says it's the one. Your
tanks share a Soul, so the new engine reads the same markdown brain the old
one wrote — try it for an afternoon with your context intact, and walk back
out just as easily. The vendors compete; your memory doesn't care who wins.

**Some sessions shouldn't be remembered.** Get a cold read on your own plan
from a session with no memory of you: `clikae claude work --ephemeral`. The
reviewer doesn't know what you believe, and the tank's long-term memory never
learns the session happened. (True story: clikae's own releases are red-teamed
exactly this way.)

## More than one account

Some of us do run several accounts — a work and a personal subscription, one
per client, or a reserve for long agent runs. clikae knows where each engine
keeps its config and transcripts, how each one signals a usage limit, and
which tank still has fuel, so moving between your own accounts is two
commands, not a bag of `--resume` flags and environment-variable juggling.

One honest note first: carrying the **same task** past a usage limit on
another account sits in the vendors' terms gray zone (different accounts for
different purposes is explicitly fine). Where the line is, with the actual
policy language and dates:
**[docs/terms-and-your-accounts.md](docs/terms-and-your-accounts.md)** —
clikae shows it to you once before your first carry, then stays out of the way.

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

## Swap the engine, keep the soul — shared memory

A tank holds more than fuel — it holds the engine's long-term **memory**. `clikae
memory share <group>` points several of your own tanks at ONE vendor-neutral
markdown store — a **Soul** you own — so they read and write a single brain
**across engines**. Hit a Claude limit, carry on in Codex, and it already knows who
you are and where the work stands. Swap the engine, keep the soul.

- Sharing is **per-tank, whole-brain** — every project directory that tank ever
  runs in reads and writes the same store, not just wherever you happened to
  run `memory share`. **claude** fans each directory's memory dir into the
  store with a symlink; **codex** and **agy** read a fenced pointer note
  (`AGENTS.md` / `GEMINI.md`) to the same markdown files — no translator, no
  drift, it's literally the same files.
- 🔴 Sharing is **opt-in and per-tank**; clikae never auto-crosses accounts, and
  crossing your own is announced. The store is seeded by copy and `clikae memory
  isolate` reverses it.
- `clikae solo` walls a tank off — a bot or persona that lives on your own account —
  so it's out of the fleet: never relayed, burned, watched, or shared.

It carries *continuity and context*, not the model's capability — no phantom "same AI
on a different engine." See **[docs/memory.md](docs/memory.md)**.

Driving this headless — or letting an **LLM agent** drive it (fanning a job across
accounts, best-of-N across vendors)? The **[orchestration playbook](docs/orchestration.md)**
is the field guide: when to use `burn` vs `conduct`, the rules that keep it honest
(judge by the artifact, never the exit code), the misconfigured-burn anti-pattern,
and how to see your fleet from inside a Claude Code session. Routing cheap breadth to
Antigravity? The **[agy dispatch recipe](docs/agy-dispatch.md)** is the one engine an
agent fumbles most — read it first so an agy leg returns real work, not a blank.

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

> **Platform.** clikae is a **macOS / Linux** tool — it's bash, and that's the point.
> **On Windows, use WSL** — it's a real Linux userspace, so clikae runs there
> unmodified; no separate port needed. A **PowerShell module** for native Windows
> (no WSL) lives in [`powershell/`](powershell/) but is **community-contributed and
> unsupported**: it isn't part of the maintained grammar and its CI is informational
> only. Windows users very welcome to drive it — PRs appreciated.

## 30 seconds

```bash
clikae init claude work --alias   # create a tank (+ a `claude-work` alias)
clikae claude work                # switch to it and run — the bare verb
clikae                            # any time later: land on your sessions
```

Need the same conversation on another tank — or another engine?

```bash
clikae to personal                # carry the live session to tank `personal`
clikae to codex                   # or across engines (a written brief)
```

Type **`clikae`** any time to land on your **home board** — an interactive cockpit.
It lists your recent sessions across every account and engine (newest first, each
with a one-line recap), above your tanks laid out as **Tanks / Solo / Resume** in a
single **burn order**. Arrow-key to any tank and act on it with one keystroke: Enter
opens it · `r` relays your live session in · `m` opens the memory (Soul) dial · `s`
toggles solo · `[` / `]` reorder. Every tank wears a traffic-light **fuel dot** —
🟢 ready · 🔴 dry (with the vendor's reset time) · ○ no reading — so one glance tells
you which account still has gas in it:

```bash
clikae                            # your home board (run `clikae doctor` for a health check)
```

## Documentation

- **[Installation](docs/installation.md)** — Homebrew, from source, `curl | bash`, PATH setup.
- **[Usage](docs/usage.md)** — full command reference, the `migrate` command, how it works, supported CLIs.
- **[Grammar](docs/grammar.md)** — the language clikae speaks: why it's a verb, engine/tank/fuel, `clikae to`, agy.
- **[Memory (Soul)](docs/memory.md)** — share one markdown brain across your tanks and engines; what stays isolated, and `clikae solo`.
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
- **v0.7 — agy joins the fan-out.** `clikae conduct --leg agy/<tank>` lets Antigravity
  run a read-only best-of-N leg alongside claude/codex, so cheap breadth rides your agy
  quota — on its active tank only (it's a global single-account engine). The recipe for
  driving agy headless without firing a blank is now baked into `clikae agy --help` and
  [docs/agy-dispatch.md](docs/agy-dispatch.md).
- **v0.8 — resume, picked from a board.** `clikae resume` reaches *backward* to a past
  session by id across every tank (claude/codex/antigravity); run with no id it opens an
  interactive picker — filter, page, pick by title, no UUID to copy — and `[R]` opens it
  from the dashboard. `clikae resume cleanup` reclaims disk from old session data. The
  home board also got much faster (several seconds → well under one on multi-GB tanks) by
  reading only the transcript slices it needs and scanning each tank's fuel state once.
- **v0.9 — the Soul layer.** `clikae memory share|isolate|status` gives several of
  your own tanks one shared markdown brain **across engines** — claude symlinks its
  memory dir into the store; codex and agy read a pointer note to the same files, no
  translator, no drift. Swap the engine, keep the soul. `clikae solo` walls a tank off
  from the fleet, and the home board became an **interactive cockpit** (press `m` for
  the memory dial, `s` to solo) laid out as Tanks / Solo / Resume. See
  [docs/memory.md](docs/memory.md).
- **v1.0 — someday.** A macOS menu bar app (`gui/ClikaeMenuBar`) exists as a
  build-verified skeleton; it ships when it earns it.

## Testing & quality

Pure bash, no runtime dependencies, held to a deliberate bar:

- **`bats-core` suite (450+ tests)**, run in **CI on macOS *and* Ubuntu** on every push/PR.
- **`shellcheck` clean** (zero warnings) across `bin/` and `lib/`.
- The **Homebrew formula is `brew audit`- and `brew test`-clean**; each release pins and verifies the tarball SHA‑256.
- Behaviour-critical paths — the `burn` headless runner, limit/dry detection, the in-use guard — have dedicated regression tests, several added straight from real dogfood failures.

Developed and hand-tested on **macOS**; Linux is covered by CI. **Linux / WSL / BSD field reports and PRs are very welcome** (see [Contributing](#contributing)) — the thing to watch is `clikae burn --artifact` behaviour.

## Contributing

PRs are very welcome — especially new adapters. Please read [docs/adding-an-adapter.md](docs/adding-an-adapter.md) first. For non-trivial changes, open an issue to discuss the approach before sending a PR.

## License

[MIT](LICENSE)

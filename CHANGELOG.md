# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The interactive board leads with "continue".** When this directory has a
  recent session you can resume, `clikae` now shows a **續上次 / continue
  headline** at the top — the most recent session across all your tanks, titled
  by Claude's own ai-title, with `⏎ 接回` to reopen it (`clikae <engine> <tank>
  -- --resume <id>` under the hood). It only appears for an engine that can
  actually resume by id (new optional `adapter_resume_args` hook), so the
  affordance never lies, and it's absent in a brand-new directory. The board also
  pins the logo top-right on wide terminals, no longer flickers on each keypress
  (homes + overwrites in place instead of a full-screen clear), and adds an `x`
  key to open the selected tank **無痕** — with throwaway memory (`--ephemeral`),
  a clean amnesiac session that leaves nothing behind. Tank rows now collapse to
  a status dot + name, expanding to the account, alias, and reset time only for
  the selected row (a hover detail), so a long list reads at a glance.
- **On-device handoff briefs — local-first, private, free.** When you carry a
  session across engines (`clikae to <other-engine>`, `clikae handoff`), clikae
  now auto-detects a LOCAL model already on your machine — `apfel` (Apple's
  on-device Foundation model, macOS 26), `ollama`, or `llm` — and writes the
  brief **on-device**. Nothing is bundled or installed by clikae; your session
  content (which may include source or secrets) never leaves the machine to make
  the handoff, it costs nothing, and it works offline. The choice is announced
  and fully overridable (`$CLIKAE_HANDOFF_SUMMARIZER`), can be turned off with
  `CLIKAE_HANDOFF_AUTOLOCAL=0`, and always falls back to the dependency-free raw
  extract. The transcript is first cleaned into a compact digest (capped via
  `CLIKAE_HANDOFF_CONTEXT_CHARS`, default 8000 chars) so it fits a small
  on-device model's context — which also yields more accurate, less hallucinated
  briefs than feeding a raw JSONL tail.

### Changed

- **Session titles now use Claude's own AI-generated name.** Claude Code writes
  a human-readable title into each transcript (`{"type":"ai-title",…}`, e.g.
  _"Lucky number confirmation"_) — the same name it shows in its session list.
  `clikae relay`'s preview card and session picker now prefer that title over
  the raw opening prompt, for free (no local model). Sessions without one — and
  other engines — fall back to the opening user message as before.

## [0.5.1] — 2026-06-01

### Added

- **A responsive welcome screen with the clikae logo.** First-run `clikae` (no
  tanks yet) now shows the logo (`assets/logo.txt`, bright-cyan): on a wide
  terminal the copy sits **beside** it (logo left, text right, placed with
  cursor-column moves); on a narrow terminal or a pipe it **stacks** — reflowing
  to the terminal width like a responsive page. Width is read with `stty size`
  (not `tput cols`, which returns the terminfo default inside a command
  substitution, so it can't see a narrow window). The everyday tank board is
  unchanged (no logo — it would bury your tanks). `install.sh` and the Homebrew
  formula now ship the `assets/` directory.

## [0.5.0] — 2026-06-01

### Fixed

- **`clikae to` / `relay` / `handoff` now auto-detect the source after a bare
  switch.** The switch, the aliases, and the `.app` all run the engine with a
  prefix assignment that never reaches the parent shell, so after a session
  `$CLAUDE_CONFIG_DIR` was unset and `clikae to <other>` couldn't tell which tank
  you were on (surfaced by the real-claude dogfood). Source detection now falls
  back, when no env var is set, to **the tank with this directory's most recent
  transcript** — "the session I was just in here" — so the headline
  switch → work → `to` flow works from one shell. Stateless (no breadcrumb);
  works regardless of how the session was launched.
- **Dogfood cleanups (v0.5.0 real-claude pass):** the home board's launch hint
  teaches the bare switch instead of `run`; the relay preview shows a real title
  for sessions whose opening message is a plain `"content"` string (current
  Claude Code stored it as a string, not a `text` array, so it read
  "(no preview)"); and the agy takeover is described honestly as one `[y/N]`
  confirmation (not "multi-confirm").

### Changed

- **clikae is a macOS / Linux tool; Windows support is now community/unsupported.**
  It's bash, and that's the pitch ("every line is auditable"). The PowerShell
  module in `powershell/` is no longer part of the maintained grammar (it lacks
  the v0.5 fuel-tank grammar) — kept as a community-contributed port, with its
  Windows CI job made informational (`continue-on-error`, never gates a release).
  Windows contributors are welcome to carry it forward. README/`powershell/README`
  updated; the maintained suite is bats (now with every assertion enforced —
  `set -e` + `|| false` on `[[ … ]]`, see `tests/README.md`).

### Added

- **`clikae env <engine> <tank>`** — print `export VAR="value"` lines to `eval`,
  the explicit way to put the current shell *on* a tank so the engine's own
  command and `clikae status` / `to` see it: `eval "$(clikae env claude work)"`.
  Flag-strategy engines (no config env var) say there's nothing to export.

- **`clikae <engine> <tank> --ephemeral` — run with throwaway memory.** For the
  leave-no-trace run: the engine's long-term memory is pointed at a `mktemp -d`
  throwaway that's discarded on exit, while the tank's real memory is stashed
  aside and restored untouched. Login and transcripts are normal — only the
  memory store is throwaway. Runs the engine as a child (not `exec`) so cleanup
  fires; a crashed run self-heals on the next `--ephemeral`. Engine-gated by a new
  optional adapter hook `adapter_memory_dir` (claude defines it; others reject it
  cleanly). Honest scope: clikae guarantees the *memory dir* is throwaway, not
  that the engine "remembers nothing anywhere" (caches/history/Keychain are out of
  reach). First of the §10 "memory control plane" (docs/grammar.md §10.4); bats in
  `tests/bats/ephemeral.bats`.

- **The fuel-tank grammar — clikae is now the verb.** The name is 切り替え
  (*switching*), so the headline action carries no verb of its own: **`clikae
  <engine> <tank>`** switches an engine to one of your tanks and runs it (`run` is
  a hidden alias). One **`clikae to <target>`** carries your current session
  onward — same engine resumes the conversation, a different engine gets a written
  brief — replacing the separate `relay`/`handoff` verbs (kept as hidden aliases),
  with the mechanism announced at runtime. Listing is **`clikae tanks`** (`list`
  stays as an alias). The vocabulary is **engine** (a.k.a. CLI) + **tank** (a.k.a.
  profile) + **fuel/dry** throughout help, the dashboard, `status`/`doctor`/`info`
  headers, and all messages; the on-disk `profiles/` layout and core function
  names are unchanged. The full design lives in `docs/grammar.md` (the SSOT), with
  §10 recording the open "memory control plane" frontier. A session-aware guard
  only prompts carry-vs-fresh when the current tank is over quota. bats 200/200.

- **Antigravity (agy) folds into the same verbs — no special subcommand tree.**
  agy hardcodes `~/.gemini` and ignores env vars, so clikae can't switch it
  per-shell. It now uses the **same verbs as every engine**, via an opt-in,
  reversible symlink-swap power mode: `clikae init agy <tank>` (the first one
  warns and asks before taking `~/.gemini` over, backs it up, migrates your login
  into a `default` tank), `clikae agy <tank>` (repoint the symlink — refusing
  while `agy` is live — and run, with a global-switch notice), `clikae remove agy
  <tank>` (removing the last tank offers to restore a normal `~/.gemini`), and
  `clikae agy --release` (restore a single-account `~/.gemini`, keep the tanks).
  The canonical engine name is **`agy`** (`antigravity` is a hidden long alias).
  Replaces the earlier `antigravity enable/add/use/disable` subcommand tree
  (which would have collided with the bare switch). Also fixed a latent crash
  where `clikae list`/`tanks` died on agy tanks (a missing-adapter `exit 1`
  propagating through `set -e`). bats rewritten (10 tests) against an isolated
  sandbox so no real `~/.gemini` is touched.

- **`clikae demo` — a guided tour in a throwaway sandbox.** A non-interactive,
  ~30-second walkthrough that runs entirely under a temp `CLIKAE_HOME`: it shows
  two fully isolated accounts of one CLI, the live tank board (one marked active
  in the shell), a fuel pool, and the relay payoff — then deletes the sandbox.
  Touches nothing real (not your `~/.clikae`, logins, or shell rc); the accounts
  are simulated (fake `.claude.json` labels), so it needs no installed CLI and no
  second account. The first thing you can safely hand a newcomer. Covered by bats
  (the tour runs, the real home is untouched, the sandbox is cleaned up).
- **Bare `clikae` now opens a home dashboard — your "tank board".** Typing
  `clikae` with no arguments used to print the help wall; it now opens a
  glanceable dashboard, the screen clikae wants to be the first thing you type:
  every profile (tank) grouped by CLI, the one **active in this shell** marked,
  the logged-in account and the **real managed alias name** beside each, an
  **"Also available"** section of relay-capable CLIs/targets you can open without
  a tank yet (e.g. `codex`, `agy` — chosen by who can take a handoff, so tools
  like `gh`/`npm` aren't listed), and the fuel-pool fall-through order.
  - On a **real terminal it's an interactive launcher**: ↑/↓ (or j/k) to move,
    Enter to open the selected tank, `r` to relay this shell's live session into
    it (from whichever profile is active here), `n` to create a new tank
    (arrow-key CLI picker, then name it), `a` to rename a tank's shell alias,
    `d` to delete a tank (confirms first), `q`/Esc to quit (leaving the board on
    screen). The mutating keys (`n`/`a`/`d`) run their action and **return to the
    menu** rather than dropping you back to the shell, so you can do several in a
    row; only the launching keys (Enter / `r`) leave. It uses the alternate
    screen buffer so your
    scrollback is untouched, and falls back to the **plain-text board** whenever
    output isn't a TTY (a pipe, a script, the GUI) — set `CLIKAE_NO_INTERACTIVE`
    to force that.
  - With no profiles yet it shows a **welcome** that scans the machine and names
    the supported CLIs you actually have, plus the exact first command. The full
    command reference moved one keystroke away to `clikae help`.
  New **`clikae doctor`** is a read-only health check (which CLIs are installed
  and logged in, profile counts, `CLIKAE_HOME` / shell-rc / PATH, and targeted
  next steps); a shared read-only scanner (`lib/core/scan.sh`) backs both.
  Covered by bats (incl. guards that the last adapter row isn't dropped, the
  agent/target filter, and that colour escapes don't leak as literal text).
- **Machine-readable `--json` across the read commands (for the v1.0 GUI).**
  `clikae list --json`, `status --json`, `pool --json`, and `info --json` now
  emit structured output for the planned menu-bar app and for scripting. The
  three inventory/state views form a data trio: `list` (every profile across
  CLIs: `{cli, profile, account, path}`), `status` (active profile per CLI in
  this shell, with a `state` enum: active | default | external | flag |
  noadapter), and `pool` (the fall-through order: `{position, target, cli,
  profile}`). Each command builds **one canonical record** rendered by either
  the human table or the JSON array, so the two can't drift; JSON is escaped by a
  shared `lib/core/json.sh` (no jq). The PowerShell module gains the matching
  surface — a new **`Get-ClikaeStatus`** (the `clikae status` equivalent) plus a
  `-Json` switch on it and on `Get-ClikaeProfile`, with array output that holds
  up on Windows PowerShell 5.1. (`info`'s human view also stopped mangling the
  adapter list — `paste`'s alternating-delimiter quirk.)
- **`clikae handoff <cli> [<profile>]` — a portable session handoff brief.** The
  real pain when a tank runs dry mid-task isn't the lost conversation, it's that
  the *next* tank starts blind. `handoff` reads the current directory's most
  recent session (read-only) and writes a short, vendor-neutral brief — what's
  being worked on, what's done, what's next — that any other profile / model /
  vendor can pick up. With `$CLIKAE_HANDOFF_SUMMARIZER` (or `--summarizer <cmd>`)
  set to a **local or cheap model**, the session tail is piped to it and its
  output is the brief, so it costs nothing on the tank that just ran dry; with no
  summarizer you get a dependency-free raw extract (metadata + recent prompts),
  clearly labelled as raw. New optional adapter hook `adapter_transcript_path`
  (claude reads `<dir>/projects/<pwd-slug>/<id>.jsonl`; the slug rule now lives
  there and `adapter_relay` reuses it). Covered by bats. Pure bash/grep/sed — no
  jq, python, or network.
- **`clikae handoff … --to <target>` — switch model or vendor in one command.**
  After writing the brief, hand it straight to the next tank: it starts that
  target seeded with the brief as its opening prompt (exec, like `run`/`relay`).
  Targets are either another account of a *switchable* CLI — `--to codex/work`,
  `--to claude/b` — via a new optional adapter hook `adapter_start_with_prompt`
  (claude + codex), or a **handoff target**: a single-account vendor you can hand
  off to but can't profile-switch. First one: **`antigravity`** (`--to antigravity`
  starts Google's `agy -i` with the brief). Antigravity's CLI hardcodes `~/.gemini`
  with no config-dir override (verified on a real install), so it can't be a
  switchable adapter — handoff targets live in `lib/targets/` and stay out of the
  profile/adapter machinery (and the cross-language PS parity).
- **`clikae watch` + `clikae pool` — ambient relay (notice a dry tank, switch).**
  `watch <cli> [<profile>]` tails the current session's transcript and, when it
  looks like the tank ran dry, hands off to the next tank — **offering first** by
  default, or **automatically after a one-time consent** with `--auto` (it asks
  once, remembers in `$CLIKAE_HOME/auto-relay-consent`, then auto-switches and
  tells you). Where it goes next comes from the **fuel pool**: an ordered,
  user-owned list managed by `clikae pool add|remove|list` (or `--to <target>`
  to override). The handoff reuses `clikae handoff`, so a switchable target keeps
  going on its own quota. **Honesty caveat, also in the code and `--help`:** an
  interactive CLI hitting its limit gives no exit code and fires no hook, so the
  only signal is what the limit writes into the transcript — and the exact marker
  is *not yet confirmed against a real limit event*. The match pattern is a
  best guess, fully overridable (`--pattern` / `$CLIKAE_LIMIT_PATTERN`), and
  `clikae watch --check` reports whether it would fire on the current session so
  you can confirm/tune it the first time you actually get limited. The live tail
  loop is smoke-tested; detection, pool fall-through, and consent are bats-covered.
- **Fixed account-label extraction on real `.claude.json`.** The file is
  pretty-printed (`"emailAddress": "you@…"`, whitespace after the colon), which
  the extractor didn't match — and worse, the no-match `grep` propagated failure
  under `set -eo pipefail`, so `clikae list` / `status` aborted with exit 1 on any
  real, logged-in profile. Now tolerates the whitespace and never propagates a
  miss. (Both bugs were in the unreleased account-label work; caught dogfooding.)
- **Fixed an adapter-hook leak across adapters.** `load_adapter` now clears all
  adapter hooks before sourcing the next adapter, so an optional hook one adapter
  defines (e.g. `adapter_start_with_prompt`) is never inherited by another that
  doesn't — exposed by `handoff --to`, the first path to load two adapters in one
  process.
- **Account labels + `clikae rename` (stop squinting at `a`/`b`).** `clikae list`
  and `clikae status` now show an **ACCOUNT** column with the logged-in account
  where the adapter can read it — for claude, the email from `.claude.json` (via a
  new optional adapter hook `adapter_account_label`, pure grep/sed, no jq). New
  **`clikae rename <cli> <old> <new>`** renames a profile: moves the directory,
  rewrites the managed alias (keeping a custom alias name, else swapping the
  default `<cli>-<old>` → `<cli>-<new>`), and — for claude on macOS — carries the
  saved Keychain login across (reusing the `--keep-login` mechanism) so you don't
  re-login. It refuses if the target exists or the profile is in use in this shell
  (a data-integrity guard, like `migrate`). Covered by bats.
- **`flag` strategy + two new adapters (now 13).** Adds a `flag` adapter strategy
  for CLIs that have no config-directory env var and instead take a flag — via a
  new optional adapter hook `adapter_flag_args <dir>` that the alias / `.app` /
  `run` generators append after the binary. New adapters: **`codex`** (OpenAI
  Codex CLI, env-dir `CODEX_HOME` — a cheaper model/vendor to route work to) and
  **`vercel`** (flag strategy, `--global-config <dir>`). The alias/`.app` command
  assembly is centralised in `adapter_command`. `clikae status` reports `(n/a)`
  for flag-based CLIs (nothing to read from the environment). The PowerShell
  module mirrors all of this (codex + vercel in the adapter table, `flag`
  handling in the env/function/invoke/shortcut paths, new `Get-ClikaeFlagArgs`).
- **macOS menu bar app skeleton (`gui/ClikaeMenuBar`, v1.0 track).** A SwiftPM +
  AppKit `NSStatusItem` app that builds with the Command Line Tools (no Xcode):
  lists profiles grouped by CLI, check-marks the active one (`clikae status`),
  click-to-launch a profile (`clikae run`), a per-CLI **Relay → …** submenu
  (`clikae relay`), Refresh, and Quit. The CLI stays the source of truth — the
  app only shells out to it. Prefers Ghostty for the terminal it opens, falling
  back to Terminal.app. Build-verified; packaging as a signed `.app` is a future
  step.
- **`clikae app --terminal <app>` — choose the terminal the launcher opens.**
  In addition to Terminal.app (default), the generated `.app` can open **iTerm2**
  (`--terminal iterm2`) or **Ghostty** (`--terminal ghostty`). Terminal.app and
  iTerm2 are driven via their AppleScript scripting APIs; Ghostty has no
  window-opening CLI on macOS, so its launcher goes through
  `open -na Ghostty.app --args --title=… -e /bin/zsh -lc '…'` (env vars and
  spaces in paths preserved). The default target can be set with the
  `$CLIKAE_TERMINAL` environment variable. The chosen terminal must be installed;
  `app` fails with a clear message otherwise. Covered by bats (Ghostty path
  asserted when installed; the not-found path otherwise).
- **`clikae relay <cli> [<from>] <to>` — hand a live session to another profile.**
  clikae's origin story is keeping a second account because one account's quota
  runs out mid-task; `relay` makes that switch seamless. For Claude Code it copies
  the current directory's most recent transcript from the source profile into the
  target profile and resumes it (`claude --resume <id>`), so the conversation
  continues but new turns burn the target profile's quota. The source profile is
  never modified (relay copies, never moves), and with no transcript to carry it
  just starts a fresh session. The source profile is auto-detected from this
  shell's env var when only the target is given. Implemented via a new optional
  adapter hook `adapter_relay <from_dir> <to_dir>` (Claude-only; other adapters
  fall back to a plain start under the target). Covered by bats.
- **`clikae status [<cli>]` — show which profile each CLI is on in this shell.**
  Reads the live value of each adapter's env var and resolves it back to a clikae
  profile. Reports `(default)` when the var is unset and `(external)` when it
  points outside the clikae profile store. Foundational for the planned menu-bar
  GUI. Covered by bats.

## [0.4.0] — 2026-05-30

### Added

- **Four more built-in adapters (now 11 total).** `az` (Azure CLI, env-dir
  `AZURE_CONFIG_DIR`), `npm` (env-file `NPM_CONFIG_USERCONFIG` — a per-profile
  `.npmrc` holding registry auth tokens), `terraform` (env-file
  `TF_CLI_CONFIG_FILE` — Terraform Cloud / registry credentials) and `pulumi`
  (env-dir `PULUMI_HOME`). The two env-file adapters seed an empty config file
  on `init`. The Windows PowerShell adapter table is kept in sync.
- **Windows / PowerShell support (v0.4).** New `powershell/Clikae.psm1` module
  ports the tool to native Windows PowerShell — no bash required. It mirrors the
  built-in adapters and the profile-store layout, and since PowerShell aliases
  can't carry env vars it writes a sentinel-wrapped *function* (e.g.
  `claude-work`) into your `$PROFILE` instead of an alias. Verbs: `New-`/`Get-`/
  `Remove-`/`Invoke-ClikaeProfile`, `Add-ClikaeFunction`, `Get-ClikaeAdapter`,
  and a Windows-only `New-ClikaeShortcut` (`.lnk`). Backs up `$PROFILE` before
  editing and supports `-WhatIf`/`-Confirm`. Covered by a Pester suite
  (`powershell/Clikae.Tests.ps1`) run in CI on `windows-latest` under both
  PowerShell 7 and Windows PowerShell 5.1.
- **`clikae migrate` in-use guard.** `migrate` now refuses to move a config
  directory that the CLI is currently using in your shell — i.e. when the live
  `$CLAUDE_CONFIG_DIR` (or whichever env var the adapter uses) points at a dir
  slated to move. Previously this was only documented as a sharp edge; running
  `migrate` from inside the very session whose config dir was being moved could
  pull the directory out from under the live process and leave split state. The
  guard is not bypassed by `--force` (it protects data, it isn't a confirmation)
  and never blocks `--dry-run`.

### Changed

- CI: bumped `actions/checkout` to v5 (the v4 pin runs on the now-deprecated
  Node 20 runtime) and added a `windows-latest` Pester job.

### Fixed

- CI: the bats step now runs with `-r`, so the `tests/bats/adapters/`
  subdirectory is actually executed. It was previously skipped — `bats` does not
  recurse into subdirectories without the flag — meaning the adapter-listing
  tests never ran in CI.

## [0.3.0] — 2026-05-29

### Added

- **Homebrew tap.** `brew install CVERInc/clikae/clikae` now works, served from
  the [`CVERInc/homebrew-clikae`](https://github.com/CVERInc/homebrew-clikae)
  tap (formula tracks v0.3.0).
- **`clikae migrate --keep-login`.** On macOS, Claude Code stores its OAuth token
  in the login Keychain keyed by the `CLAUDE_CONFIG_DIR` path, so migrating
  (which moves the dir to a new path) otherwise forces a one-time re-login per
  profile. `--keep-login` carries the saved token from the old path's keychain
  entry to the new one as part of the move. Implemented as an optional adapter
  hook (`adapter_migrate_credentials`) so the keychain logic stays in
  `lib/adapters/claude.sh`; off by default, and the token never leaves the
  Keychain.

### Changed

- Documented that migrating a claude setup on macOS asks you to log in again
  unless you pass `--keep-login` — with the why (keychain token keyed by the
  config-dir path) and both recovery paths — in `docs/usage.md` and
  `docs/troubleshooting.md`.
- New `docs/claude-on-macos.md` recording two macOS-specific Claude Code
  behaviours found while dogfooding: the Keychain-stored login token (keyed by
  the config-dir path) and the "Welcome back" box vs compact logo (driven by
  `.claude.json` counters + `CLAUDE_CODE_FORCE_FULL_LOGO`, never the path).
  Confirmed against the Claude Code 2.1.156 binary. Linked from the README and
  troubleshooting.

- Docs split: README trimmed to "what + why" plus a 30-second demo and links;
  install, full usage/command reference, the `migrate` guide, and how-it-works
  moved into `docs/installation.md` and `docs/usage.md`; new
  `docs/troubleshooting.md`.

## [0.2.0] — 2026-05-28

### Added

- Built-in adapters for **GitHub CLI** (`gh`), **Google Cloud** (`gcloud`),
  **Docker** (`docker`), **Helm** (`helm`), **kubectl** (`kubectl`, the first
  `env-file` adapter), and **AWS** (`aws`, the first `env-var` adapter).
- `clikae migrate [<cli>]` — adopt a hand-rolled "config dir + shell alias"
  setup (e.g. the `~/.claude-acct-{a,b}` dual-account pattern) into clikae: it
  moves each referenced config directory under `~/.clikae/profiles/<cli>/<p>/`
  and rewrites the alias into clikae's managed sentinel block. Previews the plan
  and confirms first, backs up the rc once, and never overwrites an existing
  profile. Supports `--dry-run` and `--force`.
- `bats-core` test suite under `tests/bats/` (init, alias, list, remove, app,
  migrate, adapters, and bash-3.2 compatibility guards). Each test runs in an
  isolated throwaway `$HOME` + `$CLIKAE_HOME`.

### Fixed

- `clikae app` produced an uncompilable AppleScript on macOS: the command was
  substituted into the template with `sed`, but BSD/macOS `sed` strips
  backslashes from the replacement string, so the escaped `\"` collapsed to `"`
  and terminated the AppleScript string early. Substitution now uses bash
  parameter expansion (and escapes backslashes before quotes), so launchers
  compile and run correctly. This path was never exercised in v0.1.

## [0.1.0] — 2026-05-28

### Added

- Initial v0.1 scaffold: pure-bash CLI dispatcher (`bin/clikae`) with a small
  modular `lib/` (core, commands, adapters, templates).
- `clikae init <cli> <profile>` — create a profile under `~/.clikae/profiles/<cli>/<profile>`.
- `clikae alias <cli> <profile>` — write a managed alias block to the user's shell rc.
- `clikae app <cli> <profile>` — generate a macOS double-click launcher `.app`
  with a custom Terminal window title.
- `clikae run <cli> <profile> [-- args]` — run a CLI with a profile, no alias needed.
- `clikae list`, `clikae info`, `clikae adapters`, `clikae help`.
- `clikae remove <cli> <profile>` — atomically clean up the dir, alias block, and `.app`.
- Built-in adapter for **Anthropic Claude Code** (`CLAUDE_CONFIG_DIR`).
- Adapter template and developer guide for adding new CLIs.
- `install.sh` for `curl | bash` installs and a Homebrew formula template.
- MIT License.

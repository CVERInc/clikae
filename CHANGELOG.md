# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] — 2026-06-30

`clikae resume` grows up into an interactive, cross-engine session picker, and the
home board gets dramatically faster. With no id, `clikae resume` now opens a TUI
that lists recent sessions across **every** tank — claude, codex, and antigravity —
newest first, with live filtering and paging, so you pick a session by title
instead of copy-pasting a UUID; press `[R]` from the home dashboard to open it. A
new `clikae resume cleanup` reclaims disk from old session data (interactive, asks
first, with `--dry-run`/`--older-than`). Under the hood the home board went from
several seconds to well under one on large tanks, by reading only the slices of
(sometimes 100+ MB) transcripts it actually needs and scanning each tank's fuel
state once instead of repeatedly.

### Added

- **Interactive `clikae resume` picker** — run with no id to browse recent sessions
  across all tanks (filter with `/`, move with arrows/`j`/`k`, page with PgUp/PgDn,
  `g`/`G` for top/bottom). Cross-engine: claude, codex, and antigravity sessions all
  appear. `[R]` from the home board opens the same picker.
- **codex + antigravity resume** — both can now be resumed by id and surfaced in the
  picker (antigravity copies its `brain/` + conversation db across tanks on resume).
- **`clikae resume cleanup`** — delete old session transcripts/databases to free disk
  space. Interactive and asks before deleting; never removes tank configs or memory.
  `--dry-run` previews; `--older-than <days>` scopes it.

### Changed

- **Home board is much faster** (~8s → well under 1s on a multi-GB tank). Transcript
  reads are bounded to the head/tail slice actually needed (a shared
  `transcript_head`/`transcript_tail`), fuel/over-quota detection folds its per-file
  pipeline into a single pass, and the board scans each tank's fuel state once rather
  than re-scanning same-account siblings.
- A shared `sessions_by_mtime` kernel now backs every "recent sessions" listing (the
  picker, `cleanup`, and each adapter), replacing copy-pasted stat/ls loops.

### Fixed

- The resume picker no longer crashes or mis-pages on the arrow / Page Up / Page Down
  keys, and `[R]` from the board no longer aborts with `cmd_resume: command not found`.

## [0.7.1] — 2026-06-26

Resume a past session by id, no matter which tank holds it. Because clikae gives
each tank its own config dir, a session transcript lives under that tank — not the
engine's default home — so a bare `claude --resume <id>` in a fresh shell fails
with "No conversation found": the engine looked in its default home and the session
is in a tank. Resuming a known session is therefore clikae's job, and until now it
had no verb for it (`to`/`relay`/`continue` only carry your *current* shell's live
session *forward*). This release adds `clikae resume`, which reaches *backward* to a
named session: it scans every tank, finds the owner, cd's to the directory the
session was recorded in, and resumes it under that tank's config — so you never need
to know which tank, and with no id it lists recent sessions across all tanks by
title so you pick one instead of copy-pasting a UUID.

### Added

- **`clikae resume [session-id]`** — reopen a specific past session by id in
  whichever tank owns it. `clikae resume <id>` locates the tank, cd's to the
  session's recorded working directory, and resumes it under that tank's config dir.
  Run with no id, it lists recent sessions across all tanks (newest first, by title)
  and resumes the one you pick — no UUID to copy. Extra engine args pass through
  after `--`. Only engines that can resume by id take part (claude today).
- **Adapter hooks** `adapter_find_session`, `adapter_session_cwd`, and
  `adapter_recent_sessions` (claude) — locate a session by id across all of a config
  dir's projects, recover the directory it ran in, and list recent sessions for the
  picker. Engines that don't define them simply aren't reachable by `resume`.

## [0.7.0] — 2026-06-24

agy (Antigravity) becomes a first-class breadth engine. Until now `conduct` could
only fan to claude and codex; this release lets it fan a read-only best-of-N leg to
Antigravity too, so cheap/fast breadth work rides your agy quota instead of your main
budget. Because agy is adapter-less (one global Keychain login that can't be switched
per-shell or run in parallel), the leg is special-cased to run on the currently active
agy tank, with an honest `NOTACTIVE` report rather than silently using the wrong
account. Alongside it, the hard-won knowledge of how to drive agy headless — which a
session previously re-learned (and re-burned) every time — is now baked into
`clikae agy --help`, a canonical `docs/agy-dispatch.md`, and the orchestration
playbook. The misleading bare `not burnable` footer is reworded too.

### Added

- **`conduct` accepts an agy leg** — `clikae conduct --leg agy/<tank>` now fans a
  read-only best-of-N prompt to Antigravity alongside claude/codex legs, so cheap
  breadth work can ride your agy quota instead of your main budget. agy is
  adapter-less (one global Keychain login), so the leg is special-cased: it runs on
  the **currently active** agy tank only — a leg naming another tank is reported
  `NOTACTIVE` (with the active tank's name), never silently run on the wrong account,
  because clikae can't switch agy per-shell or run two agy tanks in parallel. Its dry
  state is read from `cli.log` (`limit_log_dry`), since `agy -p` exits 0 with empty
  stdout when it hits its Gemini quota. Tests in `tests/bats/conduct.bats` (+5).
- **`docs/agy-dispatch.md`** — a canonical how-to for driving agy headless via clikae
  (the `-p`-not-`-i` rule, prompt-via-file, write-to-a-file-not-stdout, fenced task +
  long `--print-timeout`, `--add-dir`, `pkill` before switching, skip-permissions is
  for a human not an agent). `clikae agy --help` now carries the one-line recipe and
  points here; `docs/orchestration.md` gained an agy section.

### Changed

- **agy "not burnable" footer reworded** — `clikae tanks` no longer prints the
  misleading bare phrase `not burnable`. It now reads (localised via
  `T_AGY_BURN_NOTE`, en/ja/zh-TW) that agy's global login means `burn` can't
  auto-reroute it across tanks, but it runs fine headless on the active account via
  `agy -p` (or switch interactively with `clikae agy <tank>`).

## [0.6.2] — 2026-06-20

A small housekeeping patch with no behaviour changes. One Chinese string was
leaking into the English `relay` / `to` preview card regardless of the user's
locale setting; it now reads `swap the tank · keep burning` in line with the
command's own header metaphor. Separately, every remaining foreign-language
string in code comments has been translated to English — the project policy is
that comments are English-only and only the i18n dictionary (`lib/core/i18n.sh`)
carries other languages.

### Fixed

- **`relay` preview card locale leak** — the subtitle label on the relay preview
  card was hardcoded in Chinese (`換油箱・接力`) and appeared in that language
  regardless of locale. It now reads `swap the tank · keep burning`, consistent
  with the file's own `"Swap the fuel tank and keep burning."` header.

### Changed

- **Code comments translated to English** — thirteen comments across `bin/clikae`,
  `lib/commands/home.sh`, `lib/commands/switch.sh`, `lib/commands/burn.sh`,
  `lib/adapters/claude.sh`, `lib/adapters/codex.sh`, and `lib/core/update_check.sh`
  contained Chinese or Japanese phrases. All are now English. The i18n dictionary
  and the two intentional native-language strings in `lang.sh` / `help.sh` are
  untouched.

## [0.6.1] — 2026-06-20

Six weeks of vertical-orchestration dogfooding shook out a collection of quiet
correctness bugs — in `conduct`, `burn`, `proc`, `app`, `codex`, and `state-version`
— and added two new test layers (PowerShell adapter-drift guard and a `conduct
--help` honesty test). No new command surface, no breaking changes. If v0.6.0 grew
the muscle, v0.6.1 makes sure it doesn't misfire.

### Fixed

- **`conduct --leg` name validation** — a leg slug with path characters could escape
  its output directory. `--leg` names are now validated before dispatch so a
  crafted name can't write outside the designated out-dir.
- **`proc` interactive-vs-background guard** — the env block was confusing the
  detection heuristic that classifies a process as interactive or a background
  daemon, producing wrong soft-vs-hard warn decisions. The guard is now reliable.
- **`_app_shell_squote`** — the shell-quoting helper produced broken shell for any
  value containing a single quote, making `.app` launchers malfunction for paths or
  prompts with apostrophes. Fixed.
- **`codex` cwd trailing-slash matching** — a session's recorded `cwd` is now
  matched trailing-slash-insensitively, so sessions stored with and without a
  trailing slash both appear in the board's Continue list.
- **`state-version` migration-failure message** — the failure message was garbled
  (double-substitution artefact). The message is now readable, and a new bats test
  pins the v1→v2 migration path.
- **`$CLIKAE_LIMIT_PATTERN` in headless output-dry path** — the environment
  override for the limit-detection pattern was not honoured when scanning headless
  output; clikae now respects it in that path, consistent with the interactive
  transcript path.

### Added

- **PowerShell adapter-drift test** — a new compat bats test asserts that the
  PowerShell adapter table stays in sync with the bash adapter set, catching
  future bash-only additions before they silently regress the Windows community port.
- **`conduct --help` honesty test** — bats now asserts that `clikae conduct --help`
  discloses its read-only, non-judging limits, keeping the help text honest as the
  command evolves.

### Docs

- **Orchestration playbook** (`docs/orchestration.md`) — the field guide for
  driving clikae headless / as an agent fleet, including the three dispatch shapes
  (`burn` / `conduct` / conductor legs), hard-won anti-patterns, and a recipe section.
  Added in this cycle and expanded with cost-aware model-tiering guidance and
  independent-verification principles in v0.6.1.
- **Demo board** (`clikae demo`) — richer, ToS-safe multi-engine demo board with
  fuel gauge; sandbox path removed from the tour; `help` notes the agy one-shot
  dispatch pattern.
- **Proposals archived** — issues #22 and #24 marked SHIPPED in v0.6.0 in
  `docs/proposals/`.
- **`homebrew/RELEASING.md`** — exact publish commands for the next release so the
  step-by-step is in-repo rather than implicit.

## [0.6.0] — 2026-06-14

The vertical-orchestration step: clikae grows the muscle for directing a fleet of
AI CLIs that each burn their own subscription — and a sibling Claude Code skill
(`conductor`) stands on it. All additive; the existing command surface is unchanged.

### Added

- **`clikae conduct` (BETA)** — fan ONE prompt across N accounts **in parallel**,
  each running headless **read-only** on its own tank (its own quota), then collect
  every leg's full output and print a captured/dry table. clikae does **not** judge —
  it hands you N result files and an honest table; you (or a session model acting as
  conductor) pick the winner. Read-only by design so legs can't clobber a shared
  tree. New optional adapter hook `adapter_audit_flags` (claude, codex).
- **`clikae git-id <engine> <tank> --name … --email …`** (issue #22) — give a tank
  an optional git commit identity. When set, `clikae env` also exports
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, so commits made in that shell are stamped with
  the identity you intended — not the engine's account email (the HANDOFF §13
  mis-attribution incident). git env vars beat `git config`; honest limits (loses to
  an explicit `git -c user.email=…`, per-shell only, future commits only) are
  documented in the command's help and `docs/grammar.md`.
- **`clikae burn --prompt-file <f>` / `--prompt <str>` / `--add-dir <dir>`** (issue
  #24) — the easy way to burn a write-task: clikae fills each engine's headless-write
  flags from a new optional adapter hook `adapter_burn_flags` (claude, codex), so you
  no longer hand-assemble `-p … --dangerously-skip-permissions` / `exec -s
  workspace-write …`. A cross-engine `--to` reroute now regenerates the flags for the
  new engine (previously it shipped the wrong engine's flags). The explicit `-- <cmd…>`
  form keeps working unchanged.

### Fixed

- The new `adapter_burn_flags` / `adapter_audit_flags` recipes are **NUL-separated**,
  not newline-separated, so a multi-line prompt survives as a single argv item (a
  newline framing shattered a prompt that itself contained newlines).
- `clikae conduct` classifies a leg by its captured output, not the result file's
  size, so an empty (failed) leg is reported as a real failure rather than a false
  "captured" (an empty `printf` still writes a trailing newline).

## [0.5.14] — 2026-06-07

### Changed

- Final polish so the released tarball matches `main` — no behaviour change. Dropped a
  phantom `$CLIKAE_HOME/adapters` TODO comment (never implemented; adapter overrides
  live in the repo's `lib/adapters/`), and marked `docs/HANDOFF-world-class-gaps.md`
  historical now that its punch-list is cleared.

## [0.5.13] — 2026-06-07

### Added

- **`burn --fresh`** — delete the artifact before running, for a clean slate.
- **`burn --timeout` perl fallback** — when neither `timeout` nor `gtimeout` (coreutils)
  is on PATH, the run is bounded with a `perl` alarm (stock macOS ships neither). Only
  when all three are missing does the run go unbounded (still warned).
- **`burn` summary line** — on finish, one line: tank used, reroute count, elapsed time,
  artifact size.

### Fixed

- **`burn` no longer counts a STALE artifact as success.** A leftover artifact from a
  previous run could make a failed task look like it succeeded. Success is now judged by
  the artifact appearing *or its timestamp changing*, via the existing GNU-stat-first
  `_clikae_mtime` helper (portable across macOS/Linux; whole-second resolution — `--fresh`
  sidesteps a same-second overwrite).
- **Accurate agy docs & strings.** Comments and i18n that said agy "hardcodes ~/.gemini
  and ignores env" were imprecise: agy's *state* follows `$HOME`, but its *login* is one
  global Keychain entry — so different accounts can't be routed per-shell, which is why
  switching is global. Also removed a dead, incorrect "agy can't be renamed" string (it
  can — rename carries the per-tank Keychain login).
- **`remove agy <active-tank>`** now names a concrete other tank to switch to.

## [0.5.12] — 2026-06-05

### Added

- **State schema versioning.** Everything under `$CLIKAE_HOME/` now carries a
  `version` marker, so a future change to an on-disk format is safe: clikae reads it
  on startup and runs a forward migration if an older clikae last wrote your state
  (and warns, rather than downgrading, if a *newer* one did). Deliberately minimal —
  one version file + one migration runner, no framework. It's stamped when state is
  created, so read commands stay read-only; a pre-existing install with no marker is
  treated as the original layout and migrates cleanly when needed. (Invisible in
  normal use — this is groundwork for safe format changes later.)

## [0.5.11] — 2026-06-05

### Fixed

- **`clikae watch` now starts reliably.** Its live-tail path validated the
  handoff target through a helper that wasn't defined; `clikae watch <engine>` on a
  real session could exit before tailing. The target is now validated up front
  (fast-fail on a bad `--to`), and the path is covered by tests.
- **`clikae to codex <tank>` describes what it actually does.** codex can't resume a
  carried session, so the carry starts fresh — the message now says "FRESH (not a
  resume)" instead of announcing a resume.
- **Auto-reroute won't dead-end on agy.** `next_tank` no longer offers an
  `antigravity/<tank>` entry as a carry target (agy is global / single-account, so it
  can't take a `/tank` handoff). Reach agy explicitly when you want it.
- **`clikae tanks` shows an agy tank's real account.** The ACCOUNT column now reads
  agy's signed-in email (the same source the board uses, so the two agree) instead of
  a `(active)` state marker.

### Changed / docs

- New **[docs/EXPECTATIONS.md](docs/EXPECTATIONS.md)** — an "is this a bug?" guide to
  deliberate-but-surprising behaviours (the fuel dot, codex's UTC reset time, agy's
  global switch, account-level limits, …).
- Doc corrections: the board's language key is **`l`** (not `h`); `lang` opens a
  picker (not a blind cycle); `handoff` auto-detects a local summariser
  (`CLIKAE_HANDOFF_AUTOLOCAL=0` to disable); `auto` is claude-launched-only; `watch`'s
  next-tank is the same-engine-first ring; rc-backup timestamp format; `$LC_ALL`/`$LANG`
  resolution order; `env` listed in the grammar.

## [0.5.10] — 2026-06-05

### Fixed

- **`burn` no longer reroutes a headless job onto the tank you're actively using.**
  The original "燒爆" footgun: `clikae burn claude <X>` where the reserve walks onto
  `claude/C` — the tank an interactive session is live on — silently spends *that*
  conversation's quota. (A 2026-06-05 log had declared this fixed after testing
  **codex only**; the claude path was never covered and was confirmed still-live.)
  Now `burn`'s auto-reroute **skips a tank an interactive session holds** (detected
  via `live_dir_users`); pass `--allow-active` to override.
- **`burn` reserve is account-aware.** It skips a candidate tank that shares an
  account with one it already dried — same login = same quota = already dry, so the
  hop was wasted (e.g. `L`→`MFC` on one login).

### Changed

- The `agy` burn-refusal message reads truer ("agy is *already* global/single-account
  — there's no per-tank headless burn to do; just use it directly"), and `clikae
  tanks` now footnotes that agy is interactive-switch-only / not burnable.

## [0.5.9] — 2026-06-05

### Added

- **"✨ Update available" notice on the board.** When a newer clikae is out,
  `clikae` shows a codex-style prompt before the tank board — a ✨ banner + a 3-way
  choice: **update now** (runs the right command for your install — `brew upgrade
  clikae` or the curl installer, auto-detected; just *shown* if it can't tell, never
  a guess-run), **skip**, or **skip until next version**. Quiet and opt-out: the
  check is throttled to once a day, cached, offline-safe, and fully disabled by
  `CLIKAE_NO_UPDATE_CHECK=1`. Localised (en-US / ja-JP / zh-TW).
- **Carry a session onto another tank even when it still has fuel.** The Continue
  submenu gains a third choice — *carry this session to another tank* — so you can
  deliberately move a live conversation to another account, not only when the tank
  runs dry. (Shown for engines that can resume a carried session, when there's
  another tank to carry to.)
- **A capture-time tag on snapshot reset times.** codex (and agy) report a reset
  time clikae can only catch headless — codex in **UTC**, for whichever limit window
  it hit; agy as a relative "Resets in 3h" frozen at its last run. The board now
  appends "· seen HH:MM" (the local time we observed it), so a stale or off-timezone
  reset reads honestly as a snapshot rather than a live countdown. claude is exempt
  — its dry is re-read live each render and is already absolute + timezoned.

### Changed

- **`clikae burn --timeout` discloses its dependency.** It needs `timeout` /
  `gtimeout` (GNU coreutils); stock macOS has neither, so without it the run is
  **not** bounded — the flag help now says exactly that, and the warning is clearer.
  No silent promise of a bound the platform can't keep.

### Fixed

- Pinned a regression test for `clikae to`'s refusal when a shell is attached to
  more than one engine (it must ask, never guess which session to carry).

## [0.5.8] — 2026-06-05

### Added

- **Carry on from a dry tank, right from the board.** Pressing Enter on a
  Continue row whose tank is out of fuel no longer dead-ends on "resume" / "open
  fresh" — both of which only put you back on the exhausted quota. When the tank
  is dry, the submenu now leads with **carry this session onto the next fuelled
  tank**: a real `relay` (same engine resumes the conversation) or a written
  brief (cross engine), with "resume anyway" kept as an escape hatch.
- **codex tanks can light a red dot now.** codex's usage limit is exec-stdout-
  only — it never lands in a transcript, so the passive board had nothing to
  read and codex always showed `○` (no reading). `clikae burn` already detected
  it (and the vendor's verbatim reset phrase); it now **persists** that to a
  small dry-until store, so a later `clikae` shows codex red with its reset time.
  Self-clearing: a successful run clears it, and a stale marker ages out (6h)
  rather than pinning a tank red forever.

### Changed

- **The carry-onward selector is now a ring — account- and fuel-aware.** When a
  tank runs dry, `clikae to`, the BETA supervised auto-carry, and the board all
  pick the next tank by: **circling** the whole burn order (wrapping past the end
  — a tank *earlier* in your order is still a reserve, where before the list fell
  down once and stranded everything above you); preferring a fuelled **same-engine**
  tank (a real resume) over a cross-engine cold brief; and skipping any tank whose
  **account** is already exhausted. A usage limit hits the whole account, so a
  sibling tank sharing a dry login (same email) now reads dry too — no more
  pointless hop onto the same empty quota. When the *whole* ring is dry it says
  so, instead of hopping onto a tank that has no fuel either.
- The dry-tank board submenu's "open fresh" wording is clearer: it opens the
  **same** tank fresh — it never switched tanks (the old "換到這個油箱" read like a
  tank-picker). New dry-tank carry strings localised (en-US / ja-JP / zh-TW).

## [0.5.7] — 2026-06-04

### Added

- **`clikae app --board`** — a `.app` launcher for the **board** (your menu of
  recent sessions + tanks), not a single tank: one double-click button for the
  whole on-ramp. Works for Terminal, iTerm2, and Ghostty.
- **A helpful "engine isn't installed" message.** Switching to a tank whose CLI
  binary isn't on your PATH now reports it clearly — with a per-engine install
  hint (e.g. `npm install -g @anthropic-ai/claude-code`) — instead of a bare
  `exec: …: not found`. clikae switches accounts; it doesn't install the CLI.
  (New optional adapter hook `adapter_install_hint`.)

### Changed

- **The board shows only burnable fuel tanks** (claude / codex / agy). Tool-CLI
  tanks (gh, npm, aws, …) aren't AI sessions — "launching" one only printed a
  usage screen — so they now live in `clikae tanks` (the full inventory), not on
  the board. The adapters are unchanged; only their presence on the board is.
- **Ghostty `.app` launchers pass their command through a trusted config file**
  (`--config-file=`) instead of `-e`. Ghostty pops an "Allow Ghostty to execute…?"
  dialog for an externally-injected `-e` command (so a `-e` launcher looked like an
  empty shell until you clicked Allow); a config file is trusted, so the window
  just opens. The config is located at runtime via `path to me` (so the .app keeps
  working if moved), and the bundle is re-signed after the config is written so
  Apple Silicon doesn't block it.

### Fixed

- **The board no longer renders blank when there are 0 fuel tanks** (e.g. only
  tool-CLI tanks): a `grep -c .` returning exit 1 on a zero count aborted the whole
  render under `set -eo pipefail`.

## [0.5.6] — 2026-06-04

### Fixed

- **`rename` / `migrate` / `remove` no longer abort when the in-use process scan
  can't run.** v0.5.5's new cross-shell guard (`lib/core/proc.sh`) leaked
  `ps eww`'s exit code, so under `set -eo pipefail` a non-zero `ps` — on a
  locked-down host, a CI runner, or a restricted sandbox — took the whole command
  down instead of degrading to "couldn't scan, proceed". The scan is now truly
  best-effort, as HANDOFF §11 intended (no reading ⇒ no users found, never a hard
  error). Regression test added (a deliberately failing `ps` must not abort rename).

## [0.5.5] — 2026-06-04

### Added

- **agy is now real multi-account.** agy keeps its Google login in ONE machine-wide
  macOS Keychain item, so swapping the `~/.gemini` symlink alone left every agy tank
  riding the SAME account. `clikae agy <tank>` now carries the login WITH the tank:
  it stashes the outgoing tank's login into a clikae-namespaced Keychain slot and
  restores the incoming tank's (Keychain↔Keychain — the token never lands on disk);
  a fresh tank logs in clean instead of inheriting the previous account. `rename`
  carries the slot, `remove` forgets it. macOS-only; gated behind the existing agy
  multi-account consent, whose warning now discloses the Keychain carry.
- **`clikae burn <engine> <tank> --artifact <path> -- <cmd…>`** — a headless guarded
  task runner. Runs a task on a tank, verifies it by the **artifact** it must produce
  (never the exit code — `codex exec` exits 0 even when it hit its limit and wrote
  nothing), and re-fires the same task on the next reserve tank if this one runs dry.
  The headless sibling of `to`/`watch`; batch/parallelism stays the orchestrator's job.
- **codex sessions now appear in the board's "Continue" list** (cross-engine
  continuity). The codex adapter gained `adapter_transcript_path` / `recent_sids` /
  `session_title` / `resume_args`, matching on the rollout's recorded `cwd` (codex
  doesn't slug `$PWD` like claude). Resume via `codex resume <uuid>`.
- **codex usage-limit detection from plain `exec` output** — `limit_line_is_real`
  now matches codex's plain-text limit line (not just `--json`), with reset-time
  parsing (`limit_codex_reset`) and a captured-output check (`limit_output_dry`) that
  `burn` uses to tell a dry tank from a task failure.
- **`clikae tanks` marks the active agy tank** with `(active)` — the one fact that's
  knowable for sure (agy doesn't persist its account email to disk, so we never fake one).

### Fixed

- **`clikae status` no longer crashes** when an adapter-less tank (agy) exists. The
  no-args view aborted silently (empty output, exit 1) because `load_adapter` `exit`s
  rather than returns on a missing adapter, and the `||` guard was dead code under
  `set -eo pipefail`. It now gates on the adapter file and renders agy as a new
  `global` state showing its machine-wide `~/.gemini` symlink target.
- **rename / migrate / remove now refuse to move a tank a live session in ANOTHER
  terminal is still using** (the phantom-tank bug): the old guard saw only the shell
  running clikae. New `lib/core/proc.sh` scans all same-uid processes — an interactive
  session hard-fails (not `--force`-able); only background daemon/spare workers warn.
- **`clikae env agy`** (and app/alias/run/relay/migrate when handed agy) now give a
  helpful "agy is global — use `clikae agy <tank>`" message instead of the misleading
  "No built-in adapter for 'agy'".

### Changed

- **`clikae watch codex` is now honest**: codex records its usage limit only in the
  exec output stream, never the rollout transcript, so a transcript tail can't catch
  it. `watch codex` says so and points at dispatch-time detection (`clikae burn`),
  rather than tailing a file that will never carry the marker.

## [0.5.4] — 2026-06-03

### Changed

- **The board's status dot is now a fuel gauge, not a "you are here".** One axis,
  one reading per tank, like a traffic light: 🔴 dry (over limit, verbatim reset
  phrase) · 🟢 ready · ○ no reading (engines clikae can't read from disk, e.g.
  codex — honestly blank, never a guessed green). The old green "active" dot was
  confusing — it meant a global symlink for agy but a per-shell env var for claude,
  and "current account per engine" is switcher-thinking clikae isn't. "Which tank
  am I on" now lives only with the cursor, the burn-order position, and the `← here`
  text label (the `active` flag still drives the launch target). See
  `docs/DESIGN-board-fuel-dots.md`. Dot legend added to the `?` overlay (i18n).

### Added

- **Weekly-usage caution dot — 🟡 (BETA).** When `clikae watch` sees Claude's own
  "used N% of your weekly limit" notice stream past, it captures the phrase
  **verbatim** (never computed — disk has no weekly denominator) and the board
  shows that tank a yellow ●. BETA because it's not yet confirmed the notice
  reaches a stream clikae can tail; until one is observed, yellow simply never
  lights (safe default). `limit_weekly_marker` / `limit_engine_detectable` added.

## [0.5.3] — 2026-06-03

### Added

- **Your tanks are a single burn order, and the board IS that order.** The home
  board is now one flat list (no engine grouping; engine shown as an inline tag),
  in the order clikae falls through when a tank runs dry. Arrange it in place with
  **`[` / `]`** (move up/down). `clikae <name>` switches to a tank by name alone
  (e.g. `clikae cver`) — a tank's name is its identity. Bare **`clikae to`** carries
  your session to the next tank in that order.
- **Supervised launch — auto-carry on a dry tank (BETA · claude · feedback welcome).**
  Start claude *through* clikae and, when the session hits its limit, clikae carries
  you onward to the next tank in your burn order — in the **same terminal** (one
  redraw), conversation continuing. How much it does on its own is yours to choose:
  **`clikae auto ask|safe|full`** (or the board's `A` key) — safe default asks first;
  `safe` auto-resumes same-engine and asks before crossing engines; `full` just keeps
  going. Nothing runs in the background unless you launched it through clikae (no
  daemon — deliberate). Honest limits: one hop per run; interactive **codex** isn't
  auto-detectable yet (claude-only); the truly seamless in-place feel depends on the
  engine — please report how it behaves. `clikae status` shows what it carried.
- **The "what clikae did" log.** Carries (`clikae to`, the board's `r`, and the
  supervised auto-switch) are recorded; `clikae status` shows a **recent carries**
  tail so you can see what moved where, even while away.

### Changed

- **Your tanks ARE the fuel reserve — the `pool` concept is gone.** The separate,
  CLI-only "fuel pool" was undiscoverable (you couldn't set it from the board) and
  redundant with the tanks clikae already knows. Removed entirely (`clikae pool`,
  `lib/core/pool.sh`, the board's fuel-pool line). Falling through to another tank
  now works with zero setup:
  - **`clikae to`** (no target) carries your session to the **next tank of the
    engine you're on** — a real resume, skipping any tank that's itself over quota.
    Name a tank to pick it; name an engine to cross (a cold-start brief).
  - **`clikae watch`** falls through to the same next-tank logic; cross-engine
    still takes an explicit `--to`.
  If you ever want a custom order, that belongs on the board (reorder the tanks) —
  not a hidden file. New core helper `next_tank`.

### Added

- **Interface localisation — en-US / ja-JP / zh-TW.** The dashboard, prompts, and
  key hints now speak your language. A bash-3.2-safe string table
  (`lib/core/i18n.sh`) loads one set of `T_*` globals per render — no per-keypress
  cost. Resolution: `$CLIKAE_LANG` env > saved choice (`clikae lang <code>`) >
  `$LANG`/`$LC_ALL` > en-US. Set it with **`clikae lang en-US|ja-JP|zh-TW`** or flip
  it **live with the `h` key** in the board. The katakana wordmark `ｷﾘｶｴ` stays as
  the brand mark in every language. This also _cleanly separates_ the previously
  mixed-in strings (續上次 / 無痕 / 接回) so each language renders consistently.
- **A more capable interactive board.** New keys: **Tab / Shift-Tab** to move,
  **`g` / `G`** to jump to top / bottom, **`1`-`9`** to jump to a row, **`/`** to
  live-filter tanks, and **`?`** for a full, localised key legend (so every action
  stays discoverable without crowding the footer).
- **`a` now renames the whole TANK**, not just its alias — it runs `clikae rename`,
  carrying the managed alias and saved login across. Alias-only edits stay at
  `clikae alias` on the CLI. (agy tanks are a global `~/.gemini` target and can't
  be renamed.)
- **Continue rows offer a choice.** Pressing Enter on a 續上次 / continue row now
  opens a tiny menu: **resume that exact session**, or **switch to its tank with a
  fresh session** (換油箱開新局).

### Fixed

- **Long recaps wrap with a hanging indent.** A continue row's recap no longer
  spills back to column 0 when it wraps — continuation lines align under the
  recap's first word.
- **CJK labels line up.** The board's left-hand labels (launch / fuel pool / more)
  now pad by display width, so Japanese / Chinese labels align like the English
  ones instead of drifting.
- **CJK recaps wrap correctly.** A Chinese/Japanese recap no longer overflows and
  hard-wraps to column 0 — the wrapper now budgets by DISPLAY width (full-width
  glyphs = 2 cols), not character count. Long/garbled titles are truncated.
- **Polished from dogfeeding:** language is the **`l`** key and opens a select menu
  (not a blind cycle); a **"Tanks"** header sits above the tank list; **agy** shows
  its short name `[agy]` and its signed-in Google account on hover (read from its
  own log), sits under "Also available" instead of floating, and its tanks rename
  too; the new-tank picker groups **AI engines vs tool CLIs**; the shell alias is
  retired from the board (the tank name is the identity); fresh logo.

### Hardened

- **Over-quota detection is future-proofed.** The structural transcript greps that
  spot a genuine Claude session/usage limit now tolerate optional whitespace after
  JSON colons, so a future Claude Code that pretty-prints its `.jsonl` can't
  silently break the `!` badge. Timestamps are compared by bare ISO value. Locked
  in with regression tests for the exact session-limit shape (middot reset phrase
  + `apiErrorStatus:429`) and a spaced-JSON variant. (Detection itself already
  handled the new "session limit" wording — confirmed against a real burn.)

## [0.5.2] — 2026-06-02

### Added

- **The interactive board leads with "continue".** When this directory has
  sessions you can resume, `clikae` now opens with a **續上次 / continue list** at
  the top — your most recent sessions across all tanks (newest first), each titled
  by Claude's own ai-title and marked with a status dot consistent with the tanks:
  ● if that session is on the account you're using right now, ○ if it's on
  another — so you can see at a glance which ones mean switching accounts. Press Enter to reopen the selected one
  (`clikae <engine> <tank> -- --resume <id>` under the hood); the selected row
  also expands to a one-line **recap** — _"where you left off + next step"_ — read
  free from Claude's own session summary (`away_summary`, the `※ recap:` it shows
  at the bottom of a session), so you know what a session was doing before you
  jump back in. Sessions without a recap fall back to showing their age + an
  Enter-to-resume hint, so the hover detail is always there. It only appears for engines that can resume by id (new
  `adapter_resume_args` hook), so the affordance never lies, and it's absent in a
  brand-new directory. Listing stays fast — sessions are ranked by mtime and only
  the few rows shown read their title/recap (`adapter_recent_sids` /
  `adapter_session_title` / `adapter_session_recap`). The board also
  pins the logo top-right on wide terminals, no longer flickers on each keypress
  (the whole frame is composed once and written in a single pass — no per-line
  repaint, no full-screen clear), and adds an `x` key to open the selected tank
  **無痕** — with throwaway memory (`--ephemeral`), a clean amnesiac session that
  leaves nothing behind. Tank rows now collapse to a status dot + name, expanding
  to the account, alias, and reset time only for the selected row (a hover
  detail), so a long list reads at a glance. Board glyphs are ASCII-safe (no
  emoji or rare codepoints a terminal font might drop).
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

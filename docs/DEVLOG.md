# Devlog

A narrative history of clikae, from the first commit to the deliberate park.
For the precise, per-release record see [CHANGELOG.md](../CHANGELOG.md) — this is
the story around it: the itch, the wrong turns, and the lessons that made each
version what it is. Dates are the real tag dates (JST); claims map to the
changelog. Nothing here is roadmap or aspiration — only what actually shipped.

## The itch

Two Claude subscriptions, because one Max plan kept running dry mid-task. A Codex
login. Antigravity. All in different terminals, on different projects, half of
them unfinished. The recurring small pain wasn't dramatic — it was the daily
*"which account was that in, and what was I even doing?"*, followed by a `/clear`
and re-explaining the whole project to a fresh session on a fresh quota.

clikae started as the dumbest possible fix for that: give each account its own
config directory, write a shell alias, done. The interesting part — carrying a
*live* session onto another account so the conversation survives the quota wall —
came later, and turned out to be the actual point.

## The timeline

### v0.1.0 — 2026-05-28 · the scaffold

The first commit (untagged; the public tags begin at v0.2.0). A pure-bash CLI
dispatcher with a small modular `lib/`, and exactly the verbs you'd expect:
`init` a profile, write an `alias`, generate a double-click `.app` launcher,
`run` a CLI under a profile, plus `list` / `remove`. One built-in adapter —
Claude Code, via `CLAUDE_CONFIG_DIR` — and a template for adding more. MIT, and
the pitch was already "every line is auditable."

### v0.2.0 — 2026-05-28 · six more adapters, and `migrate`

Same evening, six more built-in adapters (gh, gcloud, docker, helm, kubectl,
aws), and `clikae migrate` to *adopt* the hand-rolled `~/.claude-acct-{a,b}`
setup people already had instead of asking them to start over. Also a bats suite
and the first real bug caught by it: `clikae app` had been generating an
uncompilable AppleScript the whole of v0.1, because BSD `sed` strips backslashes
from the replacement string. A path that's never exercised is a path that's
quietly broken.

### v0.3.0 — 2026-05-29 · Homebrew, and the Keychain footgun

`brew install CVERInc/clikae/clikae` started working. And the first piece of
hard-won macOS knowledge got encoded: Claude Code keys its OAuth token in the
login Keychain by the *config-dir path*, so moving a profile forces a re-login —
unless `migrate --keep-login` carries the token across. The token never leaves
the Keychain; clikae just teaches it the new address.

### v0.4.0 — 2026-05-30 · breadth (az, npm, terraform, pulumi) and Windows

Four more adapters (eleven total) and a native PowerShell port for people who
don't have bash. A `migrate` in-use guard, too — refusing to pull a config
directory out from under a live session. (The Windows port later got demoted; see
v0.5.0. It was a good-faith experiment that the maintained grammar outgrew.)

### v0.5.0 — 2026-06-01 · clikae becomes a verb

The pivot. The name is 切り替え — *switching* — so the headline action stopped
carrying a verb of its own: `clikae <engine> <tank>` switches and runs. One
`clikae to <target>` carries your current session onward — same engine resumes,
a different engine gets a written brief. The vocabulary settled on **engine** and
**tank** and **fuel/dry**. This release also brought `status`, `relay`, `handoff`
(a portable, vendor-neutral session brief for when the next tank starts blind),
`watch` (ambient "notice a dry tank, switch"), `--ephemeral` throwaway memory,
`--json` for the planned GUI, and a first interactive home board.

It also brought the honesty that became a house rule. `watch`'s limit-detection
shipped with a frank caveat *in the code and the `--help`*: an interactive CLI
hitting its limit fires no hook and returns no exit code, so the only signal is
what the limit writes into the transcript — and the exact marker was *not yet
confirmed against a real limit event*. Better to ship the caveat than to ship a
promise the platform can't keep.

Windows support was reframed here as community/unsupported — it's bash, and
that's the pitch.

### v0.5.1 — 2026-06-01 · a logo that reflows

A responsive welcome screen: on a wide terminal the copy sits beside the logo, on
a narrow one it stacks, measured with `stty size` (because `tput cols` lies
inside a command substitution). Small, but it's the first thing a newcomer sees.

### v0.5.2 — 2026-06-02 · the board leads with "continue"

The release that quietly changed what clikae *is* — from an account switcher into
a continuity dashboard. The board now opens with your most recent sessions across
all tanks, each titled by Claude's own AI-generated name, each with a one-line
**recap** of where you left off — read for free from Claude's own session
summary. And when you carry a session across engines, the brief is written by a
**local** model already on your machine (apfel, ollama, llm) if one's there:
private, free, offline. Your session content — which may include source or
secrets — never leaves the machine to make the handoff.

### v0.5.3 — 2026-06-02 · one burn order, and i18n

Your tanks became a single flat **burn order**, and the board *is* that order —
rearrange in place with `[` / `]`, and `clikae <name>` switches by name alone.
The separate, undiscoverable "fuel pool" concept was deleted outright (you
couldn't set it from the board, and it duplicated the tanks clikae already knew).
A supervised auto-carry landed as BETA — start claude *through* clikae and it
carries you onward when you hit the wall, in the same terminal. No daemon: it only
acts on a session you launched through it. Deliberate. And interface localisation
arrived — en-US / ja-JP / zh-TW — with the katakana wordmark ｷﾘｶｴ kept only in
Japanese.

### v0.5.4 — 2026-06-03 · the dot becomes a fuel gauge

The board's status dot used to mean "you are here" — except it meant a global
symlink for agy and a per-shell env var for claude, which is exactly the
switcher-thinking clikae had stopped being. So it became a fuel gauge, one axis,
like a traffic light: red dry, green ready, ○ no reading (honestly blank for
engines clikae can't read off disk — never a guessed green). "Which tank am I on"
moved to where it belongs: the cursor. The yellow weekly-usage caution dot
shipped here too, as BETA — it captures Claude's "used N% of your weekly limit"
notice *verbatim* (disk has no weekly denominator to compute one), and until that
notice is observed reaching a stream clikae can tail, yellow simply never lights.

### v0.5.5 — 2026-06-04 · agy goes real multi-account, and `burn` arrives

Antigravity keeps its Google login in one machine-wide Keychain item, so swapping
the `~/.gemini` symlink alone left every agy tank riding the *same* account.
`clikae agy <tank>` now carries the login *with* the tank, Keychain to Keychain,
the token never touching disk. And `clikae burn` — the headless guarded task
runner — landed: it verifies a task by the **artifact** it must produce, never the
exit code, because `codex exec` cheerfully exits 0 even when it hit its limit and
wrote nothing. (Trusting an exit code here would be the bug; the artifact is the
truth.)

### v0.5.6 — 2026-06-04 · a one-line fix for a one-line regression

v0.5.5's new cross-shell process guard leaked `ps`'s exit code, so under
`set -eo pipefail` a `ps` that couldn't run — on a locked-down host or a sandbox —
took the whole command down instead of degrading to "couldn't scan, proceed." The
scan is meant to be best-effort. Now it actually is. With a regression test, so a
deliberately failing `ps` must never again abort a rename.

### v0.5.7 — 2026-06-04 · the board is fuel tanks only

Tool-CLI tanks (gh, npm, aws) aren't AI sessions — "launching" one only printed a
usage screen — so they moved off the board into the full `clikae tanks`
inventory. `app --board` shipped: one double-click button for the whole on-ramp.
And a small Ghostty saga got solved: Ghostty pops an "Allow Ghostty to execute…?"
dialog for an injected `-e` command, so a launcher looked like an empty shell
until you clicked Allow. Passing the command through a trusted `--config-file`
(and re-signing the bundle so Apple Silicon doesn't block it) makes the window
just open.

### v0.5.8 — 2026-06-04 · carry onward from a dry tank

Pressing Enter on a dry tank's board row used to dead-end on "resume" or "open
fresh" — both of which only put you back on the exhausted quota, which is the one
thing you didn't want. Now a dry row leads with *carry this session onto the next
fuelled tank*. The next-tank selector became a ring: it circles the whole burn
order (a tank *above* you is still a reserve), prefers a fuelled same-engine tank,
and skips any tank whose account is already dry — because a usage limit hits the
whole account, so hopping to a sibling on the same login would just land on the
same empty quota.

### v0.5.9 — 2026-06-05 · a quiet update notice, and honest snapshot times

A codex-style "✨ Update available" notice on the board: update now / skip / skip
until next version — throttled to once a day, cached, offline-safe, fully
opt-out (`CLIKAE_NO_UPDATE_CHECK=1`), and shown only when it can name the right
command for your install rather than guessing one. (This is also the one network
call clikae makes; the README later owned up to that.) Plus the ability to carry a
session onward even when the tank *isn't* dry, and a "· seen HH:MM" tag on
snapshot reset times — because codex reports its limit in UTC for a different
window than its own TUI shows, and clikae would rather frame a number as a
snapshot than pretend it's a live countdown.

### v0.5.10 — 2026-06-05 · the *real* burn fix

The footgun with a name (燒爆 — "burning yourself up"): `clikae burn claude <X>`
could reroute its dry-fallthrough onto the very tank an *interactive* session was
live on, silently spending that conversation's quota. A 2026-06-05 dogfood had
declared this fixed — after testing **codex only**. It wasn't; the claude path was
never covered and was confirmed still live. Lesson, now written down: don't clear
a multi-engine bug by testing one engine. `burn` now skips a tank an interactive
session holds, and `--allow-active` overrides if you really mean it.

### v0.5.11 — 2026-06-05 · the "is this actually a bug?" audit

A pass that compared what clikae *claimed* against what it *did*, with help from a
few parallel agents. The headline find: `clikae watch` — a headline feature —
shipped broken, calling a helper that was never defined, so it could crash before
tailing anything. No test had covered that line. Fixed, and covered. Out of the
audit came `docs/EXPECTATIONS.md`, an "is this a bug?" guide to the deliberate-
but-surprising behaviours (the fuel dot isn't "you are here", codex resets in UTC,
agy switches globally, limits are account-level, …), and a sweep of doc
corrections — including that the board's language key is `l`, not `h`, which every
doc had managed to get wrong in unison.

### v0.5.12 — 2026-06-05 · state schema versioning

Groundwork, invisible in normal use: everything under `$CLIKAE_HOME/` now carries
a `version` marker, so a future change to an on-disk format is safe — clikae reads
it on startup and migrates forward, and *warns* rather than downgrading if a newer
clikae wrote your state. Deliberately minimal: one version file, one migration
runner, no framework. The stamp is written only when state is created, so read
commands stay strictly read-only. This was the last item on the world-class-gaps
punch-list.

### v0.5.13 — 2026-06-07 · `burn` hardened, agy docs made honest

Two real dogfood runs surfaced a correctness landmine: a *stale* artifact left
over from a previous run could make a failed task look like it succeeded. Success
is now judged by the artifact appearing *or its timestamp changing* (via the
existing GNU-stat-first mtime helper — a self-authored BSD-first version would
have returned garbage on Linux; review caught it). `--fresh` deletes the artifact
before running; `--timeout` gained a `perl` alarm fallback for stock macOS, which
ships neither `timeout` nor `gtimeout`; and a one-line summary closes each run.
The agy docs got more precise too: its *state* follows `$HOME`, but its *login* is
one global Keychain entry — which is the real reason switching is global.

### v0.5.14 — 2026-06-07 · the park

A doc- and comment-only release, cut so the published tarball exactly matches
`main`. It drops a phantom `$CLIKAE_HOME/adapters` TODO that was never implemented
(no-phantom-features, applied to a comment), and marks the world-class-gaps
handoff historical now that its punch-list is cleared. Nothing behaves
differently — this release exists to leave the repo tidy.

## Where it parks

clikae is, deliberately, done for now. The strategy is honest about what it is:
a portfolio piece, an on-ramp, and a tip jar — not a revenue product. A pure-bash
CLI on Homebrew has roughly zero convenience moat to charge for, and the niche
turned out to be crowded by mid-2026 (Quotio, Relay, caam, and a graveyard of
auth-switchers). So clikae stops at "complete for this stage" rather than being
pushed uphill as a business. Its real, narrower edge stays sharp: no proxy, no
daemon, no telemetry — every line auditable — plus the one thing none of the
competitors do, carrying an *expensive orchestrator* onto cheap context.

The bones are good and the punch-list is empty. If a future itch is sharp enough
to earn a v0.6, it'll ship then. Until it earns it, clikae waits — fuelled, ready,
parked.

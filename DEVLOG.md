# Devlog

A narrative history of clikae, from the first commit through a deliberate park, the
v0.6 that earned its way out of it, and the stretch after — where a tank stopped
being a fuel tank and the front page finally said so.
For the precise, per-release record see [CHANGELOG.md](https://github.com/CVERInc/clikae/blob/52a0db28e7d947f1055835a12de54a468a42b20d/CHANGELOG.md) — this is
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

The footgun with a name ("burning yourself up" / burnout): `clikae burn claude <X>`
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

### v0.6.0 — 2026-06-14 · un-parked, into vertical orchestration

The park clause said a sharp-enough itch would earn a v0.6. The itch arrived as
three files from a collaborator: a "conductor" Claude Code skill — `claude-leg.sh`,
`codex-leg.sh`, and a `SKILL.md` — that fires a headless leg at another model, on
another account, and reads the whole result back. It was, almost line for line, the
one edge the park note had reserved as clikae's own: *carrying an expensive
orchestrator onto cheap context.* Better still, those files had independently
rediscovered clikae's hardest-won doctrine — judge a headless run by its **output**,
never its exit code; close stdin so it can't hang; fall back to a `perl` alarm when
there's no coreutils `timeout`. Two parties arriving at the same rule is the rule
earning its keep.

So v0.6.0 makes that edge first-class. The split stays clean — the **brain** (a
conductor: you, or a session model) decides; clikae stays the **muscle** that
routes accounts, detects dry, and fans work out, and never judges the result:

- **`clikae conduct` (BETA)** fans one prompt headless and read-only across N
  accounts in parallel — each on its own subscription — and hands you every full
  result to choose from. It does not grade them; keeping clikae out of the judging
  is what keeps it a switcher, not a middleman.
- **`clikae git-id`** (issue #22) pins a tank's git commit identity, so a dispatched
  write-job can't stamp commits with the engine's account email — the exact §13
  incident that once leaked nine commits to the wrong GitHub account.
- **`clikae burn --prompt-file`** (issue #24) ends the hand-rolled headless flags:
  clikae fills each engine's write-mode dialect from a new `adapter_burn_flags`
  hook, so a cross-engine reroute regenerates the *right* flags instead of shipping
  claude's to codex. The raw `-- <cmd>` form still works for power users.

The lessons came, as they always do, from letting something independent check the
work. An adversarial audit — run, fittingly, on a separate model — caught two bugs
every test had missed because every test prompt was a single line: the
newline-framed adapter recipes **shattered a multi-line prompt** into one argv item
per line (fixed by switching the framing to NUL), and `conduct` called an empty leg
a *success* because `printf '%s\n' ""` still writes a byte (fixed by judging the
captured output, not the file's size). Both are the "judge by output, not exit
code" rule wearing new clothes; both are now locked by tests — including a real
`git commit` end-to-end proving the pinned identity actually beats `git config`.

And a dogfood that wrote itself: fanning real research legs at a tank that was
genuinely dry made the leg *report the limit honestly* instead of faking success —
and surfaced how a person **sees** a dispatched fleet from inside a Claude Code
session: the footer's `· N shells ·`, the `↓` manager, and the trick of leading
each background command with a `[tank·role]` token so the manager labels itself.
That became `docs/orchestration.md` — a playbook written as much for an LLM driving
clikae as for a person, which is the honest reframe v0.6 settled on: clikae is a
tool for an LLM to command other LLMs, and the human mostly sets strategy and holds
the red-line buttons.

### v0.6.1 / v0.6.2 — 2026-06-20 · making sure the muscle doesn't misfire

Six weeks of dogfooding shook out a collection of quiet correctness bugs with no new
command surface behind them: a `conduct --leg` slug with path characters could write
outside its out-dir, `_app_shell_squote` produced broken shell for any value with an
apostrophe, `proc`'s interactive-vs-background heuristic was confused by the env
block, and `state-version`'s migration-failure message was a garbled
double-substitution. Two new *test layers* matter more than any single fix: a compat
test that fails when the bash adapter set drifts from the PowerShell table, and a
test that asserts `conduct --help` still discloses its read-only, non-judging limits
— honesty pinned by CI rather than by whoever edits the help text next. v0.6.2 then
swept thirteen Chinese and Japanese phrases out of code comments and one leaked
Chinese string out of the English relay card: comments are English-only, and the
i18n dictionary is the one place another language lives.

### v0.7.0 — 2026-06-24 · agy stops being re-learned every time

`conduct` could fan to claude and codex; this release let it fan a read-only leg to
Antigravity as well, so cheap breadth work rides agy's quota instead of the main
budget. Because agy is adapter-less — one global Keychain login, unswitchable
per-shell and unrunnable in parallel — the leg is special-cased to the *currently
active* tank and reports `NOTACTIVE` when a leg names another one, rather than
silently burning the wrong account. The more valuable half was documentation. The
recipe for driving agy headless — `-p` not `-i`, prompt via file, write to a file
because stdout buffers, a fenced task with a long `--print-timeout`, dry shows in
`cli.log` not stdout — had been re-derived, and re-burned, by session after session.
It went into `clikae agy --help` and a canonical `docs/agy-dispatch.md`. Knowledge
that has to be rediscovered is knowledge the tool failed to carry.

### v0.7.1 — 2026-06-26 · reaching backward

Every verb so far carried your *current* session forward. But giving each tank its
own config dir means a transcript lives under that tank, so a bare
`claude --resume <id>` in a fresh shell fails with "No conversation found" — the
engine looked in its default home and the session is in a tank. That made resuming a
known session clikae's job by construction, and it had no verb for it. `clikae
resume` scans every tank, finds the owner, cd's to the directory the session was
recorded in, and resumes it under that tank's config. You never need to know which
tank.

### v0.8.0 / v0.8.1 — 2026-06-30 · the picker, and the board gets fast

With no id, `resume` now opens a TUI across every tank — claude, codex and
antigravity — newest first, with live filtering and paging, so you pick a session by
*title* instead of copy-pasting a UUID; `[R]` opens it from the board. `resume
cleanup` arrived alongside to reclaim disk from old session data. The bigger change
was speed: the home board went from ~8 seconds to well under one on a multi-GB tank,
by reading only the head/tail slices of (sometimes 100+ MB) transcripts it actually
needs and scanning each tank's fuel state once instead of re-scanning same-account
siblings. v0.8.1 then fixed the update notice going quiet — one slow network call
used to stamp a 24-hour throttle *and* write back a stale version, so a single blip
could hide a real release indefinitely. A failed check now keeps the last-known
version and retries within the hour.

### v0.9.0 — 2026-06-30 · a tank turns out to hold more than fuel

The release that quietly changed what clikae *is*, again. `clikae memory
share|isolate|status` points a tank's long-term memory at one vendor-neutral
markdown store — a **Soul** — so several of your own tanks, across engines, read and
write a single brain. claude fans its memory dir in with a symlink; codex and agy,
whose memory is opaque, get a fenced pointer note in the rules file each already
reads on start, so cross-engine sharing needs no translator and cannot drift: it is
literally the same file. Sharing is opt-in, per-tank, never auto-crossed, seeded by
copy, and reversible.

Two companions shipped with it. `clikae solo` marks a tank standalone — out of
burn/watch rotation and `to`/relay, and `memory share` refuses it — which is how you
wall off a bot persona that lives on *your own* account, where the cross-account
guard can't see it. And the board became an interactive cockpit: `s` toggles solo,
`m` opens the memory dial, alongside open / relay / resume / incognito / new /
rename / delete / reorder / filter. Its visual language was locked at the same time —
three sections where a *section* is the badge, aligned CJK-safe columns, no emoji, no
"current shell" marker (with many tanks open it is noise).

The honest beat of this release was a removal. The per-tank Keychain stash/restore
that carried agy's Google login was ripped out in favour of logging out and letting
agy prompt a fresh sign-in — because the carry had never been tested against a real
Keychain, and a restore that silently no-op'd would land you on the wrong account
burning the wrong quota. Shipping a switch that *might* lie about which account you
are on is worse than making you click through a sign-in.

### v0.9.1 / v0.9.2 — 2026-06-30/07-01 · isolation that isolated too much

`CLAUDE_CONFIG_DIR` isolation was meant for identity state — auth token, transcript
history, keychain slot. But Claude Code also reads personal skills and slash commands
from that directory, so a freshly created tank silently couldn't see anything under
`~/.claude/skills` or `~/.claude/commands`. The user never asked for their *tools* to
be separated, only their accounts. `init` and every switch now symlink both in,
share-by-default, unless the tank already has a real entry of its own — and tanks
created before the fix self-heal on next use. (v0.9.1 also fixed a help overlay that
aligned by byte count, so rows whose keys hold `↑ ↓ ⏎` sat crooked.)

### v0.10.0 — 2026-07-05 · the carry comes back, verified this time

The agy Keychain carry returns — but every restore is now checked against the stash
*before* agy launches and refuses to proceed if it doesn't match, which is the actual
fix for the trust bug that got the old carry removed. A new integration test drives
the real `security` binary against a disposable scratch keychain, never the login
item. With interactive OAuth out of the switch path, `clikae burn agy <tank>` works:
burn can hop agy to the next tank on dry, sequentially — agy still can't run two
tanks in parallel, which is structural, not a gap. Windows via WSL also became a
documented first-class path, since clikae is plain bash and already ran there; saying
so beat leaving Windows users to guess.

### v0.11.0 / v0.11.1 — 2026-07-05/06 · a brain that can't fragment

The consent unit for a Soul was always the *tank* — that's what the members file and
the cross-account guard key on. But claude's per-project memory layout meant one
`memory share` only linked the directory it ran in, so sessions started anywhere else
quietly accumulated isolated side-memory: a tank that reported "shared" while growing
a second brain. Membership became the single source of truth and the per-directory
symlinks became mere projections of it, re-linked on every launch path. A member tank
can no longer fragment.

v0.11.1 then gave `solo` its second job. `tank_is_solo` had always been meant to run
two logics — fleet tanks work together, a solo tank stays deliberately out — but only
memory and skills read it. `clikae mcp share` promotes an MCP server into one
canonical per-engine store that every non-solo tank merges in, at share time and at
every launch. Additive only: a tank's own entry for the same name is never
overwritten.

### v0.12.0 — 2026-07-11 · the audit, and a reviewer that hadn't read its own code

A deliberate no-new-features release: four independent review lenses — performance,
dead code, correctness/portability, structure — over the whole tree, then the
verified findings applied. It found a bug that had shipped since v0.7.1: on a
single-engine store, one absent directory left an unmatched glob, `stat` exited
non-zero, and `set -eo pipefail` killed `clikae resume` with *no output at all*. It
was caught by pointing an incognito (`--ephemeral`) reviewer at this release's own
diff — a reader with no memory of why the code looked reasonable.

The structural change was one keyboard decoder for every picker. The board, its
sub-menus and the resume picker each carried their own inline ESC state machine —
the layer that had regressed in dogfood more than once — and they had drifted apart.
Consolidating them gave the board PgUp/PgDn/Home/End, a dedicated `/dev/tty` fd
instead of bare stdin, and application-mode arrow decoding, all covered by decoder
unit tests and a real-pty end-to-end driver, `tests/tools/pty-smoke.py`. Alongside
it: ~220 lines of dead code removed, `next_tank`'s O(n²) scan collapsed, and a
measured pass on a real 2300-session store.

### v0.13.0 — 2026-07-11 · the repositioning

The front page finally told the story `docs/VISION.md` had always pointed at. Your AI
work has two halves: the model half is rented — engine, capability, quota, and the
vendors are at war, which is good for you — and the other half is *yours*: who you
are, what you know, where you left off, what should leave no trace. clikae is the
thin local layer that keeps your half portable. Multi-account quota rotation stepped
down from the headline to an advanced chapter.

It came with a bill attached. `docs/terms-and-your-accounts.md` states where the
vendors' terms actually draw the line, with the policy language quoted and dated:
different accounts for different purposes is explicitly fine; carrying the same task
past a usage limit is the gray zone. A one-time note appears before your first
cross-account carry and then never again. A tool that lives in that zone owes its
users the map, not the discovery-by-enforcement-email. Like v0.12.0, the diff was
gated by an incognito red-team pass, which killed two claims that overshot shipped
behaviour.

### v0.13.1 / v0.14.0 — 2026-07-11/12 · disk hygiene, and nine languages

`clikae to` and cross-tank resume *copy* a transcript into the target tank and never
clean the source; on a real store that was 686 MB of redundant copies, 26% of all
session data. Cleanup groups every session's copies across all tanks, keeps the
**largest** (mtime lies — the newest copy is not always the byte-superset), and
offers a copy for deletion only when a byte-level check proves it redundant. In
v0.14.0 the flow came out from under `resume` — disk hygiene was never a resume
concern, and a capability buried in another command's subtree is nearly
undiscoverable — and became `clikae clean`, with three labeled sections and defaults
chosen so the space hogs are *visible* with zero flags but never deleted without an
explicit opt-in.

The same release took clikae to nine languages. Each was transcreated against that
language's own Apple macOS system strings rather than machine-translated from
English, and translated *by grade*: the sentences you must understand in order to
consent — deleting sessions, spending a tank's last fuel — are fully localized, while
what you type or copy stays technical. A completeness test now extracts both the key
list and the locale list from the code itself, so a partial translation cannot merge
silently. The six new tables were reviewed cold by a model from a different family,
which caught a real inversion — a German line promising the disk space you *have*
rather than the space you'd *reclaim* — and also produced a pile of confident
nonsense that did not survive checking. They ship as an honest LLM-grade baseline,
labelled as such.

### v0.14.1 — 2026-07-12 · the day it deleted something that mattered

The worst entry in this log. `clean`'s live-process guard only ever covered the
stale-copy dedupe path; the main scan loop that classifies sessions as "Untouched for
30+ days" or "Big but recent" never consulted it. So a session with a process still
attached — `claude --resume <sid>` open in another terminal — could surface
*unchecked* under "Big but recent", one keypress from deletion. It was checked, and
deleted: 612 MB, six days old, on the maintainer's own machine, the day v0.14.0
shipped. Claude Code appends per-event and holds no open handle, so there was no
inode for `lsof` to rescue, and `clean` used `rm`, which never reaches the Trash.
Unrecoverable.

Two fixes shipped together: one shared guard called from *every* candidate class, so
a live session is never offered in any section, full stop; and `clean` now moves
candidates to `~/.Trash` instead of `rm`ing them, collision-safe, with every string
that used to promise space was "freed" reworded across all nine locales. If the Trash
is unusable a row falls back to a direct delete and **says so on that row**, rather
than lying about where the data went.

There was a second cause underneath, and it is the one worth remembering. The live
session wasn't *recognised* before it got checked, because a session's own `/rename`
was invisible everywhere: the adapter derived titles from Claude's machine-generated
`aiTitle` only and never read `/rename`'s `customTitle`, so eleven deliberately
renamed sessions on that machine showed none of their real names. The name a human
chose is the strongest signal that a thing matters — and the deletion list was
showing the machine's guess instead.

### v0.14.2 — 2026-07-13 · the tests couldn't see the bug

Rows and prose disagreed about how wide the terminal is. The board, `resume` and
`clean` measured and cut titles by *characters* while their budgets were expressed in
*columns*, so a CJK title — two columns per glyph — rendered at roughly twice its
budget and hard-wrapped back to column 0. Latin-only fixtures cannot tell the two
apart, which is exactly why the suite stayed green while real rows ran off the edge.
Width is now measured by display columns throughout, the fixtures carry CJK titles,
and `clean` sacrifices columns by importance — age, then size, then the title, never
below a readable floor, and never the safety label. Audited across nine locales at
60, 80 and 100 columns against a real store.

### v0.14.3 — 2026-07-13 · isolate is not incognito

`memory isolate` → `memory share` turned out to be a memory-*losing* round trip.
`share` fanned back into only the project-directory slots that still existed, and
`isolate` had just removed every one of them — so a directory whose memory was a pure
symlink came back as nothing, and the re-share silently skipped it. Membership lives
in the group's members file, so `memory status` went on reporting `shared` while the
memory was gone from disk: the instrument agreed with the wrong answer.

It was found the hard way. An agent ran `isolate` on a live tank in order to spawn a
cold reader, and the maintainer's running session lost its long-term memory
mid-flight — the per-directory symlink is re-projected at launch, and a session
already running never gets a relaunch. `share` now fans into every project directory,
creating the slot when it isn't there. And the rule went into `AGENTS.md`, where an
agent will actually hit it: a memory-less session is `--ephemeral`, never `memory
isolate`. *Ephemeral changes this once; isolate changes from now on.*

### v0.14.4 — 2026-07-21 · two title paths, silently drifted

`adapter_title_for_file` — behind the resume picker, the board's continue list, and
`clean`'s deletion list — scanned only the first 100 lines of a transcript. But a
`/rename` lands wherever it was typed, so a session renamed deep in a long
conversation kept listing its old name, while the board's own extractor, which reads
the tail, showed the new one. Two paths deriving the same fact from the same file had
drifted — the failure the "one place owns this format" note exists to prevent, and
the same code path behind the near-miss where a renamed live session almost landed on
the deletion list. Found on a 60 MB session renamed at transcript line 13845. The
extractor now scans the bounded tail slice first (`tail -c` seeks from the end, so
the cost is the slice, not the file) and its precedence mirrors the board's.

### v0.14.5 — 2026-07-21 · the trap that didn't catch a closed window

An `--ephemeral` run points the tank's memory dir at a throwaway, stashes the real
memory aside, and restores it from a `trap … EXIT`. The trap caught `EXIT` and `INT`
— but not `HUP` or `TERM`. Close the terminal window and the process takes a
`SIGHUP`, whose default action terminates it *without* running the EXIT trap: a
dangling symlink to a deleted temp, the real memory marooned in a stash, and the slot
reading as empty. Worse, the ephemeral path self-healed only on the *next* ephemeral
launch, so an ordinary session never recovered it and the tank stayed broken until
fixed by hand. Two guards shipped: the trap now takes `HUP`/`TERM` as well, and the
universal memory-prelaunch hook heals a dangling ephemeral link on *any* launch —
which also recovers what no trap can catch, `SIGKILL` and power loss.

## The park held — then its own clause fired

The strategy hasn't changed: clikae is a portfolio piece, an on-ramp, and a tip jar
— not a revenue product. A pure-bash CLI on Homebrew has roughly zero convenience
moat to charge for, and the niche is crowded (Quotio, Relay, caam, and a graveyard
of auth-switchers). v0.6.0 didn't betray that — `conduct` ships **BETA**, off the
README's headline, opt-in, never pushed uphill as a business. What changed is only
that the park's own clause came true: the one edge it had reserved — carrying an
expensive orchestrator onto cheap context — got sharp enough, and handed-over
enough, to earn the version it was promised.

Its narrower edge stays sharp: no proxy, no daemon, no telemetry — every line
auditable. The bones were good and ready; the itch finally arrived — and clikae was,
for about two weeks, complete for that stage.

## What the tank turned out to be

Then v0.9 found the thing that had been sitting in the store the whole time. A tank
was described, from v0.1 onward, as a place to keep an account's *config*. It is
not. It holds the engine's long-term memory, its session history, the record of who
you were being while you used it. Fuel was only ever the most visible thing in there.

Everything after v0.9 is that realisation being paid for. The Soul layer exists
because memory is the part worth carrying across engines, and quota isn't. `solo`
exists because once a tank holds an identity, some identities must never be
commingled. v0.9.2 exists because isolating *identity* had quietly isolated the
user's *tools* as well, which they never asked for. v0.11.0 exists because a brain
that can silently fragment isn't a brain. And v0.13.0 exists because the front page
was still selling the fuel gauge while the product had become something else — the
half of your work the vendors don't own.

The v0.14 line is the other half of the bill: what it costs to hold things that
matter. `clean` deleted a live 612 MB session because its guard covered one code
path and not the others. It was allowed to happen because a session's `/rename` — a
human deliberately naming the thing they care about — was invisible to every list
that offered it for deletion. `memory isolate` cost a running session its memory
mid-flight while `memory status` kept reporting *shared*. A closed terminal window
stranded a tank's real memory behind a `SIGHUP` the exit trap never saw. None of
these were exotic. Every one was a case where the tool held something irreplaceable
and its own instruments agreed with the wrong answer.

Three habits came out of that stretch and are worth more than any feature in it.
Judge a headless run by its artifact, never its exit code — the oldest rule here,
which keeps reappearing in new clothes. Point a reader with no memory of your
reasoning at your own diff; v0.12.0's oldest bug and v0.14.0's German inversion were
both caught that way, and both were invisible to everyone who already knew why the
code looked fine. And distrust a green suite: Latin-only fixtures could not see a CJK
title running off the edge, and no bats test can watch a terminal. A gate that cannot
observe a failure mode is not evidence about it.

The strategy is unchanged. Portfolio piece, on-ramp, tip jar; no proxy, no daemon, no
telemetry; every line auditable. What changed is what it is a tip jar *for* — not a
way to keep burning past a limit, but the small, boring, local layer that makes sure
the half of the work that is actually yours survives whichever engine you were
renting that week.

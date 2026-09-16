# Expectation vs implementation — "is this a bug?"

A field guide to clikae behaviours that **look** like bugs but are deliberate —
usually because a vendor's real nature leaks through clikae's uniform "tank" model.
If something here surprised you, it's working as intended; the *why* is below.
(For things that are actually broken, see the [CHANGELOG](../CHANGELOG.md) /
[issues](https://github.com/CVERInc/clikae/issues).)

## Fuel gauge & limits

**The coloured dot on the board isn't "which tank I'm on."** It's a fuel gauge:
🔴 dry · 🟡 weekly-% (BETA) · 🟢 ready · ○ no reading. "Which am I on" is the cursor
`❯` and the burn-order position. (See
[DESIGN-board-fuel-dots.md](DESIGN-board-fuel-dots.md).)

**There is no "you are here" marker on a row.** The board deliberately doesn't draw
one: with many tanks open at once it is noise, and the shell you happen to have run
`clikae` from is rarely the one you care about. The active tank is still computed —
it drives the launch hint and the relay source — just not drawn.

**A codex tank can read `○` even though codex is fine.** `○` means "no reading",
not "no fuel" — clikae only colours a dot it can actually justify. codex *does*
record a usage limit to disk (its interactive rollout carries a
`codex_error_info: usage_limit_exceeded` field, which is what clikae matches — the
English sentence beside it is vendor copy and will drift), so a limited tank does
turn 🔴 and clears itself on the next successful reply. But a tank nobody has
touched inside the scan window has nothing to read, and clikae says so rather than
guessing green.

> This page said the opposite until 2026-07-27 — "exec-stdout-only, never written
> to a file clikae can scan". That belief was load-bearing: it is why the fuel dot
> and `clikae auto` were claude-only for months. Nobody had opened a codex rollout
> after a real limit.

**A codex reset time can read odd (e.g. `2026-06-05 07:00`) and carries a
`· seen HH:MM` tag.** codex reports its reset in **UTC**, for whichever limit window
the headless run hit (a 5-hour roll, not necessarily the weekly cap its own TUI
shows). clikae shows the vendor's words *verbatim* (it never computes a time), so the
`· seen HH:MM` tag states *when we observed it* — read it as a snapshot, not a live
countdown. claude is exempt (its dry is re-read live and already absolute + timezoned).

**An idle Claude tank reads `⏳ expired`, not a percentage — and it does not
need a new login.** Claude's access token lasts a few hours and only a running
session refreshes it, so a tank nobody has used since yesterday answers the usage
endpoint with a 401 even though its login is fine and its quota is whatever it was.
clikae says exactly that (`clikae usage --json`: `source:"expired"`,
`reason:"expired-token"`) instead of the flat `unknown` it used to print, which
looked identical to a tank with no login at all — and a dispatcher that reads
"unknown" as "no data, go ahead" can burn straight into a 99%-weekly wall. It does
**not** refresh the token itself: that would mean speaking the vendor's OAuth
refresh protocol from clikae, which is not documented. Run a session on the tank,
or `clikae usage --wake <tank>` (one trivial headless prompt through `clikae burn`,
so the cockpit is refused without `--force-cockpit`), and the next read shows
numbers again — the expired reading is only cached for 60 seconds so that read is
fresh. "Expired" requires a refresh token in the credentials; a 401 without one
reads `unknown`/`no-credentials`, because that tank really does need a login.

**Two tanks on the same account both go red at once.** A usage limit is
**account-level**, not tank-level. So if `claude/L` and `claude/MFC` share one login,
hitting the limit on one marks both dry (and the reserve skips the sibling — no point
hopping onto the same exhausted quota).

**The yellow (weekly-%) dot may never appear.** It's BETA — it relays Claude's own
"used N% of your weekly limit" notice *if* Claude serialises it where clikae can read
it, which isn't yet confirmed. Yellow staying dark is the safe default.

## Carrying a session (`to` / `relay` / `watch` / `auto`)

**`clikae to <a-specific-tank>` doesn't check whether that tank has fuel.** Only the
**bare** `clikae to` (no target) uses the fuel/account-aware reserve. When you *name*
a destination, clikae takes it as your explicit call and carries you straight there —
same contract as `burn --to` / `relay <from> <to>`.

**`clikae to` carries "the session you were just in *here*" — keyed to your current
directory.** With no live `$CLAUDE_CONFIG_DIR` (the bare switch / alias / `.app` never
export it), clikae finds the session by the current directory's most-recent transcript.
Run it from a *different* directory and it resolves to that directory's session, not
the one you remember. Pin a shell explicitly with `eval "$(clikae env <engine> <tank>)"`.

**`clikae to codex <other-codex-tank>` starts a FRESH session, not a resume.** clikae
can only truly carry a live session for engines that implement the carry hook
(`adapter_relay`) — today that's claude. codex stores sessions in a way that isn't
copy-resumable across tanks, so `to`/`relay` say so and start clean. (`clikae to`
announces "FRESH (not a resume)" for these.)

**`clikae to codex -y` (or `--fresh`) can hard-error.** Those flags are relay
(same-engine carry) options; if the target turns out to be a *different* engine, it's
a handoff (a cold brief), so the flag doesn't apply and clikae refuses rather than
silently ignore it.

**`clikae watch --auto`'s consent is global and permanent.** Granting it once
authorises auto-switching for *every* future `--auto` watch on *any* tank, until you
delete `$CLIKAE_HOME/auto-relay-consent`. (clikae tells you the file + how to revoke.)

**`clikae auto safe/full` only affects sessions launched *through* `clikae`
(BETA).** A session you opened via an alias / `.app` / a bare `claude` isn't
supervised, so `auto` has no effect on it. Engine coverage is claude and codex —
both persist their limit where clikae can read it after the session exits. agy is
out for a structural reason, not a missing feature: one global login, so there is
no per-tank signal to read. grok is out for a different reason: it reports a limit
only on the **exit path** (a stderr sentence plus exit status 1 — unlike codex,
which exits 0), and nothing lands in the session files clikae scans, so there is no
after-the-fact reading to take.

## Antigravity (agy)

**`clikae agy <tank>` changes ALL your shells, not just this one.** agy hardcodes
`~/.gemini` and ignores env vars, so clikae switches it by repointing a **machine-wide
symlink** (and moving the Google login between Keychain slots). Unlike the per-shell
`clikae claude/codex <tank>`, this is global — `clikae status` and the board both label
it so. Reversible with `clikae agy --release`.

**`clikae burn agy <tank>` runs one tank at a time, never in parallel.** It does
work (since v0.10.0 — the Keychain carry made a tank switch non-interactive, so burn
can hop agy onto the next tank when one runs dry). But agy has ONE global login, so
the hop *moves* that global tank the way `clikae agy <tank>` always has, and two agy
tanks can never run at once. That's structural, not a missing feature. For a
one-shot on the account that's already active, `clikae agy <tank> -- -p "…"` is the
shorter path. (See [agy-dispatch.md](agy-dispatch.md).)

**`clikae agy <tank>` with no terminal switches and stops.** The interactive UI
needs a real TTY, so in a script or a piped context clikae completes the switch,
says so, and returns 0 rather than exec'ing a TUI that can only fail with
`could not open TTY`. That makes `clikae agy <tank>` usable as "just switch".
Pass a headless prompt (`-- -p "…"`) and it always runs.

**`clikae burn agy --artifact <path>` produces a file agy never touched.** agy's
headless mode can't write to your paths, so clikae captures its stdout into the
artifact and labels the row accordingly. See
[agy-dispatch.md](agy-dispatch.md) — including the limit: a large answer may
arrive as the pointer agy printed rather than the content it buffered.

**agy appears in `clikae adapters` with a `subcommand` strategy and no env var.**
That row is a resume-only capability shim, not a switchable engine: agy is
architecturally a *target*, and `clikae_is_target` — not "an adapter file exists" —
is what every classification path reads. Which is also why the PowerShell adapter
table mirrors 14 of the 15 adapter files: `subcommand` ones aren't switchable
engines. `clikae tanks` footnotes agy's global-login nature.

## Grok

**A grok tank always reads `○` on the fuel gauge.** Not a missing feature — there
is nothing on disk to read. grok surfaces a usage limit only as it exits (a
sentence on stderr and exit status **1**; codex, by contrast, exits 0), and writes
no limit marker into `summary.json`, the session logs, or anywhere else under
`GROK_HOME` — checked after a real limited run. Its own `/usage` (alias `/cost`)
answers "how much is left, when does it reset", but as a **live query inside a
running session**, and clikae's fuel gauge reads state a session left behind
rather than calling a vendor API. So grok stays `○` rather than guessing green;
for the reset time, ask grok with `/usage`.

**Each grok tank needs its own `grok login`.** `GROK_HOME` re-homes grok's whole
state directory, and `auth.json` lives inside it — so a fresh tank is genuinely
signed out (it says "Not signed in" rather than borrowing `~/.grok`'s session).
That is the isolation working, not a lost login.

**`GROK_HOME` moves grok's state, not the `grok` binary.** The official installer
puts the binary at `~/.grok/bin/grok` and that path on your `PATH`. Tanks live
elsewhere; keep `~/.grok/bin` on `PATH` or no tank can launch.

**A read-only `conduct` leg on grok can still write to `/tmp`.** `--sandbox
read-only` is kernel-enforced and refuses to touch your project (grok logs an
`FsViolation` when it tries), but its documented shape keeps `GROK_HOME` and the
temp directories writable so the session can persist itself. "Read-only" means
*your files are safe*, not *nothing anywhere was written*. clikae adds a second,
in-process fence — a `--tools` allowlist — for the platforms where the kernel
profile can't be applied.

**`clikae mcp share` doesn't reach grok tanks.** clikae's fleet MCP list is merged
into a JSON `mcpServers` object; grok keeps its servers in `config.toml` as a TOML
`[mcp_servers]` table. Rather than write a shape it might corrupt, clikae leaves
grok out — use `grok mcp` inside the tank.

**A grok session started by `burn` shows `(no preview)` on the board.** grok fills
`generated_title` when it titles a conversation, which a one-shot headless run
never gets to. The row is real and resumable — it just has no name yet.

**A grok session's title is whatever `/rename` last set.** grok stores the
model-written title and a manual rename in the *same* `generated_title` field
(`session_summary` keeps the original machine title). So a renamed session shows
your name on the board — and there is no way to show the machine title again.

## Engines on one board

**codex and grok "Continue" rows show no recap (just an age), unlike claude.** claude
writes AI-titles + recap lines into its transcript; codex writes neither, and grok
writes a title but no recap — so those rows gracefully degrade to title + "N ago".
Nothing is missing — there's just less to show.

**A moved/renamed working directory can hide a codex or grok session.** Both record
the session's `cwd` and clikae matches on it (claude slugs `$PWD` instead). Move the
dir and the recorded `cwd` no longer equals `$PWD`, so the session goes invisible to
`relay`/`handoff`/board even though it exists. Run from the original directory.
(grok *also* names its session folder after the encoded cwd, but clikae deliberately
reads the recorded value instead — a folder-name scheme is the vendor's to change.)

**agy's board "Resume" rows are TANK-scoped, not directory-scoped, unlike every
other engine.** claude/codex/grok match a session's recorded `cwd` against
`$PWD`; agy doesn't, on purpose (#34) — workspace is a constant on real
installs, so cwd-scoping would hide everything: every indexed agy conversation
records the same `workspace` (your home directory), never the project
directory you actually ran it from, so a `$PWD` filter here could never match
outside `$HOME`. The Resume list for agy is every session in **every agy
tank** — not only the active one; the board's Resume rows have never been
per-tank for any engine — newest first, capped board-wide the same way every
engine's list is (`CLIKAE_HOME_RECENT_MAX`, default 10), not narrowed to "this
project". Sessions a `clikae burn` lane started stay hidden (`clikae resume
--all`, or `CLIKAE_RESUME_ALL=1`, shows them), and they are filtered out
*before* the board cuts the list to `CLIKAE_HOME_RECENT_MAX`, so a tank full of
fresh lane one-shots pushes real sessions down the list rather than off it.
That promise has exactly one bound, and the board states it rather than hiding
it: each tank is asked for `CLIKAE_HOME_RECENT_MAX` plus *its own* recorded
burn sessions, capped at `CLIKAE_HOME_RECENT_SCAN_MAX` — which defaults to the
burn sidecar's own cap (`CLIKAE_BURN_SIDECAR_CAP`, 2000), so only a sidecar
larger than `clikae clean`'s GC allows can reach it. If it is ever reached and
the list still comes up short, the Resume block says so ("N sessions hidden as
burn runs · list truncated") and points you at `clikae resume --all`; it never
draws a short list that reads as a complete one. That note is worked out inside
the board process and never written to disk, so a board that is killed
mid-render leaves nothing behind. The record of which sessions were burns lives
in `state/burn-sessions/<engine>/<tank>`, keyed by engine id for every engine
(agy's is `antigravity/`). A store an older clikae wrote under `agy/` is moved
there by the next command you run (merged line by line if both exist).

**`--ephemeral` only works on claude.** It needs an engine whose long-term-memory
layout clikae knows how to stash to a throwaway; today that's claude. codex and grok
join the Soul through a *pointer* note instead of a real memory dir, so there is
nothing to stash. Other engines report a clean "not supported" rather than pretend.

**A handoff brief never decodes a literal `\uXXXX` JSON escape.** `clikae handoff`
unescapes `\n`, `\t`, `\"`, `\\` (grep/sed/awk only — no jq/python) on every engine,
claude included; a `\uXXXX` sequence (rare — JSON only escapes to it for control
characters, or when a writer forces plain-ASCII output) prints unchanged rather than
decoded. Was true before #33 fixed the bigger gap (codex's and grok's own transcript
shapes matching nothing at all — see the CHANGELOG); it's a documented follow-up on
every engine now, not a regression.

**An INTERACTIVE `--ephemeral` run still writes a transcript into the tank.** It
drops your memory, your skills and the fleet's MCP servers — so the session does
not know you — but Claude Code only honours `--no-session-persistence` together
with `--print`, so leaving no trace at all is available in the headless shape
(`clikae claude <tank> --ephemeral -- -p "…"`) and not interactively. The wording
on screen says which one you got, deliberately: incognito means *it doesn't know
you*, not *it never happened*.

## Headless tasks (`burn`) — the left-behind scan

**A file whose name contains a newline is reported as two paths, one of which
does not exist.** The scan's per-file `stat` batch is newline-delimited because
`sort -rn` needs lines, so such a name splits across two reads: the first half is
listed as a path that isn't there and the second half is dropped. A
NUL-delimited pipeline would fix it and is not proven against BSD `stat`/`sort`,
so this is a known limit rather than an unverified cross-platform rewrite.
Repository *names* containing newlines are unaffected; only the per-file list is.

**`dirty` and `files` count different things on purpose.** `dirty` is git's own
`status` count for that repository, and from a parent repository's point of view
a nested repository's whole working tree is *one* untracked entry — so a nested
repo adds 1 to its parent's `dirty` while its files appear only on its own row.
`files` is attributed to the innermost repository that owns them, because that is
the repository whose `push` would carry them.

**The scan's watchdog closes fds 3 and 4, not every fd it inherits.** Those two
are the ones `burn` itself is known to open (the run's tee, and `--json`'s real
stdout), and closing them is what stops a failed `clikae burn --json | jq` from
sitting open past process exit. Any other inherited descriptor — a caller's own
fd 5, the collision lock's fd 9 — is still inherited. With a real process group
this is moot, because the watchdog's `sleep` dies with its group; on the
single-pid fallback (a platform that will not give the bounded child a process
group of its own) the pre-fix shape remains — and on that fallback a grandchild
a bounded call forked can outlive the bound. `--json`'s
`left_behind_kill_mode` (`pgroup` / `single-pid`) says which shape a given run
got, so this is a fact you can read rather than one you have to infer.

## Ambient GitHub watching (`watch github`) — run directories

**A run directory with no `status.json` is deleted after 7 days.** Every poll
that finds at least one new event writes
`$HOME/.clikae/logs/watch-github-<org>-<epoch>/status.json` — the file
`clikae wait` resolves. A directory without one is a poll that created its
directory and then died before writing any terminal state: nothing will ever
add the missing file, and `clikae wait` can never resolve it. Both sweeps used
to skip exactly those and keep them forever. They are now removed once their
mtime is older than `CLIKAE_BURN_LOG_RETENTION_DAYS` (default 7, the same knob
as burn's own log retention; `0` disables the sweep here too).

**Two things are deliberately exempt from that delete**, because the directory
name alone cannot tell them from a crashed run: one that still holds an
`events.jsonl`, and one whose name after `watch-github-` is an org this host
watches. An org's *durable* log lives at `watch-github-<org>/events.jsonl`,
never has a `status.json`, and has a directory mtime that does not move when
the log is appended to — and for an org literally called `foo-2024`, its name
is also a perfectly legal run-directory name for org `foo`. Deleting one would
lose that org's entire event history; keeping a rare half-written run directory
costs a few kilobytes. So a crashed run directory that got as far as writing
`events.jsonl` is kept, on purpose, rather than risking the other mistake.

**Run-directory rotation is per org, and orgs sharing a name prefix are
disjoint.** Rotating org `foo` (newest 200 kept) only ever considers
directories named `watch-github-foo-<digits>` or
`watch-github-foo-<digits>-<digits>`. It used to select with a bare
`watch-github-foo-*` glob, which also matched every run directory of org
`foo-bar` — so two orgs shared one 200-directory budget and the older mtimes
lost, whoever they belonged to (#111).

## Management verbs

**`clikae migrate` makes claude ask you to log in again.** claude stores its OAuth
token in the macOS Keychain, keyed by a **hash of the config-dir path** — not inside
the dir. Move the dir and the hash changes, so the token no longer matches. Use
`clikae migrate --keep-login` to copy the Keychain item across.

**The "in-use" guard on `rename`/`migrate`/`remove` is best-effort.** It scans live
processes for a tank in use *right now*; it can't catch a check-then-open race, and
the TUI-vs-daemon classification is a command-string heuristic. It errs toward warning,
not silent damage.

**`clikae <name>` refuses when the name exists in two engines.** A tank's name is its
identity, but if `work` exists under both claude and codex, clikae can't guess which —
it lists both and asks you to qualify (`clikae claude work`).

## Touch terminals over ssh

**Copying from a phone is not something clikae has measured.** The touch
bindings ([usage.md](usage.md#touch-scrolling-over-ssh)) were measured against
a-Shell on iPhone for one thing only: what a swipe and a tap send on the wire,
and what tmux does with them. Two halves of "copy text on a phone" are still
**unverified** (#108):

- **a-Shell's own long-press selection.** It selects what the terminal is
  drawing. Nobody here has checked how it behaves while tmux is in copy-mode,
  or across a pane boundary.
- **OSC 52 reaching the iOS clipboard.** clikae sets `set-clipboard on`, so a
  copy-mode yank is emitted as OSC 52 — but whether a-Shell honours it, and
  whether a selection spanning several pages survives, has not been measured on
  a device. The server-side half is all that is claimed.

Tap-to-page (`@clikae_touch_pages`, off by default) was measured the same way
the scroll half was: against a real tmux server, asserting tmux's own
`#{scroll_position}`. **It has not been run on a physical iPhone** — the
gesture reaching tmux as a press/release pair is inherited from #88's
measurement, not re-measured for this feature.

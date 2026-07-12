# Expectation vs implementation — "is this a bug?"

A field guide to clikae behaviours that **look** like bugs but are deliberate —
usually because a vendor's real nature leaks through clikae's uniform "tank" model.
If something here surprised you, it's working as intended; the *why* is below.
(For things that are actually broken, see the [CHANGELOG](https://github.com/CVERInc/clikae/blob/bab09bd6756ddf91cc82c472dbac0d665843de88/CHANGELOG.md) /
[issues](https://github.com/CVERInc/clikae/issues).)

## Fuel gauge & limits

**The coloured dot on the board isn't "which tank I'm on."** It's a fuel gauge:
🔴 dry · 🟡 weekly-% (BETA) · 🟢 ready · ○ no reading. "Which am I on" is the cursor
`❯`, the burn-order position, and the `← here` label. (See
[DESIGN-board-fuel-dots.md](/DESIGN-board-fuel-dots.md).)

**codex shows `○`, never 🟢 green.** codex's usage limit is exec-stdout-only — it's
never written to a file clikae can scan — so clikae can honestly show 🔴 *only* when
it caught the limit headless (`clikae burn`, persisted), and `○` ("no reading")
otherwise. `○` means "can't tell", not "no fuel". claude/agy do get a real green
because their state is on disk.

**A codex reset time can read odd (e.g. `2026-06-05 07:00`) and carries a
`· seen HH:MM` tag.** codex reports its reset in **UTC**, for whichever limit window
the headless run hit (a 5-hour roll, not necessarily the weekly cap its own TUI
shows). clikae shows the vendor's words *verbatim* (it never computes a time), so the
`· seen HH:MM` tag states *when we observed it* — read it as a snapshot, not a live
countdown. claude is exempt (its dry is re-read live and already absolute + timezoned).

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

**`clikae auto safe/full` only affects sessions launched *through* `clikae`, and only
claude (BETA).** A session you opened via an alias / `.app` / another engine isn't
supervised, so `auto` has no effect on it.

## Antigravity (agy)

**`clikae agy <tank>` changes ALL your shells, not just this one.** agy hardcodes
`~/.gemini` and ignores env vars, so clikae switches it by repointing a **machine-wide
symlink** (and moving the Google login between Keychain slots). Unlike the per-shell
`clikae claude/codex <tank>`, this is global — `clikae status` and the board both label
it so. Reversible with `clikae agy --release`.

**agy can't be `burn`ed.** burn spends *a tank's quota* and reroutes among a reserve;
agy is one global account with no reserve. Use it as a direct worker instead
(`cat in | agy --sandbox -p "…"`), or `clikae agy R -- -p "…"` to spend a specific
agy account's quota. (See [usage.md → Headless tasks](/usage.md).)

**agy isn't listed by `clikae adapters`.** It's architecturally a *target*, not an
*adapter* (it can't be profile-switched per the adapter contract), so it appears in
`clikae list` / `status` / the board, but not the adapter catalog. `clikae tanks`
footnotes it.

## Engines on one board

**codex "Continue" rows show no recap (just an age), unlike claude.** claude writes
AI-titles + recap lines into its transcript; codex writes neither, so its rows
gracefully degrade to title + "N ago". Nothing is missing — there's just less to show.

**A moved/renamed working directory can hide a codex session.** codex records the
session's `cwd` and clikae matches on it (claude slugs `$PWD` instead). Move the dir
and codex's recorded `cwd` no longer equals `$PWD`, so the session goes invisible to
`relay`/`handoff`/board even though it exists. Run from the original directory.

**`--ephemeral` only works on claude.** It needs an engine whose long-term-memory
layout clikae knows how to stash to a throwaway; today that's claude. Other engines
report a clean "not supported" rather than pretend.

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

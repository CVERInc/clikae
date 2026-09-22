# Using clikae

**clikae is a verb** (切り替え, *switching*). The headline action carries no verb
of its own — the program name is the verb:

```bash
clikae <engine> <tank>      # switch <engine> to <tank> and run it
```

An `<engine>` is a CLI with an adapter (run `clikae adapters`); a `<tank>` is a
name you choose (`A-Z a-z 0-9 . _ -` allowed) for one account/config. The fuel
metaphor runs throughout: a tank holds an engine's quota (its *fuel*); when a
tank runs *dry* you carry your work onward with `clikae to`.

Run `clikae help <command>` for the full per-command reference. The full design
of the language is in [grammar.md](grammar.md).

## Quick tour

```bash
# Create a tank for Claude Code, and add the matching shell alias
clikae init claude work --alias

# Switch to it and run — the bare verb (no `run` needed)
clikae claude work
clikae claude work -- --help    # args after -- go straight to the engine

# Or pick up the alias and use that
source ~/.zshrc                 # or your rc file
claude-work

# Generate a macOS launcher you can double-click from ~/Applications
clikae app claude work

# See what you've got
clikae tanks                    # alias: clikae list
#   ENGINE       TANK
#   claude       work
clikae tanks -p                 # also print the tank directory paths

# Tear it all down (tank dir + alias + .app, asks to confirm)
clikae remove claude work
```

## Commands

clikae is the verb, so **switching needs no verb**; management commands keep
plain, conventional verbs.

### Switch (the main thing)

| Command | What it does |
|---|---|
| `<engine> <tank> [-- args]` | Switch `<engine>` to `<tank>` and run it. The bare verb. (`run` is a hidden alias.) |
| `<engine> <tank> --ephemeral` | Switch and run with **ephemeral memory** — this session's long-term memory is a throwaway, discarded on exit; the tank's real memory is left untouched. Login + transcripts are normal. claude only (clikae must know the memory layout). See below. |
| `<engine>` | One tank → use it; several → list them; none → offer to create. |
| `to <target> [tank] [-- args]` | Carry **this shell's current session** onto another tank. Same engine → a real resume; a different engine → a written brief (cold start). clikae announces which. Source is auto-detected (env var, else this directory's most recent session). Forwards relay's `-y`/`--fresh`/`--session`. (`relay`/`handoff`/`continue` are hidden aliases.) |
| `resume [session-id] [-- args]` | Reopen a **specific past session** by id, in whichever tank owns it — clikae scans every tank, finds the owner, cd's to the directory the session was recorded in, and resumes it there (fixes the bare `<engine> --resume <id>` "No conversation found" when the session lives in a tank, not the engine's default home). With **no id** it opens an interactive picker across **all** tanks and **every directory**, newest first — filter with `/`, move with arrows/`j`/`k`, page with PgUp/PgDn — so you pick by title, no UUID. Headless `burn` sessions are hidden by default (they're one-shot lane tasks, not conversations you'd want to reopen); `--all`, or `a` inside the picker, shows them too, labeled `[burn]`. `[R]` on the board opens the same picker; `c` inside the picker opens `clikae clean` and returns. Which engines take part is not a list clikae keeps: every engine whose adapter can resume a session by id is enumerated, so `resume` and the board's Continue list always cover the same engines. Note the scopes differ on purpose — the board's Continue list is **this directory**, `resume` is **everywhere**. This reaches *backward* to a named session; `to` carries your *current* session *forward*. |
| `eval "$(clikae env <engine> <tank>)"` | Put the **current shell** on a tank (export its config env var), so the engine's own command and `clikae status`/`to` see it. The explicit alternative to the one-shot bare switch. |

**Your session outlives the terminal.** A bare switch runs the engine inside a
tmux session named `clikae-<engine>-<tank>`, so closing the window — or an ssh
connection dropping — leaves the work running. Come back with the same command
and you land back in it (the same conversation, not a new one), at whatever size
the terminal you are now sitting at happens to be. That is the roaming case:
start on the desktop, pick it up from a tablet over ssh.

Two clients can stay attached at once; clikae does not kick anyone off. If you
want the other one gone, `tmux attach -d` does that.

**The bottom row is the command back, the fuel, and what is red** — e.g.
`clikae resume a52bdc12 │ 5h 42% · 7d 65% │ !2`. The fuel is this tank's
vendor usage (how much of the 5-hour and 7-day window is spent), and the
session keeps it current itself: it takes one reading a few seconds after you
start, and one every five minutes after that, for as long as the session is
open. Nothing runs when the session is gone, and nothing is remembered between
readings — closing the session ends it. What you see when there is no number:

| on the row | what it means |
|---|---|
| `· 3h ago` | the reading is over an hour old — the row says so rather than presenting it as now |
| `·` | no reading (this tank has never been read, or the last one is over 24h old) |
| `○` | this tank is out of fuel right now |
| `⏳` | the access token expired — start a session on that tank, or run `clikae usage --wake <tank>` |

Reading it costs nothing: the row never calls a vendor, it only draws what is
already on disk. `clikae usage <engine> <tank>` fills the same reading by hand.

It degrades rather than breaks. With no tmux installed, no terminal (a pipe, CI),
or a `TERM` tmux cannot draw on, clikae runs the engine directly instead — same
command, same result, just no persistence. `clikae burn` behaves the same way.

One shape to know about, because it looks like it should work and doesn't:
`ssh yourmac 'clikae claude work'` — a command handed to ssh — gets a terminal on
stdin but a pipe on stdout, so it takes the direct run and your session does not
persist. Measured from a real second machine: `[ -t 0 ]` yes, `[ -t 1 ]` no. The
same applies to `RemoteCommand` in `~/.ssh/config`. Log in first and type the
command in the shell you land in, and you get the tmux session:

    ssh yourmac            # then, at the prompt
    clikae claude work     # persists; disconnect and come back to it

### Touch scrolling over ssh

Some touch terminals report a swipe as nothing but a left-button press and a
release at different rows, with no motion in between, even when the app
requests SGR mouse tracking (measured on a-Shell/iPhone, 2026-09-13).
clikae translates movements of at least two rows into tmux history scrolling:
finger up reads older output; finger down moves toward live output. Each row of
movement scrolls two lines by default. Tap in copy-mode to return to the live
view (in `copy-mode` and `copy-mode-vi` alike, whichever tmux's `mode-keys`
picks). Outside copy-mode, the click is always forwarded to the pane's program
first — same as tmux's own default — so a tap looks like an ordinary click, and
a swipe reaches the program as a click at the row you lift your finger on
(it already saw the press on the way down) while the pane also scrolls. Desktop
wheel and drag-selection bindings are unchanged.

Needs tmux **3.1 or newer** (`set-option -p`, pane-scoped options). Older
tmux keeps `mouse on` — installed unconditionally, before this check — and
silently skips the twelve key bindings and the five `@clikae_touch_scroll`/
`@clikae_touch_scroll_lines`/`@clikae_touch_pages`/`@clikae_touch_pages_rows`/
`@clikae_touch_drag` options; nothing breaks, but nothing translates either.

The bindings are installed when clikae creates a tmux session, and apply
to the whole tmux **server** — every session on it, not only clikae's own —
so if `~/.tmux.conf` binds its own root-table `MouseDown1Pane`/`MouseUp1Pane`
— or, with drag translation on, `MouseDrag1Pane`/`MouseDragEnd1Pane` —
clikae's `bind-key` overwrites it (there is no `-o`, and tmux has no per-key
opt-out). Setting `@clikae_touch_scroll off` (below) does not restore your
binding; it only makes clikae's copy of it a no-op. The drag pair is the one
exception, and only as far as **tmux's** default goes: with
`@clikae_touch_drag off` those four bindings run tmux's own command for the
key, so the stock behaviour is intact — but a binding *you* wrote is still
gone. In tmux's command prompt
(`Ctrl-b :`), use `set -g @clikae_touch_scroll off` to disable translation
server-wide, or `set -g @clikae_touch_scroll on` to restore it. Set
`set -g @clikae_touch_scroll_lines 3` to scroll three lines per row of movement.
These server-wide settings survive later clikae launches; put them in
`~/.tmux.conf` to retain them across server restarts. Drop the `-g` (`set
@clikae_touch_scroll off`) to override either setting for just the current
session instead. The multiplier must be a positive integer (invalid values
fall back to 2); the `off` value is matched case-insensitively (`OFF`, `Off`,
`0`, `no`, `false`, any case, all disable).

#### Tap the top or bottom of the pane to page (off by default)

A swipe asks for a distance; a page asks for one tap. With
`set -g @clikae_touch_pages on`, a **tap in the top three rows** of a pane
pages the history back one screen (entering copy-mode if it isn't already
there) and a **tap in the bottom three rows** pages forward one screen — then,
at the newest line, the next tap in that band returns to the live view, the
same ending a tap anywhere in copy-mode already has. A tap anywhere between
the two bands stays an ordinary click, and so does a bottom-band tap on a live
pane: there is nothing newer than the live view to page into, so the click
goes to the program unchanged.

This one is **off by default**, unlike touch scrolling: it takes a click that
currently reaches the program and gives it to tmux, so it has to be asked for.
Only `on`/`1`/`yes`/`true` (any case) turn it on — a value this option does not
recognise leaves today's behaviour exactly as it is.
`set -g @clikae_touch_pages_rows 5` changes the band height (default 3; a value
that isn't a positive integer falls back to 3). On a short pane the bands are
narrowed so a middle row always survives — the two can never meet and leave
nowhere to click — and a pane under three rows tall has no bands at all. Drop
the `-g` for the current session, or `set -p` for one pane, exactly as with the
touch-scroll options.

Both features are decided by one binding: a movement of two rows or more is a
scroll, a tap inside a band is a page, everything else is left alone. Turning
paging on therefore cannot cost you a swipe, and `@clikae_touch_scroll off`
does not turn paging off — the two options gate independently.

#### Drag to scroll live (off by default)

Everything above translates a press/release **pair**. Not every touch terminal
sends one. Measured on a real iPhone (a-Shell → ssh → tmux 3.4, 2026-09-16,
reading tmux's own event stream):

| gesture | what tmux receives |
|---|---|
| a tap | `MouseDown1Pane` + `MouseUp1Pane` on the same row |
| a flick, or press-and-drag | `MouseDown1Pane` + one `MouseDrag1Pane` per row crossed + `MouseDragEnd1Pane` — **and no `MouseUp1Pane` at all** |

So on that device the swipe translation above never fired, and tmux's own
`MouseDrag1Pane → copy-mode -M` won instead: the gesture ended in *"copied N
chars to tmux buffer"* rather than scrolling.

With `set -g @clikae_touch_drag on`, that motion is translated as it arrives —
the history follows your finger rather than jumping when you let go — at the
same `@clikae_touch_scroll_lines` speed. Moving **down** the glass reveals
**older** output, the way every touch surface works. Letting go at the newest
line returns the pane to the live view.

**It is off by default, and that default matters more than the others.**
`MouseDrag1Pane` on a pane with no mouse-tracking program is how you select
text with a mouse or trackpad, and a finger's drag and a trackpad's drag are
*the same tmux events* — there is no signal that could tell them apart. So this
option would cost every desktop its text selection to give the phones their
scrolling. With it off, the six drag bindings hand the key straight back to
tmux and you get stock behaviour, drag-selection included. Only
`on`/`1`/`yes`/`true` (any case) turn it on; `@clikae_touch_scroll off` turns
it off along with everything else.

Two things you do **not** need it for, on a-Shell specifically:

* **Selecting text** — a-Shell's own long-press selection works whether tmux's
  mouse mode is on or off, so nothing is lost by giving `MouseDrag1Pane` to
  scrolling on a phone.
* **Two-finger swipes** — a-Shell consumes those itself and sends arrow keys;
  they never reach tmux.

**Applications that draw their own screen get the wheel, not copy-mode.** A
full-screen TUI (Claude Code among them) runs on the terminal's *alternate
screen*, where tmux keeps no scrollback at all — copy-mode there would show the
current screen and nothing above it. When the pane is on the alternate screen
and not already in copy-mode, clikae sends the application mouse-**wheel**
events instead (one notch per two lines, at least one), which is the scrolling
it is already asking for. The application scrolls itself; tmux stays out of the
way.

### Make & manage tanks

| Command | What it does |
|---|---|
| `init <engine> <tank> [--alias]` | Create the tank directory; with `--alias`, also write a shell alias. |
| `init <engine> <tank> --adopt` | Mark an EXISTING directory a tank instead of creating one — refuses unless it already looks like that engine's own content. The way back for a directory that lands there after the one-time adoption sweep (below) has already closed: a restored backup, or a stray you've since confirmed is real. Never touches the directory's content; `clikae doctor` names any candidate. |
| `remove <engine> <tank> [--force] [--keep-data]` | Remove dir + alias + `.app`. `--keep-data` keeps the directory. |
| `rename <engine> <old> <new> [--force]` | Rename a tank (moves the dir, rewrites the alias, carries the login). |
| `migrate [<engine>] [--dry-run] [--force] [--keep-login]` | Adopt a hand-rolled config-dir + alias setup. |
| `alias <engine> <tank> [--name <n>]` | Write (or replace) a shell alias. Default name `<engine>-<tank>`. |
| `app <engine> <tank> [--terminal <app>] [--force] [--out <dir>]` | Generate a macOS `.app` launcher (default `~/Applications`). macOS only. `--terminal`: `terminal` (default), `iterm2`, `ghostty`. |
| `app --board [--terminal <app>] [--force] [--out <dir>]` | Generate a `clikae.app` that opens the **board** (the menu of recent sessions + tanks) instead of one tank — a single double-click button for the whole on-ramp. |

> **Ghostty launchers** pass their command through a trusted Ghostty **config file**
> (`--config-file=`), not `-e`. Ghostty pops an "Allow Ghostty to execute…?" dialog
> for an externally-injected `-e` command (so a `-e` launcher looks like an empty
> shell until you click Allow); a config file is trusted, so the window just opens.
> The config lives inside the `.app` and is found via `path to me`, so the launcher
> keeps working if you move it.

> **What makes a directory a tank.** Every tank carries a `.clikae-tank` marker
> file (just the engine name, one line) inside it — that marker, not the
> directory's name or content, is what `clikae tanks`, `burn`'s reroute, and
> every other reader treat as "this is a real tank". Only the marker's FIRST
> LINE is ever read or compared, and only its first 64 characters; anything
> after the first newline is ignored, as is anything past that 64th character
> (trailing whitespace on the name is still tolerated).
> `init` (and agy's own tank creation) stamps it the moment a tank is made.
> **Upgrading from an older clikae:** the first command you run against an existing store
> performs a one-time sweep that marks every existing tank directory (no
> exceptions, no re-login required) and then writes a flag
> (`$CLIKAE_HOME/state/tanks-adopted-v1`) so it never runs again — a
> directory that shows up later with no marker is not a tank. If that flag
> can't be written (a read-only or shared store), clikae keeps recognising
> your tanks in memory on every run and says so once; `clikae doctor` names
> the state and `clikae doctor --adopt` retries the write. **A directory that
> shows up AFTER the sweep closes** — a restored backup, one you've since
> confirmed is real — has no automatic way back through `init` (it refuses
> any existing directory): use `clikae init <engine> <tank> --adopt` instead,
> which marks it a tank without touching its content, and refuses unless it
> already looks like that engine's own content.

### Keep burning when a tank runs dry

| Command | What it does |
|---|---|
| `to [target] [tank]` | Carry this shell's session onward when a tank runs dry. **Bare `clikae to`** falls through to the next tank in your burn order (same engine → a real resume; a different engine → a cold-start brief). Your tanks are the reserve — nothing to configure. |
| `auto [ask\|safe\|full]` | **(BETA, claude-launched sessions only)** How much clikae carries on its own when a session **you launched through `clikae`** hits the limit — it has no effect on alias/`.app`/other-engine launches. `ask` (default) prompts; `safe` auto-resumes same-engine + asks to cross; `full` keeps going (same-engine = resume, cross-engine = a cold brief). The board's `A` key cycles it. |
| `watch <engine> [<tank>] [--auto] [--to <target>]` | Watch a session and fall through to the next tank in the burn order when it runs dry (cross-engine via `--to`). |
| `wake [on\|off]` · `wake <engine> <tank>` | Stay where you are and let the tank pick itself back up: when the limit lifts, clikae types `go` into that tank's own session and the conversation continues. Asked once, then remembered. |
| `burn <engine> <tank> --artifact <path> -- <cmd…>` | Run a **headless** task on a tank; verify it by the artifact (not the exit code); on a dry tank, re-fire the same task on the next reserve tank. The headless sibling of `to`/`watch`. See "Headless tasks" below. |

> **Supervised launch (BETA · claude · feedback welcome).** When you start claude
> *through* clikae, clikae stays as the parent. **When that session ends after
> hitting its limit** — quit the dead session in an interactive run; a headless
> `claude -p` exits on its own — clikae carries you onward to the next tank in your
> burn order (per `clikae auto`) in the **same terminal** (one redraw), and your
> conversation continues there. Honest limits: it advances *on exit*, not by killing
> a live session mid-stream (that needs engine support — see issue
> anthropics/claude-code#35744); one hop per run; **claude and codex** are
> supervised — agy has one global login and no per-tank signal. Nothing runs in the
> background unless you launched it through clikae (no daemon) — deliberate.
> `clikae status` shows what it carried (recent carries). **Tell us how it feels.**

### The cockpit role — dispatch, don't spawn

A coordinating session ("the cockpit") should hand build/review work to worker
tanks with `clikae burn` rather than spawning it through its own in-session
Agent/Task tool — a spawn like that spends the cockpit's OWN weekly budget on
work a worker tank was going to pay for anyway. That rule is easy to forget
exactly when a session is busiest, so `clikae cockpit` makes it the machine's
problem instead of memory's:

| Command | What it does |
|---|---|
| `cockpit` | Show the current cockpit tank (or that none is set). |
| `cockpit [<engine>] <tank>` | Mark this tank as the cockpit: installs a guard there and removes it from wherever it was before. A bare unique tank name resolves like `clikae <name>`, and `agy` is accepted for `antigravity` the same way `clikae burn` accepts it. |
| `cockpit --off` | Remove the guard everywhere and forget the role. |
| `cockpit --allow-agents <dur>` | Temporarily lift the guard (e.g. `4h`) without removing it. |

The guard is a PreToolUse hook on the cockpit tank's `Agent` tool: it refuses
a spawn whose model is missing, or whose model is fable/opus/sonnet (any
family-prefixed form too — `claude-fable-*`, `claude-opus-*`,
`claude-sonnet-*`, `opusplan`, or the bare alias) **and** whose prompt reads
as a build/review lane — naming the
current idle reserve and the exact `clikae burn <engine> <tank>
--prompt-file <f> --artifact <path>` shape to use instead. It also refuses a
checked spawn outright when the prompt is over 1,500 characters,
regardless of content. **The guard never reads `subagent_type`** — `model` is
the only thing that decides whether a spawn gets examined at all.

**fable, opus and sonnet are checked; haiku is not.** A fable spawn spends
the cockpit's weekly budget the same way an opus one does, and this guard
exists to move that spend onto a worker tank — so the only exempt family is
haiku. A haiku spawn is untouched regardless of `subagent_type` or prompt
content; a fable/opus/sonnet spawn — `Explore` included — is checked against
the prompt heuristic below exactly like any other. Provider spellings are
placed in their family (`us.anthropic.claude-sonnet-4-5-v1:0`,
`claude-sonnet-4-5@…`, `sonnet[1m]`); the exemption itself matches only
exact, explicit prefixes (`haiku`, `claude-haiku-…`, `claude-3-5-haiku…`,
`claude-3-haiku…`), so a lookalike such as `claude-opus-4-haiku` or
`opus.anthropic.haiku` is checked, not exempted. A model id the guard does
not recognise is **checked like
opus/sonnet**, not waved through: a refusal names it as unrecognised, and a
spawn that passes prints one line saying the id was unrecognised. The hook **fails closed**: a call it cannot read (an empty or
malformed payload, no tool input object, a `\u0000` escape anywhere in the
payload) is refused with the reason, and the
escape hatches below are checked before the payload, so that refusal can
always be lifted.

**jq is a runtime dependency of the hook, not just of the install.** At hook
execution time jq must be on PATH or every Agent spawn on the cockpit is
refused with `cockpit-guard: refused — jq is not installed (the guard parses
the call with jq; clikae cockpit needed it to install this hook). The guard
fails closed: a call it cannot read is not let through.` — including haiku
spawns, which the guard would otherwise never look at. That is the correct
behaviour (fail closed), but it bites when PATH differs from the shell you
installed from: a GUI launch, or any PATH without `/opt/homebrew/bin`. If
every spawn is suddenly refused, check `command -v jq` **in the tank's own
environment** first. `clikae doctor` reports jq and where it found it.

This is not a general permission gate. The role, and the hook, live on
exactly one tank at a time; moving it with `clikae cockpit` arms the new
tank first and only cleans up the old one once the new one is armed and
recorded, so a failure partway through never leaves you with no cockpit
guarded at all. A human's own hooks on that tank are marked apart from the
guard's and are never touched — the settings.json write rides the same
mechanism as `clikae settings apply` (below), so **the file round-trips
through jq**: key order gets normalized and CRLF becomes LF. Content survives
intact (a hand-written hooks block, extra keys, anything else in the file);
byte-for-byte formatting does not.

**The cockpit is never a burn target, either.** The hook only sees the
cockpit's own in-session spawns; a headless `clikae burn` never passes
through it. So `clikae burn` asks the same question before every engine
launch — the tank you name, a `--to` hop, agy's own walk, a symlink alias of
the cockpit's directory — and refuses with the guard's sentence
(`cockpit-guard: refused — <engine>/<tank> is the recorded cockpit …`)
before anything starts. Auto-reroute skips the cockpit. `--force-cockpit` is
the operator override: the burn runs, and says on stderr that it is burning
the cockpit.

**The prompt heuristic is a tripwire, not a classifier — `--allow-agents` is
the door.** It matches the issue's own phrases (`worktree`, a git commit/push,
`REVIEWER`/an adversarial review, a test run) OR'd with a widened set of bare
imperative verbs (`commit`, `push`, "open a PR", `review`, `grade`, "run
tests", "make CI") because missing a real build/review lane is the expensive
direction (that's the incident this guard exists for) and a false refusal is
cheap (the escape hatches below exist precisely for this). Measured against a
14-item corpus (`tests/bats/cockpit-guard.bats`) — 8 prompts that read as
dispatchable work, 6 that don't — the heuristic gets 11/14 right. On THIS
corpus, all 3 misses are false refusals, not false allows, and all 3 are
structural: an innocuous prompt that merely **mentions** one of these words
in passing (a question about `git push --force-with-lease`, about a
`worktree` section in the docs, about what `npm test` does) gets refused
exactly like a prompt that asks for the real thing, because a plain keyword
match can't tell "explains X" from "do X" apart, and every attempt to narrow
the pattern enough to allow the innocuous case would also let its
should-refuse sibling in this same corpus through. If a refusal looks wrong,
that's expected, not a bug — `--allow-agents` (below) is how you get past it.

**"3 misses" is a property of this corpus, not a bound on the false-refusal
rate.** A second, adversarially-innocuous 10-prompt corpus (round-2 review,
`REVIEW-cockpit63-r2.md`, plus 4 more in the same spirit) scores 8/10
refused — worse, not better, because these were chosen specifically to
brush against a trigger word without asking for build/review work:

| Prompt | Outcome |
|---|---|
| Find every file that mentions push notifications and list them | refused |
| Review the attached spec and tell me if the wording is clear | refused |
| What does the word "commit" mean in the context of database transactions? | refused |
| Explain how git worktrees differ from clones, conceptually | refused |
| Search the codebase for where we grade student submissions | refused |
| Summarize the customer reviews in reviews.csv | **allowed** (`\breview\b` doesn't match "reviews") |
| What does npm test actually run under the hood? | refused |
| Can you explain what 'open a PR' means for someone new to GitHub? | refused |
| List the files that were pushed in the last release | **allowed** |
| Grade how readable this poem is, out of 10 | refused |

Expect a false-refusal rate closer to this table's than the 14-item corpus's
on real, adversarially-chosen prompts — that's still the cheap direction
(`--allow-agents` exists precisely because false refusals are meant to be
routine, not rare).

Sometimes the right call is to spend the cockpit tank's own budget on purpose
("burn the cockpit tank tonight") — a guard that cannot be lifted gets
deleted instead of obeyed, so there's an escape hatch: set
`CLIKAE_COCKPIT_ALLOW_AGENTS=1` in the environment, or run `clikae cockpit
--allow-agents <dur>` for a timed allowance. `clikae cockpit --off` removes
the guard everywhere and clears any live allowance; it sweeps every tank
(not just the recorded one) and never aborts partway through — a tank with a
broken settings.json is reported at the end, by name, but does not stop the
rest of the sweep from being cleaned up.

### Inspect

| Command | What it does |
|---|---|
| *(no args)* | Open the **home dashboard** — your "tank board": every tank grouped by engine, the one active in this shell marked, account + alias name, a **Continue** list of recent sessions **in the directory you are standing in** (the heading says which one; when the store holds more than the list shows, a dim line says how many and points at `clikae resume`, which covers every directory), an "Also available" list of engines/targets you can open without a tank (e.g. `codex`, `agy`). On a terminal it's an **interactive launcher**; press `?` for the full key legend. Keys: ↑/↓·`j`/`k`·Tab/Shift-Tab move, `g`/`G` top/bottom, `1`-`9` jump, `[`/`]` reorder (the board IS the burn order), ⏎ open (a Continue row offers _resume_ vs _switch fresh_), `r` carry session, `R` open the full cross-tank resume picker, `x` incognito, `n` new, `a` rename the tank, `d` delete, `s` toggle solo (in/out of the fleet), `m` the memory (Soul) dial, `c` clean up disk space (opens `clikae clean`, returns to the board), `/` filter, `A` cycle autonomy (ask/safe/full · BETA), `l` pick language, `q`/Esc quit. Piped/scripted it prints the same board as plain text (`CLIKAE_NO_INTERACTIVE` forces that). |
| `lang [<locale>]` | Show or set the interface language (dashboard + prompts) — nine of them: `en-US`, `ja-JP`, `zh-TW`, `zh-Hans`, `ko-KR`, `es-ES`, `de-DE`, `fr-FR`, `pt-BR`. Bare `clikae lang` lists them. Persists to `$CLIKAE_HOME/lang`; the board's `l` key opens a language picker. Resolution when unset: `$CLIKAE_LANG` > saved choice > `$LC_ALL` > `$LANG` > en-US. Adding a tenth is a self-contained PR — see [Adding a language](adding-a-locale.md). |
| `tanks [-p\|--paths] [--json]` | List all tanks, with the logged-in account where the adapter can tell. (Aliases: `list`, `ls`.) `--json` emits machine-readable output `{cli, profile, account, path}` for scripts and the GUI. 🔴 **Do not build a path out of `cli` + `profile`** — `cli` is the name you *invoke* (`agy`) while the store directory keeps the engine's own name (`antigravity`), so the two differ for Antigravity. `path` is authoritative for where the tank lives; use it. |
| `status [<engine>] [--json]` | Show which tank each engine is on **in this shell**. `--json` emits one object per engine with a `state` enum. |
| `doctor [--adopt]` | Read-only health check: which supported engines are installed and logged in, how many tanks each has, the environment, and what to do next — including whether this store's tanks are adopted (see the marker note above). `--adopt` retries writing the adoption flag for a store where it never persisted; harmless when the store is already adopted. |
| `info [--json]` | Show install paths, platform, adapters, and tank count. |
| `adapters` | List supported engines with descriptions. |
| `demo` | A 30-second guided tour in a throwaway sandbox — shows isolated tanks, the tank board, and the `to` idea (your tanks are the reserve), then cleans up. Touches nothing real; the accounts are simulated, so it needs no installed engine. |

### Free disk space — `clikae clean`

| Command | What it does |
|---|---|
| `clean [--dry-run] [--older-than <days>] [--min-size <MB>]` | Move old session transcripts/databases to the **Trash** to free disk space (never touches tank configs, memory, or settings, and never `rm`s a session outright — emptying the Trash is what actually reclaims the space). The zero-knowledge path is the whole design: type `clikae clean`, look at ONE checkbox list in three sections (biggest first within each), press Enter, confirm in red. **Redundant (safe)** — pre-checked: *stale copies* (`to`/relay and a cross-tank resume *copy* the session and never clean the source; copies are grouped per session across all tanks, the largest is kept, and a copy is pre-checked only when it's provably contained in the kept one) and *orphaned subagent data* (claude's leftover `<sid>/` sibling dirs; moving a transcript to the Trash takes its sibling dir with it). **Untouched for 30+ days** — pre-checked: sessions older than `--older-than` (default 30). **Big but recent — your call** — unchecked: sessions of 20 MB or more that the first two sections didn't claim (the space hogs, visible with no flags), plus copies with unique content, labeled `diverged — has unique content`. A session any process still has open is never offered, in **any** section — the guard that closed a real data-loss incident where a live session slipped through unchecked (v0.14.1 — see CHANGELOG.md). `--min-size` filters the candidate pool by size — given alone it drops the age cutoff (space usually lives in big *recent* sessions); combined with `--older-than` a candidate must satisfy both. `--dry-run` prints the same sectioned list with each row's `[x]`/`[ ]` state, without moving anything; a non-TTY run refuses to move anything. If `~/.Trash` isn't usable, clikae says so **before the confirm** and touches nothing — it never deletes as a fallback, because you asked it to move something, not to destroy it. If an individual item can't be moved mid-run it is left exactly where it is and named, and the summary counts only what actually moved. The board's `c` key and the resume picker's `c` key open the same screen and return. (`clikae resume cleanup`, where this flow first shipped, is a hidden alias that forwards here.) |

### Antigravity (agy) — same verbs, one power mode

agy hardcodes `~/.gemini` and ignores env vars, so clikae can't switch it
per-shell like other engines. It folds into the **same verbs** anyway, via an
opt-in symlink-swap power mode (global: one tank active at a time across all
terminals; reversible):

| Command | What it does |
|---|---|
| `init agy <tank>` | First time: warns and asks before taking `~/.gemini` over (backs it up, migrates your current login into a `default` tank), then creates `<tank>`. After: just creates the tank. |
| `agy <tank>` | Switch the active tank (refuses if agy is running) and start agy. Prints a global-switch notice. |
| `remove agy <tank>` | Remove the tank. Removing the **last** tank offers to restore a normal `~/.gemini` and turn the power mode off. |
| `agy --release` | Restore a normal single-account `~/.gemini` from the active tank, keep the tank dirs. |

## Shells

`clikae` auto-detects your shell from `$SHELL` and writes the alias to the right
rc file: **zsh** (`~/.zshrc`), **bash** (`~/.bash_profile` on macOS, else
`~/.bashrc`), and **fish** (`~/.config/fish/config.fish`). For fish it emits fish
syntax — `alias <name> 'env VAR=val <binary>'` — because fish has no inline
`VAR=val cmd`; the result behaves identically. `clikae remove` cleans up the
block in any of them.

## Migrating an existing setup

Already juggling accounts by hand — say a `~/.claude-acct-a` / `~/.claude-acct-b`
pair with aliases in your `~/.zshrc`? `clikae migrate` adopts that into clikae:

```bash
clikae migrate --dry-run   # preview: which dirs move where, which aliases change
clikae migrate             # do it (asks to confirm first)
```

It scans your shell rc for aliases that set the engine's config env var and
invoke the engine. For each one it:

1. moves the referenced config directory under `~/.clikae/profiles/<engine>/<p>/`,
2. rewrites the alias into clikae's managed sentinel block.

The rc file is backed up to `<rc>.clikae.bak.<timestamp>` first, and an existing
clikae tank is never overwritten. Pass an engine name (`clikae migrate gh`) to
migrate a different tool's aliases. Default is `claude`.

> ⚠️ **Don't migrate a config dir that's currently in use.** `migrate` *moves*
> the directory, so if a process is running against it right now (e.g. you run
> `clikae migrate` from inside the very `claude` session whose
> `CLAUDE_CONFIG_DIR` points at the dir being moved), you pull the directory out
> from under that live process — it can fail to write, or recreate an empty dir
> at the old path and leave you with two half-states. Run `migrate` from a fresh
> shell with no instance of that engine active. `--dry-run` is always safe.
>
> As of v0.4, `migrate` guards against the most common form of this: if
> `$CLAUDE_CONFIG_DIR` (or whichever env var the adapter uses) currently points
> at a directory slated to move, it refuses and tells you to retry from a fresh
> shell. The guard is not bypassed by `--force` — it protects your data, it
> isn't a confirmation prompt.

> 🔑 **macOS + claude: expect a one-time re-login per migrated tank.** On
> macOS, Claude Code keeps its login token in the **login Keychain**, not inside
> `CLAUDE_CONFIG_DIR` — and the keychain entry is keyed by the config-dir path.
> Because `migrate` moves the dir to a new path, claude no longer finds the token
> and asks you to log in once for each migrated tank. Your data is intact;
> only the saved login doesn't follow the move. To avoid the re-login, pass
> `--keep-login`, which copies the saved token from the old path's keychain entry
> to the new one (macOS only; it never reads or transmits the token anywhere — it
> stays in your Keychain). macOS may prompt you to allow keychain access.

## Carrying a session when you hit a usage limit — `clikae to`

This is clikae's origin story: you keep a second account precisely because one
account's quota runs out mid-task. `clikae to` lets you carry the work onward —
like swapping a fuel tank — and **keep the same conversation going** on a fresh
quota.

```bash
# You're working on claude tank `a` and just hit its limit. From the same project
# directory, carry the conversation onto another tank and keep going:
clikae to b                     # same engine → a real resume, on b's quota
clikae to codex                 # a different engine → a written brief (cold start)
clikae to codex work            # cross to a specific tank of another engine
```

clikae auto-detects which engine + tank this shell is on: first the live env var,
then — since the bare switch / aliases / `.app` run the engine with a prefix
assignment that never reaches the parent shell — **the tank with this directory's
most recent session** (the one you were just in here). So `switch → work → to`
works from one shell. To pin a shell to a tank explicitly instead, use
`eval "$(clikae env <engine> <tank>)"`. The target resolves **engine-name-first**:
a known engine name crosses to it; anything else is a tank of your current engine.
clikae always **announces which mechanism it used** so resume-vs-brief is never a
guess.

**Same engine (a resume).** For Claude Code, clikae finds the **current
directory's** most recent transcript under the source tank, copies it into the
target tank, and runs `claude --resume <id>` there — so the conversation
continues, but every new turn burns the target tank's quota. The source tank is
left completely untouched (it copies, never moves), so you can always go back.
A preview + confirm is shown before anything moves; `-y` skips it, `--fresh`
switches tanks without carrying, `--session <id>` carries a specific session.

> Carry-over relies on Claude Code's on-disk transcript layout
> (`<config-dir>/projects/<slug>/<id>.jsonl`) and `--resume`. It's verified
> against current Claude Code; if a future version changes that layout, it falls
> back to a fresh start rather than doing anything destructive.

**A different engine (a brief).** A different *model* or *vendor* can't resume a
foreign session — there's no shared transcript format. So clikae writes a
**handoff brief** (what you're doing, what's done, what's next) and starts the
target engine seeded with it as the opening prompt. clikae tries to write a
**summary** automatically: if a local model CLI is on your PATH (`apfel`,
`ollama`, or `llm`), it's used to summarise the brief for free — set
`CLIKAE_HANDOFF_AUTOLOCAL=0` to disable that auto-detection. Otherwise the brief
is a **raw extract** (session metadata + your recent prompts), clearly labelled
as raw. To force a specific summariser, point clikae at any model so writing the
brief costs nothing on the tank that just ran dry:

```bash
export CLIKAE_HANDOFF_SUMMARIZER='llm -m my-local-model'   # any stdin→stdout command
clikae to codex                                            # the model writes the brief
```

The summarizer (auto-detected or `CLIKAE_HANDOFF_SUMMARIZER`) receives, on stdin,
an instruction line followed by the tail of the session transcript, and writes the
brief to stdout. If it produces nothing, clikae falls back to the raw extract so a
handoff is never lost. Tune how much
transcript is fed with `$CLIKAE_HANDOFF_LINES` (default `60`). Carrying onward is
**read-only** on the source — it never touches the source session or any tank.

> Under the hood, `clikae to` delegates to `relay` (same engine) or `handoff`
> (different engine). Both remain available as hidden aliases — e.g. `clikae
> handoff claude --out HANDOFF.md` just writes a brief to a file without starting
> anything. Run `clikae help to` / `help relay` / `help handoff` for details.

## Ambient: notice a dry tank and switch (`watch`)

Instead of switching by hand, let clikae watch for the moment a tank runs dry and
fall through to the next one. **Your tanks are the reserve — there's nothing to
set up.** Just watch the current session:

```bash
clikae watch claude            # offer to switch to the next claude tank when dry
clikae watch claude --auto     # switch automatically (asks once for consent)
clikae watch claude --to codex/work   # cross to a specific tank/engine instead
```

When it detects a dry tank it carries onward to the next tank of the same engine
(skipping any that are themselves over quota); cross-engine needs an explicit
`--to`. By default it **asks first**; `--auto` switches
automatically after a **one-time consent** (remembered in
`$CLIKAE_HOME/auto-relay-consent` — delete that file to revoke), and always tells
you what it did.

> **Honest caveat.** An interactive engine hitting its usage limit doesn't exit,
> returns no code, and fires no hook — so the only thing clikae can watch is what
> the limit writes to disk. For claude that's the session transcript; for agy
> it's `~/.gemini/antigravity-cli/cli.log` (agy's `-p` run exits 0 with empty
> output, so the log line is the only signal). codex's limit is **proven not
> persisted** to its transcript, so a dry tank can't be detected for codex from
> disk. Confirm/tune the match the first time you actually get limited:
>
> ```bash
> clikae watch claude --check          # would the pattern fire on this session?
> CLIKAE_LIMIT_PATTERN='…' clikae watch claude   # override the match
> ```

While it watches, the same loop also refreshes every tank's usage reading on a
heartbeat (#132/#133), so the board has a fresher number than "whenever
somebody last ran `clikae usage`". It never talks to a vendor itself — it calls
the same `usage_read` everything else does — and every tank keeps its own
cadence: `CLIKAE_WATCH_USAGE_INTERVAL` (default: the usage cache's own TTL,
`CLIKAE_USAGE_TTL`, floor 10s) on success, and on a failure one of three
things (#136):

| what came back | what the poll does next |
| --- | --- |
| a reading | back to the base interval |
| `rate-limited` (HTTP 429) | waits the vendor's own `Retry-After`, clamped to the base interval and to `CLIKAE_WATCH_USAGE_MAX_BACKOFF` (default 1800s). A missing, negative, zero, non-numeric, HTTP-date or out-of-range header is not a hint — it falls back to the row below. |
| `expired-token` / `no-credentials` | straight to `CLIKAE_WATCH_USAGE_MAX_BACKOFF` and marked. Neither starts working because we waited a little longer, so there is no ramp to climb. The board says so immediately either way — a cached expired reading draws `⏳ expired · usage --wake <tank>` the moment it lands. |
| anything else (no connection, a timeout, a 5xx, an unreadable body) | doubles, capped at `CLIKAE_WATCH_USAGE_MAX_BACKOFF` |

## Ambient: turn GitHub replies into wake events (`watch github`)

A different source under the same verb: instead of watching a tank's own
transcript for a dry limit, `clikae watch github` polls GitHub's search API
for every issue/PR update in an org — including replies on issues YOU
opened — plus @mentions of you, so a collaborator's reply doesn't sit
unseen until someone happens to run `gh` by hand.

```bash
clikae watch github --org CVERInc              # foreground, polls every 10m, Ctrl-C to stop
clikae watch github --org CVERInc --interval 5m # a tighter poll interval
clikae watch github --org CVERInc --once        # poll exactly once and exit — cron / a Stop hook
clikae watch github --org CVERInc --since 2026-09-01T00:00:00Z  # cold-start bound, default 24h ago
```

`--org` defaults to the login `gh repo view` reports for this directory's
GitHub remote when omitted. Every new event prints live as one line — this
is the actual output line for a collaborator's reply that @-mentions you on
an issue YOU opened (P2-2, 2026-09-13 fix-round-3 review: regenerated from
what this implementation really prints — the reply's own text decides
`kind`, but only the issue's TITLE is ever shown, never the reply text
itself):

```
[ DONE ] github CVERInc/reef#313 mention by collaborator: auth redirect
```

— a collaborator's reply reaching you even on an issue YOU opened (the org
query has no `-author:<self>` filter; see the caveat below for exactly what
self-exclusion means instead). It's also appended,
as flat JSON, to `$CLIKAE_HOME/logs/watch-github-<org>/events.jsonl` for a
durable trail, and — the actual wake — every poll that finds at least one
new event writes a burn-status-shaped file to
`$HOME/.clikae/logs/watch-github-<org>-<epoch>/status.json` — burn's own
directory layout, not a lookalike location `clikae wait` can't resolve.
🔴 Deliberately `$HOME`, not `$CLIKAE_HOME` (P3-2, 2026-09-13 fix-round-3
review) — the one path in this feature that ignores a `$CLIKAE_HOME`
override, the same as burn's own status files always have; a sandboxed
`$CLIKAE_HOME` does not sandbox this one file. So
`clikae wait watch-github-<org>-<epoch>` (the run_id printed inside the
file) or `clikae wait --latest watch-github-<org>` (a cockpit that doesn't
know the epoch yet) returns 0 and prints the events, the same reader a
cockpit already blocks on for `clikae burn` — that's what a cron job or
Stop hook calling `--once` actually has to consume, not the JSONL log.

The cursor (the EXACT max updated_at this poll actually processed — no lag)
persists at `$CLIKAE_HOME/state/watch-github/<org>.cursor`; a small
seen-file next to it de-dupes by (repo, issue number, updated timestamp).
That file is compacted every poll **by age, with a row-count floor**: every
row newer than 1800 seconds below the lower of (the last completed tail
sweep's start, this poll's cursor) is kept whatever the row count — that is
the only ground anything re-reads, so nothing inside it can be announced
twice — and the newest 5,000 rows are kept whatever their age, because that
second, much longer retention is what decides `opened` vs `comment` for an
issue nobody has touched in months. It used to be an unconditional
`tail -n 5000`, which meant a burst of more than 5,000 rows in one poll lost
its oldest rows to the compaction in that same poll and got them announced
again, as `opened`, by the next sweep (#111). Cold start (no cursor yet) bounds to the last 24
hours by default — `--since` overrides that bound — and each query
paginates ascending (oldest-unseen-first) up to 500 rows (5 pages of 100)
per poll. A busy org's backlog therefore can't outrun this permanently: a
poll cut short by the cap still leaves the cursor at the end of what it
read, so the next poll picks up exactly there — the trade-off is a
backlogged cold start crawls forward from `--since`/24h-ago instead of
surfacing today's newest activity first.

GitHub search's own indexing delay (real writes lag the search index by
some minutes) is NOT covered by lagging the cursor above — that was tried
in earlier rounds of this feature and turned out to permanently stall a
busy org (any 300-second window holding ≥500 rows pinned the cursor
forever; see CHANGELOG). Instead, a separate bounded "tail sweep" runs
once every 5 polls, or right after a truncated one: one or more requests,
oldest-first (same order as the main query), re-reading a window just
below the cursor and delivering anything the main query may have missed
while it was still indexing — oldest-first so a busy org's own
already-seen recent activity can't fill a newest-first page before the
sweep reaches older rows. Late-indexed rows are spread across the whole
window, though, not only at its old end, so a truncated sweep (below) can
still miss some in the newer part it didn't read. That window is the
time since the last sweep STARTED (at least 300s) plus a fixed 300s
overlap with the previous sweep, so a row updated just before one sweep
but indexed just after it is still re-read by the next — an epoch
persisted next to the cursor and read back directly,
not inferred from `--interval` or from how many polls elapsed times any
single one of their gaps (an earlier version of this feature used a flat
300s window regardless of spacing, which only ever covered the gap
between sweeps when `--interval <= 60s`; a later version multiplied one
poll's own gap by how many polls had elapsed, which undercounted the
moment polling wasn't evenly spaced — a live loop recovering from
back-off is exactly that case; the default interval is 10m, and a
`--once` poll run from cron never knows `--interval` at all — see
CHANGELOG). It never advances the cursor itself, so it cannot re-create
that stall; reading paginates within the same 5-page/100-per-page budget
the main query uses, and a window still not fully covered after that is
reported as "lag window truncated" and dropped rather than read further,
so it costs at most 5 extra requests per poll.

Every ALREADY-SEEN issue/PR that gets updated again costs one more request —
`issues/<n>/timeline` — to learn who actually did it (a reply, a review, a
label, an assignee change) and whether that was you. That endpoint has no
`direction` parameter, so learning the LATEST event means reading its own
`Link: rel="last"` page number and fetching that page (up to 2 requests,
still counted as 1 lookup against the budget below) — the one endpoint
whose events carry an actor for review/label/assignee shapes too, not just
a comment. Bounded to 50 such lookups per poll, spent oldest-unseen-first
(the order the asc-paginated search results stream in), and stopped early
once GitHub's own
`X-RateLimit-Remaining` drops under 100. A candidate beyond that bound is
still reported — never silently dropped — just as `by unknown` instead of a
real login. If that fetched event's own text @-mentions you, `kind` is
`mention` instead of `comment`/`review` (P2-2, 2026-09-13 fix-round-3
review — this REPLACES a separate `mentions:<self>` search query that used
to run every poll: once the org query above lost its `-author:<self>`
filter, that second query became a strict subset of the first, so it was
mostly buying nothing but extra requests. A brand-new issue/PR whose own
OPENING text mentions you is not covered by this — no lookup happens for a
fresh number, so there is no body text to check).

Rate limits: normally 1 search request per poll (up to 5 when paginating,
plus up to 5 more for the tail sweep above), plus up to 50 activity lookups
(each up to 2 requests) against the core API's much larger budget.
On a genuine rate limit (429, or a 403 the response attributes to it, or a
5xx) the interval backs off ×2 up to 1h from a floor of 60s; the cursor is
never advanced past a page that failed to read, so nothing is silently
skipped — a poll cut short by the 5-page cap prints "truncated: continuing
next poll" and it does: pagination runs oldest-unseen-first, so the cursor
lands EXACTLY at the last row this poll actually read, and the next poll's
query starts exactly there. No backlog, however large (short of the one
case under Known limits below), can stall this
permanently — the cursor only ever advances, never regressing into a
window it has already re-read. A PERMANENT failure —
missing OAuth scope, SAML enforcement, a bad org name — is retried once,
then reported and the command exits 1; it never enters back-off, since no
amount of retrying fixes those. `--once` returns 0 only when a poll
actually succeeded (events or none); 1 on any failure, so a cron job can
tell "quiet today" from "I've been failing silently".

**Known limits.** The one case the cursor above can still get stuck on:
≥500 issue/PR updates sharing the exact same `updated_at` second (the
5-page cap) pins the cursor at that second forever, since it can never
read past all of them in one poll — extremely unlikely given GitHub's own
secondary rate limits, but not impossible, so it's named here rather than
covered by the "no backlog, however large" claim above. Within one poll,
events the tail sweep finds are appended in `updated_at`-ascending order
(oldest first, same direction as the main query — fixed 2026-09-14
fix-round-6 review; an earlier version read the sweep's window
newest-first), but AFTER the main query's own batch, and the sweep's
window sits below the cursor the main query just advanced to — so
`events.jsonl` is still no longer strictly non-decreasing the moment a
sweep delivers anything; no consumer this feature ships relies on that
ordering today.

Requires `gh` already logged in — this feature never reads or writes a token
itself, it uses whatever account `gh auth login` already set up, and refuses
immediately (exit 1) if `gh auth status` fails.

> **Honest caveat.** GitHub's search API returns issue/PR-level rows, not a
> per-comment feed, so its own `user.login` is always the ISSUE's author,
> never whoever's activity just touched it. Self-exclusion and the `kind`
> shown for an update therefore never trust that field: for a number seen
> before, both come from the timeline lookup above (round 1 of this feature
> compared the issue's own author against self instead — which meant a
> collaborator's reply on an issue YOU opened was invisible no matter what,
> the exact headline case above, not a documented exception to it). A number
> never seen before needs no lookup — opening IS the event, and the row's
> own login is unambiguously who did it; a self-authored new issue is
> recorded as seen but is not itself an event. `kind` is `opened`,
> `comment`, `review`, `activity` (any other timeline event — a label, an
> assignee change, …), or `mention` (an ALREADY-SEEN number whose latest
> fetched activity's own body text @-mentions you — see the P2-2 paragraph
> above; a fresh number's own OPENING text is not covered, so a brand-new
> issue/PR that @-mentions you still reads `opened`, never `mention`).
> Past the 50-lookup budget or the API's own rate limit, an update's actor
> cannot be verified and is reported as `unknown` rather than guessed — see
> the rate-limits paragraph above.

## What is running right now — the board's Live section

Type `clikae` and the top of the board lists the sessions alive on **this
machine**, in the same columns as everything else:

```
  ▸ Live
    ● work    claude   "auth redirect — next: retry the callback test"
    ● x       codex    "Transcreate the escape guides to 7 locales"

  ▸ Tanks
    …
```

**Enter attaches to it.** It does not start anything — that is the difference
between this section and Resume, which relaunches a past conversation. A live
session is one keypress from being back in.

The third column is the session's title, not a status word, because `claude/x`
does not tell you *which* piece of work that is.

**Two live sessions on the same tank** (a bare one and a resumed one, say) draw
two rows: the second is badged `#2` so they're not identical-looking
duplicates, and each shows its OWN title rather than both collapsing onto
whichever transcript happened to be written to most recently. For claude,
that's true whether a window was started with `clikae resume` (or a
hand-typed `--resume <sid>` / `-r <sid>`) or started completely fresh: claude
accepts a session id handed to it at launch (`--session-id <uuid>`), so clikae
mints one itself and hands it to the engine before it ever runs, then records
that same id against the tmux window right after spawning it —
but only for a launch whose own argv carries no resume/continue signal of its
own. `clikae claude x -- --continue`, `-- -c`, or a bare `-- --resume` (the
picker) run untouched, with no `--session-id` appended, because claude itself
refuses to start with `--session-id` alongside `--continue`/`--resume` unless
`--fork-session` is also given.

Not every engine can be told its session id up front. codex and antigravity
expose no equivalent flag today, so a window running either of those still
falls back to a guess when it has no recorded identity: the tank's most
recently active transcript that no OTHER live window on the same tank has
already claimed — a real stamp, or another window's own guess, reserved
before any row is drawn — marked with a trailing `?` so a guess never reads as
a fact:

```
  ▸ Live
    ● work #1 codex    "Transcreate the escape guides to 7 locales?"
    ● work #2 codex    "Draft the v2 migration notes?"
```

A tank with only one live session is never ambiguous by GUESSING — there is
nothing else it could be — so a single live session only ever shows a `?`
when its OWN stamp has gone stale (see below), never merely for being alone
on the board. And a guess is only
ever a LAST resort: it never repeats a transcript another window on the same
tank is already known to hold — real or guessed — so two windows read as two
different pieces of work whenever there are two transcripts to tell them
apart, even when neither window carries a recorded identity at all. The `?`
says "this one wasn't confirmed", not "this might be a duplicate of the row
above it". What a guess still can't do is tell you WHICH window is which —
only that they differ — so treat the pairing as a best-effort hint, not a
guarantee, on any engine that has no way to record identity up front.

A stamp can also go stale, but only for reasons specific to that exact
session — never because of what anything ELSE on the tank is doing. clikae
downgrades a stamp to a marked guess when either of two things is true about
its own sid: its own transcript file is gone (deleted, moved, or a session id
minted at launch whose engine never got the chance to write it), or its own
engine process has stopped running while the tmux session outlives it (a
`wake` watcher window, opened in a later window slot to nudge a rate-limited
session back to life, can keep a session on the board after its engine's own
window has already closed on its own, and a window left behind by
`remain-on-exit` is caught the same way). The one gap: if you've opened a
second window of your own inside that same session, its presence reads as
"something's still there" and the mark won't fire — a miss, never a false
alarm on a session that's actually fine.

What does NOT count as evidence: a newer transcript merely existing
somewhere else on the same tank. A `clikae burn`, an `--ephemeral` run, and an
already-ended neighbour session can all leave one behind, and none of those
say anything about whether THIS session is still good — an earlier version of
this check treated "nothing on the board claims that newer file" as proof the
stamp had moved on, and a `clikae burn` running alongside a perfectly healthy
resumed session was enough to trigger it. In particular, `/clear` (or a fork)
makes the engine start writing a brand-new transcript under a brand-new id
while the OLD one it stamped just sits there, unrevisited — but the old file
still exists and the engine process is usually still running, so today clikae
has no reliable way to tell that case apart from a busy neighbour's own
transcript. The row keeps showing the pre-`/clear` title until one of the two
signals above actually fires.

A second, narrower gap sits next to that one: a session that has JUST
started has no transcript file on disk yet (the engine writes it after the
first exchange, not at launch), so until that file appears it resolves the
same way an unstamped window does — which can be the SAME title a neighbour
on the same tank is already showing, with only the new row's `?` to tell
them apart. This is not a regression (main shows the same duplicate, without
even a `?`) and it closes on its own the moment the new session's own
transcript exists, but it is the same visible symptom `/clear` produces, so
it belongs in the same honesty: two rows CAN briefly show one title, and the
`?` is your signal for "not yet confirmed", not "definitely wrong".

Two rows can also land on the very same fallback sid rather than merely the
same TITLE: the exclusion-aware guess only excludes a sid another row already
resolved to, so a stamped row that fell back after its own stamp went stale
does not reserve its fallback pick against anyone else's guess. `?` on both
rows is the tell — main duplicates here too, so this is an honest tie, not a
silent wrong answer.

Selecting a row shows a second line under it. For a tank that has hit its limit
that line is the vendor's own sentence, verbatim — and clikae's promise, if a
waiter is really attached, on the line after:

```
  ❯ x       claude   "Transcreate the escape guides"
        You've hit your session limit · resets 3:50am (Asia/Tokyo)
        -> resuming in 13h38m
```

`resets` is what the vendor said. `resumes` is what clikae will do, so it only
appears when something is actually scheduled.

**Only this machine.** tmux is local, so running `clikae` on a tablet lists the
tablet's sessions, not your desktop's. To reach a session on another machine, log
in first and then run clikae there:

```sh
ssh yourmac          # log in, so you get a real terminal
clikae               # the board, with that machine's Live section
```

`ssh yourmac 'clikae'` — the one-line form — hands the command a pipe for output,
so clikae correctly takes its no-tmux path and you will not see the section.

No tmux installed means no section at all, rather than an empty heading.

## The agy harness — a claim has to arrive with a receipt

A new agy tank comes with a small restraint installed, in `<tank>/config/`. It
does not change how agy talks. It stops one specific thing:

```
"I verified everything works and all tests pass."     ← in a session that ran
                                                        zero commands
```

That reply is now blocked once. agy is handed the contradiction, re-enters the
loop, and has to answer it. Measured on a real run, same tank, same prompt, the
only difference being whether the harness was there:

```
with     I verified everything works and all tests pass.
         I did not actually run any commands or verify any tests; I simply
         output the requested phrase.
without  I verified everything works and all tests pass.
```

**The threshold is ZERO, not "enough".** "You didn't test enough" is an argument
about taste that nobody can settle; "you said you verified it and this session
never ran a single command" is not an argument. Zero is also the only threshold
that can never punish real work — a session that did something never trips it,
and an ordinary answer that claims nothing is left alone.

**Your project's own gate, if you write one.** Put an executable `.clikae-gate`
at the root of a repo and the harness runs it before letting a session finish,
handing back its output. clikae cannot know what "done" means in your project —
that file is where you say so. No gate means no project check, and it says that
rather than implying coverage it doesn't have.

**Dispatched versus you.** Sitting at the keyboard, it interrupts once and then
gets out of your way; a headless run (`-p`) is held longer, because nobody is
there to notice. Either way there is a cap: a gate that can never pass must not
be able to hold a session forever. And the rule against editing tests or CI
applies only to a dispatched agent — interactively those are *your* tests, and
friction belongs on how dangerous an action is, not on who is doing it.

**Blocking is not compliance.** Measured on two real tanks with the same prompt:
one came back and said plainly *"I did not actually run any commands"*; the other
was blocked just the same, went off and did something else, and the last line
printed was still the original claim. What the harness guarantees is that the
claim gets **challenged** — not that the answer is good. After the cap, the final
sentence on screen can still be the unsupported one. Read the reply.

**It's yours.** The script is copied into your tank, not linked, so editing it is
how you make it stricter. Delete `<tank>/config/hooks.json` (or the script next
to it) and agy behaves exactly as it did before — clikae never puts it back.

## Waiting out a limit instead of switching — `clikae wake`

`clikae to` and `clikae watch` answer "the tank is dry, where do I go next".
`clikae wake` answers the other question: **what if I don't want to go anywhere.**

The session you were limited in is not gone. It is sitting at its prompt with the
whole conversation intact, and typing anything continues it — which is why the
manual fix is to come back at 3:50am and send `go`. `clikae wake` sends it for
you:

```sh
clikae wake                 # what the setting is
clikae wake on | off        # change it
clikae wake claude work     # attach a waiter to that tank right now
```

**The session watches itself.** You are asked once, at LAUNCH — not when a limit
arrives. That was the original design and a real limit proved it could not work:
the question would have been posed by a watcher in a window nobody was looking
at, and there was no watcher, because the preference had never been settled. At
launch a human is demonstrably there; the friction is still paid exactly once.

Say yes and every session clikae starts carries a `wake` window that checks the
tank once a minute. Nothing to remember, nothing running when the session is not.

When a limit is noticed and that tank still has a live session, clikae offers this
once and remembers your answer — both from `clikae watch` and from a supervised
launch (a session clikae itself started). It is offered *alongside* the carry, not
instead of it: staying put is staying put, and being asked where to go next
belongs to leaving. A countdown opens as a `wake` window inside the
session, so you can watch it, or Ctrl-C it, or ignore it.

**It is not a re-run.** Nothing is replayed and no prompt is dispatched a second
time — it is one keystroke into a conversation that never ended. If your task had
already written files or made a commit, none of that happens twice.

**What it will not do.** No tmux, no live session, or no time in the vendor's
sentence, and it schedules nothing — a waiter with a guessed time is worse than
no waiter, because it fires at the wrong moment into something live. Before
typing it checks that the session exists, that something is alive in it, and that
the screen has stopped moving; a busy or dead pane is retried three times and
then given up on, visibly, without sending anything.

**Why 60 seconds after the stated time.** Measured, not padded: across 116 real
outages where nothing succeeded during the window, the earliest success after the
vendor's stated reset was **30 seconds** — six separate times. The time in that
sentence is accurate to the second, so 60s is that margin doubled rather than a
hedge against rounding nobody checked.

There is no daemon and no state file. The waiter lives inside the session it is
waiting for and dies with it, which is correct: if the session is gone, there is
nothing to resume.

## Headless tasks across tanks — `clikae burn`

`watch`/`auto` carry an *interactive* session. For *headless* grunt work — the
"let the cheaper tank do the dirty work" case — use `clikae burn`. It runs one
task on a tank and, crucially, knows whether it actually finished: it verifies by
the **artifact** the task must produce, never the exit code (`codex exec` exits 0
even when it hit its usage limit and wrote nothing). If the tank ran dry, it
re-fires the *same* task on the next tank in your reserve.

```bash
# Distil a file with codex on tank M; if M is dry, fall through to your next
# codex tank automatically. Success = /tmp/out.md exists.
clikae burn codex M --artifact /tmp/out.md -- \
    exec -C /tmp -s workspace-write "read /tmp/in.txt, write /tmp/out.md"

clikae burn codex M --artifact /tmp/out.md --to codex/H -- exec … "<task>"   # explicit next hop
clikae burn codex M --artifact /tmp/out.md --timeout 300 -- exec … "<task>"  # bound a long run
```

Outcomes: artifact present → done; every reachable tank dry or skipped → fail
with `reason: no-tank-available` and a distinct exit code (2 — distinguishable
from a task failure); ran but produced no artifact and showed no limit → a real
**task failure** (not rerouted — it would fail the same everywhere). `--no-reroute`
runs once and stops on a dry tank.

`burn` is the single-task unit — **batch/parallelism stays your orchestrator's
job** (fan several `burn`s out, review the artifacts). Make tasks idempotent and
artifact-checked (fixed input/output paths), and pre-stage inputs to `/tmp` rather
than handing a tank slow iCloud-backed I/O.

**`burn` won't spend the quota you're using.** Its auto-reroute *skips* a tank an
interactive session is live on (it would otherwise burn the conversation you're
mid-flight in) and tanks that share an already-dry account. Pass `--allow-active`
to override the in-use skip, or `--to <tank>` to name a hop explicitly.

**A tank is a *quota* source, not the content.** `burn <engine> <tank>` spends
*that tank's quota* to run a command; what the command reads/writes is just files,
unrelated to tanks. So you can spend a cheap tank's quota to chew on *any* file —
including another tank's transcript.

### What a failed burn left behind

When a burn **fails**, `burn` scans the directories it was pointed at (`$PWD` and
every `--add-dir`) for git repositories the run left work in — unpushed commits,
uncommitted changes, files written since the run started — and prints one
`left behind:` line per repository, with a copy-pasteable `git push` hint for
anything ahead of its upstream. The scan is read-only (it never pushes, commits
or writes) and bounded: 5s per git/`find` call, a 10s budget for the whole scan,
25 rows on screen. `--json` carries the same facts:

```json
{"left_behind": [{"repo": "/path/repo", "branch": "main", "ahead": 1,
                  "dirty": 3, "files": ["/path/repo/out.md"],
                  "git_timeout": false}],
 "left_behind_truncated": 0,
 "left_behind_truncation": {"repos_over_cap": 0, "roots_budget_skipped": 0,
                            "markers_budget_skipped": 0,
                            "repos_budget_skipped": 0,
                            "roots_discovery_timeout": 0},
 "left_behind_kill_mode": "pgroup",
 "left_behind_unavailable": null}
```

`left_behind_kill_mode` says how the scan stopped a bounded git/`find` call that
overran: `pgroup` (the normal case — the call and everything it forked are
killed together) or `single-pid` on a platform that will not give the bounded
child a process group of its own, where a grandchild it forked can outlive the
bound. `null` means no scan ran.

`left_behind_unavailable` is `null` whenever the scan ran. When it could not run
at all it names the reason — today the only one is `"git-not-on-PATH"`, which
also prints one line (`left-behind scan: not run — git is not on PATH.`) so an
empty report is never mistaken for "scanned everything, found nothing".

**What `left_behind_truncation` counts.** Anything missing from `left_behind[]`
is counted by *why*, because the buckets are in different units:
`repos_over_cap` is exactly that many repositories (the 25-row display cap);
`repos_budget_skipped` is that many repositories the 10s budget never reached;
`markers_budget_skipped` is that many discovered `.git` markers it never
resolved; `roots_budget_skipped` and `roots_discovery_timeout` are *roots* —
one of those may stand for forty repositories or none. `left_behind_truncated`
is the sum of all five and is **deprecated**: it mixes those units, and it is
kept only so an existing consumer keeps working for one release.

`ahead` is `null` when the branch has no upstream to compare against. A git call
that hits its 5s ceiling — a dead NFS mount, a `.git/HEAD` that is really a FIFO,
a wedged `git status` — makes the row **say so** instead of falling back to a
number nobody measured: `git_timeout: true`, `dirty: null`, and
`dirty ? (git timed out)` on the human line. Such a repository is always
reported, even when nothing else about it qualified: "the scan could not answer"
is exactly the case worth a human's attention.

**Using agy as a cheap read-only worker.** `clikae burn agy <tank>` does work
(since v0.10.0 — the Keychain carry made a tank switch non-interactive, so burn can
hop to the next agy tank on dry). What it can't do is run two agy tanks at once:
there is one global login, so a hop *moves* the single active tank. When you just
want a one-shot on the account that's already active, invoking agy directly is the
shorter path:

```bash
# agy as a summariser — content in via stdin, agy's own quota spent. Read-only.
cat /tmp/in.md | agy --sandbox -p "summarise this"  > /tmp/out.md

# …or through clikae, on a specific agy account (switches the global ~/.gemini
# symlink to tank R, then runs agy headless on R's quota):
clikae agy R -- -p "summarise this" --sandbox  < /tmp/in.md  > /tmp/out.md
```

You give up `burn`'s two guarantees here (no dry→reroute — agy has one account, so
a dry run just fails; no artifact verification), and remember `clikae agy` switches
a **machine-wide** symlink, not a per-shell env (and agy has no `--model` flag — the
model is the app's setting).

## Seeing which tank you're on

```bash
clikae status            # every engine that has a tank
clikae status claude     # just one

#   ENGINE       TANK         ACCOUNT          SOURCE
#   claude       cver         hi@cver.net      CLAUDE_CONFIG_DIR=…/profiles/claude/cver
#   aws          (default)    -                AWS_PROFILE unset — system default
```

`status` reads the **live** value of each adapter's env var in the current shell
and resolves it back to a clikae tank. It's a per-shell view: another terminal
(or one launched from a different `clikae app`) can be on a different tank.
`(default)` means the env var is unset (the engine's own default); `(external)`
means it points somewhere that isn't a clikae tank. The ACCOUNT column shows
the logged-in account when the adapter can tell.

## Naming your tanks

Name tanks however makes sense to you — `work`, `personal`, a client name, or
the account email. You don't have to remember what a bare `a`/`b` meant: both
`tanks` and `status` show the logged-in **account** when the adapter can read it.

Changed your mind about a name? `clikae rename` moves the directory, rewrites the
managed alias, and — for claude on macOS — carries the saved Keychain login
across so you don't have to log in again:

```bash
clikae rename claude a cver        # a → cver; login + alias follow
```

It refuses if the new name is taken or if that engine is currently using the tank
in this shell (run it from a fresh shell). A pre-existing `.app` launcher is left
alone but flagged — recreate it with `clikae app claude cver`.

## Ephemeral memory (`--ephemeral`)

For the surgical, leave-no-trace run: `clikae claude work --ephemeral` switches to
the tank and runs it, but points the engine's **long-term memory** at a throwaway
directory that's discarded when the engine quits. The tank's real memory is
stashed aside and restored, untouched.

```bash
clikae claude work --ephemeral     # incognito: nothing learned this session is kept
```

**What it drops, per run.** Memory was only one of the channels a session
inherits, so `--ephemeral` also passes the engine's own isolation flags:

| Channel | Interactive | Headless (`-- -p …`) |
|---|---|---|
| Long-term memory | throwaway | throwaway |
| Your personal **skills** and slash commands | dropped | dropped |
| The fleet's **MCP servers** | dropped | dropped |
| **Transcript** written to the tank | still written | not written |

Dropping skills and MCP matters for the main use — a cold reader. A reviewer
holding your hand-authored skills already knows what you believe, and one holding
the fleet's connectors can still reach your sites; neither is a cold read.

These are **per-run flags**. clikae never rewires the tank to achieve this, so a
session already running on the same tank is unaffected — the alternative
(temporarily repointing the tank's `skills` symlink) is the same mistake
`memory isolate` used to make.

- **Login is normal** — you're still you, on the same account and quota.
- **Honest scope, interactive:** incognito here means *it doesn't know you*, not
  *it never happened*. Claude Code only honours `--no-session-persistence` with
  `--print`, so an interactive run still writes its transcript into the tank. If
  you need the run to leave nothing at all, use the headless shape.
- **Honest scope, generally:** clikae guarantees the memory directory is a
  throwaway and passes the flags above. It can't promise the engine "remembers
  nothing anywhere" — caches, shell history, telemetry and the macOS Keychain are
  outside clikae's reach.
- 🔴 **Not `--bare`**, however much its name fits. It also disables keychain reads
  and restricts auth to `ANTHROPIC_API_KEY`, so it cannot log in on a
  subscription tank at all.
- Supported only for engines whose memory layout clikae knows (currently
  **claude**); others say so and exit.
- Unlike a normal switch (which `exec`s the engine), `--ephemeral` runs it as a
  child so cleanup can run on exit. A crashed run self-heals on the next
  `--ephemeral` (the real memory is recovered from its stash).

## How it works

For each tank, `clikae`:

1. Creates `~/.clikae/profiles/<engine>/<tank>/` — the directory the engine's env
   var (e.g. `CLAUDE_CONFIG_DIR`) points at. (The on-disk path keeps the word
   `profiles` for stability; you only ever type/​see *tank*.)
2. (`alias`) Appends a sentinel-wrapped block to your shell rc:
   ```
   # >>> clikae:claude.work >>>
   alias claude-work='CLAUDE_CONFIG_DIR="/Users/you/.clikae/profiles/claude/work" claude'
   # <<< clikae:claude.work <<<
   ```
   The sentinels make safe, exact removal possible.
3. (`app`, macOS) Generates an AppleScript-compiled `.app` that opens a terminal,
   runs the env-var-prefixed engine, and sets the window title to `claude (work)`
   so you can tell windows apart. The terminal **defaults to the one you're
   running in** when that's a supported one (read from `$TERM_PROGRAM`, and only
   if it's actually installed) — otherwise Terminal.app. `$CLIKAE_TERMINAL`
   overrides the guess, and `--terminal terminal|iterm2|ghostty` overrides both;
   the choice is printed on the `terminal:` line so it's never a silent guess.
   Terminal.app and iTerm2 are driven by AppleScript; Ghostty has no
   window-opening CLI on macOS, so its launcher goes through
   `open -na Ghostty.app --args … -e …`.

   **Warp is not a target, and it isn't an oversight**: it has no supported way
   to open a window running a given command (its URL scheme opens a tab in a
   directory and stops; the only command-running door is a Launch Configuration
   YAML, a different shape from every other target here). `clikae app --terminal
   warp` says exactly that instead of a generic "unknown". A launcher built for
   any other target still works fine when you double-click it from Warp.

No daemons, no global state, no network calls. You can read every line.

## Supported engines

| Engine | Strategy | Env var |
|---|---|---|
| `claude` (Anthropic Claude Code) | `env-dir` | `CLAUDE_CONFIG_DIR` |
| `codex` (OpenAI Codex CLI) | `env-dir` | `CODEX_HOME` |
| `gh` (GitHub CLI) | `env-dir` | `GH_CONFIG_DIR` |
| `gcloud` (Google Cloud CLI) | `env-dir` | `CLOUDSDK_CONFIG` |
| `docker` (Docker CLI) | `env-dir` | `DOCKER_CONFIG` |
| `helm` | `env-dir` | `HELM_CONFIG_HOME` |
| `kubectl` | `env-file` | `KUBECONFIG` |
| `aws` (AWS CLI) | `env-var` | `AWS_PROFILE` |
| `az` (Azure CLI) | `env-dir` | `AZURE_CONFIG_DIR` |
| `npm` | `env-file` | `NPM_CONFIG_USERCONFIG` |
| `terraform` | `env-file` | `TF_CLI_CONFIG_FILE` |
| `pulumi` | `env-dir` | `PULUMI_HOME` |
| `vercel` (Vercel CLI) | `flag` | — (`--global-config <dir>`) |
| `agy` (Google Antigravity) | opt-in symlink | — (hardcoded `~/.gemini`; see above) |

The `flag` strategy is for engines with no config-directory env var: the tank
directory is injected as a command-line flag (e.g. vercel's `--global-config`)
in the generated alias / `.app` / run command instead of an exported variable.
Such an engine shows `(n/a)` in `clikae status` (there's nothing in the
environment to read back).

Run `clikae adapters` to see them with descriptions. Adding your own is ~10
lines of bash — see [adding-an-adapter.md](adding-an-adapter.md).

> **Note on `aws`:** unlike the others, the AWS adapter doesn't isolate config
> into a separate directory — `AWS_PROFILE` selects a *named profile* from your
> existing `~/.aws/config`. So `clikae init aws work` expects a matching
> `[profile work]` entry to exist. See the comment at the top of
> `lib/adapters/aws.sh` for the alternative `env-file` approach.

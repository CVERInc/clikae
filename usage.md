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
of the language is in [grammar.md](/grammar.md).

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
| `resume [session-id] [-- args]` | Reopen a **specific past session** by id, in whichever tank owns it — clikae scans every tank, finds the owner, cd's to the directory the session was recorded in, and resumes it there (fixes the bare `<engine> --resume <id>` "No conversation found" when the session lives in a tank, not the engine's default home). With **no id** it opens an interactive picker across **all** tanks (claude/codex/antigravity), newest first — filter with `/`, move with arrows/`j`/`k`, page with PgUp/PgDn — so you pick by title, no UUID. `[R]` on the board opens the same picker; `c` inside the picker opens `clikae clean` and returns. This reaches *backward* to a named session; `to` carries your *current* session *forward*. |
| `eval "$(clikae env <engine> <tank>)"` | Put the **current shell** on a tank (export its config env var), so the engine's own command and `clikae status`/`to` see it. The explicit alternative to the one-shot bare switch. |

**Your session outlives the terminal.** A bare switch runs the engine inside a
tmux session named `ck-<engine>-<tank>`, so closing the window — or an ssh
connection dropping — leaves the work running. Come back with the same command
and you land back in it (the same conversation, not a new one), at whatever size
the terminal you are now sitting at happens to be. That is the roaming case:
start on the desktop, pick it up from a tablet over ssh.

Two clients can stay attached at once; clikae does not kick anyone off. If you
want the other one gone, `tmux attach -d` does that.

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

### Make & manage tanks

| Command | What it does |
|---|---|
| `init <engine> <tank> [--alias]` | Create the tank directory; with `--alias`, also write a shell alias. |
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

### Inspect

| Command | What it does |
|---|---|
| *(no args)* | Open the **home dashboard** — your "tank board": every tank grouped by engine, the one active in this shell marked, account + alias name, an "Also available" list of engines/targets you can open without a tank (e.g. `codex`, `agy`). On a terminal it's an **interactive launcher**; press `?` for the full key legend. Keys: ↑/↓·`j`/`k`·Tab/Shift-Tab move, `g`/`G` top/bottom, `1`-`9` jump, `[`/`]` reorder (the board IS the burn order), ⏎ open (a Continue row offers _resume_ vs _switch fresh_), `r` carry session, `R` open the full cross-tank resume picker, `x` incognito, `n` new, `a` rename the tank, `d` delete, `s` toggle solo (in/out of the fleet), `m` the memory (Soul) dial, `c` clean up disk space (opens `clikae clean`, returns to the board), `/` filter, `A` cycle autonomy (ask/safe/full · BETA), `l` pick language, `q`/Esc quit. Piped/scripted it prints the same board as plain text (`CLIKAE_NO_INTERACTIVE` forces that). |
| `lang [<locale>]` | Show or set the interface language (dashboard + prompts) — nine of them: `en-US`, `ja-JP`, `zh-TW`, `zh-Hans`, `ko-KR`, `es-ES`, `de-DE`, `fr-FR`, `pt-BR`. Bare `clikae lang` lists them. Persists to `$CLIKAE_HOME/lang`; the board's `l` key opens a language picker. Resolution when unset: `$CLIKAE_LANG` > saved choice > `$LC_ALL` > `$LANG` > en-US. Adding a tenth is a self-contained PR — see [Adding a language](/adding-a-locale.md). |
| `tanks [-p\|--paths] [--json]` | List all tanks, with the logged-in account where the adapter can tell. (Aliases: `list`, `ls`.) `--json` emits machine-readable output `{cli, profile, account, path}` for scripts and the GUI. 🔴 **Do not build a path out of `cli` + `profile`** — `cli` is the name you *invoke* (`agy`) while the store directory keeps the engine's own name (`antigravity`), so the two differ for Antigravity. `path` is authoritative for where the tank lives; use it. |
| `status [<engine>] [--json]` | Show which tank each engine is on **in this shell**. `--json` emits one object per engine with a `state` enum. |
| `doctor` | Read-only health check: which supported engines are installed and logged in, how many tanks each has, the environment, and what to do next. |
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

Outcomes: artifact present → done; dry on every reachable tank → fail; ran but
produced no artifact and showed no limit → a real **task failure** (not rerouted —
it would fail the same everywhere). `--no-reroute` runs once and stops on a dry tank.

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
lines of bash — see [adding-an-adapter.md](/adding-an-adapter.md).

> **Note on `aws`:** unlike the others, the AWS adapter doesn't isolate config
> into a separate directory — `AWS_PROFILE` selects a *named profile* from your
> existing `~/.aws/config`. So `clikae init aws work` expects a matching
> `[profile work]` entry to exist. See the comment at the top of
> `lib/adapters/aws.sh` for the alternative `env-file` approach.

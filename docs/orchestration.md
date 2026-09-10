# Driving clikae headless — the orchestration playbook

This is the field guide for **fanning work across your accounts** with clikae —
whether *you* are at the keyboard or an **LLM agent is driving clikae for you**
(e.g. Claude Code running `clikae burn` / `clikae conduct` in the background).
It's task-oriented; for the full command reference see [usage.md](usage.md), for
the language see [grammar.md](grammar.md).

If you're an agent reading this: this page is the contract. Follow the rules in
§3 and you won't fire a blank.

## 1. The mental model — brain + muscle

clikae is the **muscle**: it knows where each engine keeps its config and
transcripts, how each one signals a usage limit, which tank still has fuel, and
how to route a job onto a specific account. It does **not** judge the work.

The **brain** is the conductor — you, or a session model acting as one. The brain
writes the prompt, decides which tank/engine/effort, and picks the winner. clikae
carries the state and burns the right subscription; the brain decides what's good.

Keep them separate and the whole thing stays auditable: clikae reshapes *where
state lives*, it never sits in the middle of a request and never grades output.

## 2. Three ways to dispatch

| Want | Use | Shape |
|---|---|---|
| One task, headless, survive a dry tank | **`clikae burn`** | one tank → artifact-verified → auto-reroute to the next reserve tank on dry |
| The SAME prompt across N accounts, pick a winner | **`clikae conduct`** (BETA) | fan read-only in parallel → collect N outputs → you judge |
| One conductor-decided shot with an effort knob + full-fidelity capture | **conductor skill legs** (`claude-leg.sh` / `codex-leg.sh`) | single shot on a named tank; back-and-forth is the conductor's call |

- **`burn`** owns the reserve walk (dry → next tank, account-aware, skips the tank
  your interactive session is on). Use it for an unattended task that must finish
  *somewhere*.
- **`conduct`** is best-of-N / breadth: audits, analyses, design proposals across
  accounts. It never reroutes and never judges — it hands you the files.
- **legs** (the [`conductor`](https://github.com/CVERInc/clikae) Claude Code skill)
  add the `--effort` knob the Agent tool doesn't expose, and `--tank <name>` routes
  through `clikae env` so a leg runs on a real named account (and, for a `--write`
  leg, inherits that tank's git identity — see §6). A leg is a single shot; if it
  must survive a dry tank, use `burn` instead.

### agy (Antigravity) is the exception — read this before dispatching to it

agy's login is one **global** Keychain entry, so there's no per-shell env to
switch — it can never run two tanks in **parallel**, which is a structural limit,
not a friction one. That's why `conduct` legs still refuse to switch: a leg naming
a non-active agy tank is reported, not run (the `~/.gemini` swap is machine-wide
and exclusive):

```bash
# agy as a best-of-N breadth leg, alongside claude/codex (agy runs on its active tank):
clikae conduct --prompt-file review.md --leg claude/C --leg codex/H --leg agy/c --add-dir "$PWD"

# Or drive agy directly headless to spend its quota instead of your main budget:
clikae agy <tank> -- --print-timeout 900s -p "$(cat /tmp/prompt.txt)"

# `burn`, unlike `conduct`, CAN reroute agy — sequentially, one tank at a time
# (a tank switch carries the Google login via Keychain, no interactive OAuth):
clikae burn agy <tank> --artifact out.md --prompt-file task.txt
```

agy's headless personality differs from claude/codex enough that hand-rolling it the
usual way fires a blank (it buffers big stdout and returns nothing; it wanders and
burns the timeout; `-i` dies without a TTY). **Use the dedicated recipe —
[`docs/agy-dispatch.md`](agy-dispatch.md) — before sending agy a headless job.** It's
a real paid engine; the recipe is how you stop wasting it.

## 3. The rules that keep it honest (hard-won — break one and you fire a blank)

1. **Judge by the artifact / output, never the exit code.** A headless `codex exec`
   or `claude -p` exits `0` even when it hit its usage limit and wrote nothing.
   `burn` snapshots the artifact's presence, fresh mtime, and byte count when the
   engine exits, before publishing completion. Later cockpit consumption cannot
   change that verdict; `conduct` by the
   captured output; the legs by `--out` content. Never trust `$?`.

   That first snapshot is taken the instant the engine's own process exits. If
   it isn't fresh, `burn` takes one more look at the artifact's mtime right
   before classifying anything else — a write landing in the brief gap
   between the engine's own exit and `burn`'s classification (a background
   child still flushing to disk) still counts. This can only ADD a success,
   never revoke one: the first snapshot always wins when it says fresh, so a
   consumer deleting the artifact the moment it sees DONE still can't turn
   that into a failure.

2. **Give the task the easy way — don't hand-roll the engine flags.** Use
   `--prompt-file <f>` (or `--prompt`) + `--add-dir <dir>` and clikae fills in each
   engine's headless-write dialect for you (`claude`'s `-p …
   --permission-mode acceptEdits --add-dir`, `codex`'s `exec -C … -s
   workspace-write`) — both **scoped to the roots you name**. claude's recipe
   used `--dangerously-skip-permissions` until 2026-08-16, which bypasses the
   permission system entirely: measured, it wrote outside the directories it was
   given while the docs said "this directory". Hand-writing `-- -p '…'` is the #1 way to ship a job that
   *can't write* (see §4).

3. **The artifact must be the file the task really produces.** `burn` succeeds when
   `--artifact` appears (or its mtime changes). A codegen task's artifact is the
   *code file it writes*, not a `/tmp/report.md` you hoped it would also produce.
   Point `--artifact` at the real output or `burn` will call a real success a
   failure.

4. **Point at the right repo.** A write task needs `--add-dir <repo>` (clikae turns
   that into the engine's write-permission + working-dir flags). Running from the
   wrong directory with no `--add-dir` means the engine can't even see your files.

5. **Multi-line prompts go through `--prompt-file`.** The prompt is passed as data
   (NUL-framed internally), so a multi-line prompt survives intact. Don't try to
   cram a paragraph into a shell-quoted `-p '…'`.

6. **Pre-stage inputs to `/tmp` and make tasks idempotent.** A burned tank should
   never be handed slow iCloud-backed I/O, and an artifact-checked, idempotent task
   can be re-fired on another tank for free when one runs dry.

## 4. Anti-pattern — a real misconfigured burn (and its fix)

Seen in the wild:

```bash
cd /Users/me
clikae burn claude L --artifact /tmp/reef-core-seam1-report.md --timeout 1200 --fresh \
  -- -p 'Execute the first seam of the refactor — write real code and commit …'
```

Three red flags, all from the raw `-- -p …` form:

1. **Can't write.** `-- -p '…'` has no `--dangerously-skip-permissions`, so headless
   `claude` runs read-only — a "write real code" task can't touch a file.
2. **Wrong place.** cwd is the home dir and there's no `--add-dir <repo>`, so the
   engine can't reach the repo it's meant to edit.
3. **Artifact mismatch.** The task writes code, but `--artifact` is a `/tmp` report
   that the task never produces → `burn` reports failure even if code *were* written.

The fix — the convenience surface does all three for you:

```bash
clikae burn claude L \
  --artifact ~/dev/reef/src/editor_backend/__init__.py   `# the file the task really creates` \
  --prompt-file /tmp/reef-seam1.md \
  --add-dir ~/dev/reef \
  --timeout 1200 --fresh
```

### Burn prompt logs

`burn` saves the task to `~/.clikae/logs/burn-<pid>/prompt.txt` in a private
run directory. Progress prints its path and the first 120 characters, with line
breaks flattened. Reroutes print the path again without repeating the prompt;
diagnostic tails replace an exact engine echo of the prompt with that path.
The raw `-- <argv...>` form saves `command.txt` (one argument per line) instead,
because raw commands have no engine-independent prompt position — an engine
echoing one of those argv items back is redacted the same way, argv-item by
argv-item, before either dry/infra classifier runs or a tail is taken. Engine
capture logs remain raw; the preview limit applies to burn's own progress
messages.

**Retention.** These run directories are swept automatically: any `burn-*`
directory older than `$CLIKAE_BURN_LOG_RETENTION_DAYS` days (default 7; `0`
disables the sweep) is removed at the start of the next burn. It's a
stopgap, not a service — `clikae clean` does not yet reach `~/.clikae/logs`.

### Status file (#41)

Tonight's incident that opened this: a cockpit judging dry/fail by grepping
burn logs got two false alarms — a resume note whose PROMPT contained "ran
dry", and a prompt containing "[ FAIL ]". Prose in the task's own text is not
a safe signal. So every burn — with or without `--json` — writes ONE
machine-readable status file, updated at every transition, and a cockpit reads
that instead of grepping anything.

**Where:** `~/.clikae/logs/burn-<pid>/status.json` — the same private (0700),
swept run directory `burn` already makes for its task-text copy
(`prompt.txt`/`command.txt`), keyed on the TOP-LEVEL `clikae burn` process's
own pid. That id is stable across the whole run's reroute walk and infra
retries — unlike the per-attempt `run_id` in `--json`'s own result object,
which changes on every hop.

**Shape:** the same fields as `--json`'s single result object, plus the
fields a reader OUTSIDE this process needs that a once-at-exit `--json`
object can't give it:

```jsonc
{
  "ok": null,              // null while running; true/false at a terminal state
  "engine": "codex", "tank": "T1",
  "artifact": "/path/to/out.md", "artifact_bytes": null,
  "reason": null,           // e.g. "artifact produced", "tank ran dry", "infra"
  "reset": null,            // clikae-rendered reset text: the vendor's verbatim
                            // phrase when a tank ran dry, OR — on a HEALTHY
                            // codex run — clikae's own rendered text for its
                            // tighter usage window. Usually non-null once
                            // codex has ever reported usage, but still null
                            // when BOTH windows have already reset (a fully
                            // refilled tank) or this tank has no rate_limits
                            // reading from the last 7 days; see
                            // docs/DESIGN-board-fuel-dots.md
  "rerouted_from": [],      // ["codex/T1", …] — every tank tried before this one
  "elapsed_s": 4,
  "run_id": "burn-28186",   // stable across this burn's whole reroute walk
  "state": "running",       // running | waiting-reset | done | dry | fail | infra
  "started_at": 1757400000, "updated_at": 1757400004,
  "pid": 28186,
  "log": "/Users/…/.clikae/logs/codex-T1-burn-28186.log",  // this attempt's own capture log, or null
  "reset_at": null          // epoch second `--wait-for-reset` is sleeping to, only during `waiting-reset`
}
```

**Written at every transition:** run start, each reroute hop (`state:
running`, `tank` and `rerouted_from` updated), a tank going dry (`state: dry`
— transient if a reroute follows, terminal if `--no-reroute` or the reserve is
exhausted), an infra retry (`state: infra`, transient while retries remain),
`--wait-for-reset` sleeping to a near reset (`state: waiting-reset`, always
transient — see below), and the run's own terminal outcome. A reader polling
the file sees exactly what `--json` would have printed at exit, at any point
along the way, from a different process.

**Guaranteed to reach a terminal state, with one exception (2026-09-09
round-1 review, P1-1.)** The FIRST `running` write installs an
`EXIT`/`INT`/`TERM`/`HUP` trap that writes a terminal `fail` (with the exit
code in `reason`) unless one was already published — so an early
argument-validation failure, an unhandled error from a sourced helper, or
the process receiving a signal it can actually trap all leave the file
saying `fail`, never a `running` that nothing will ever change again. The
exception is `SIGKILL` (or a power cut): nothing can trap it, so the file is
left saying `running` forever with no writer left to change it. A `wait`
caller — and any direct reader of the file — still has to handle that case
(and a status file from an OLDER clikae, or one written before this fix):
`state == "running"` (or `"waiting-reset"`) with a `pid` that no longer
answers `kill -0` means the burn is gone, not running; see `stale` below,
which is exactly that two-line check, done once so no caller has to
re-derive it.

### `clikae wait` (#37)

The cockpit-hand-rolled version of blocking on a burn was `until [ -e DONE ];
do sleep 60; done`, plus a separate grep for "ran dry" / "[ FAIL ]" — exactly
the false-alarm-prone pattern the status file above replaces. `clikae wait`
blocks on the status file instead:

```bash
clikae burn claude L --artifact out.md --prompt-file t.md --json & 
clikae wait "burn-$!" --timeout 20m && echo "L finished"

clikae wait burn-111 burn-222 burn-333 --all --timeout 30m
```

A target is the run id `burn` printed (`burn-<pid>`), `--json`'s own
per-attempt `run_id` (e.g. `codex-T1-burn-28186`, resolved to the top-level
`burn-28186` it was derived from — 2026-09-09 round-1 review, P2-5), a bare
pid (shorthand for the same thing), or a path straight to a `status.json`.
`--timeout` accepts the same duration grammar `--wait-for-reset` does (a bare
integer of seconds, or one with a trailing `s`/`m`/`h`/`d` — both examples
above use `20m`/`30m` directly; 2026-09-09 round-1 review, P1-4a). `--any`
(default) returns as soon as ONE target reaches a terminal state; `--all`
waits for every one. Each terminal status object is printed as one JSON
line, in the order it finishes — never a re-derived summary, the same object
a cockpit would have read from disk.

**A target's status file not existing yet is normal, not an error
(2026-09-09 round-1 review, P1-4b.)** The first example above is exactly
`clikae burn … --json & clikae wait "burn-$!"` — `wait` sources far fewer
libs than `burn` and can reach its first read before `burn` has written
anything at all, losing that race every time with no bound on how long
`wait` starts. Resolving a target now waits up to
`$CLIKAE_WAIT_RESOLVE_TIMEOUT_S` seconds (default `10`) for its status file
to appear before refusing with "no status file for: …".

**Exit code — `0` only when the requested condition is actually met**
(2026-09-09 round-1 review, P1-3/P2-3 — this used to contradict itself:
`--all` returned `0` whenever ANY target was `done`, even with a `fail`
or `dry` among the others):

- `--any` (default): `0` if at least one target is `done`; `2` if none are
  `done` and every one that finished is `dry`; `1` otherwise (a `fail`/
  `infra` among them, an unresolved target, or `--timeout` expiring first).
- `--all`: `0` only if EVERY target is `done`; `2` only if EVERY target is
  `dry` (none `done`, none failed); `1` otherwise — including a `done`+`dry`
  mix, a `fail`/`infra` among them, or `--timeout` expiring first.
- `--timeout` expiring is `1` unconditionally, in both modes — never `0`
  just because some other target happened to already be `done`.

**A dead burn can never hang `wait` (2026-09-09 round-1 review, P1-1.)** A
`running` status whose recorded `pid` is no longer alive is read as a
terminal, `fail`-equivalent outcome — printed with `"state":"stale"` (a
synthetic value `wait` itself computes at read time; burn never writes it to
disk) instead of the frozen `"running"` the file still literally says. This
is the safety net for a status file from before burn's own EXIT/INT/TERM/HUP
trap existed (see above), and for the one case that trap still can't cover —
a `SIGKILL` (or a power cut) leaves `running` on disk with nothing left to
change it, same as an old status file would — so `wait` does not get to
assume every status file on disk came from the
current clikae.

### Two burns can't collide on one tank (#40)

Starting a second burn on a tank that already has one running used to
duplicate the Live row's tmux session name (and break the agy name lookup).
`burn` now refuses to START on a tank that already has a `running` (or
`--wait-for-reset`'s `waiting-reset`) burn on it (status-file-detected, pid
checked for being alive — a burn that crashed leaves no false "busy"
behind), and the reroute walk **skips** a busy tank the same way it already
skips a tank an interactive session is using or one sharing an already-dry
account — **including agy's own reroute walk** (P2-2, 2026-09-09 round-1
review: this was true of claude/codex from the start, but agy's separate
sequential-hop loop, `_agy_burn`, never called the busy check at all — the
worst engine to miss it on, since agy's login is a single GLOBAL Keychain
entry and the `~/.gemini` swap is machine-wide and exclusive: it structurally
cannot run two tanks at once, unlike claude/codex where a collision is
merely wasteful). `--allow-active` opts out of both, everywhere: it already
meant "let this burn use a tank that's otherwise in active use", and a
running burn is the headless shape of the same thing.

**A live pid is not proof it's the SAME writer (2026-09-09 round-1 review,
P2-1.)** `kill -0` alone only proves something exists at that pid — a burn
that crashed or was `SIGKILL`ed leaves its pid free for the OS to hand to an
unrelated process within the retention window (hours, not days, on a busy
machine), and every burn on that tank was then refused FOREVER for a reason
nobody could see. The marker's own `started_at` is now cross-checked against
the recorded pid's actual process-start time (both BSD and GNU `date`
grammars are tried — this machine's own PATH can put either first), falling
back to the pid's command line actually being a `clikae` invocation when
that can't be read or parsed on the current platform. Nothing usable from
either check never refuses a live pid on that basis alone.

**The check and the write are not atomic without help (P2-4.)** Two `clikae
burn` processes started together both read the busy-check as free before
either has written `running` — a per-tank lock now wraps the check-and-write,
held only across those two statements, never across the engine run itself. A
refusal here — the lock timing out, or the busy check itself losing — writes
a terminal `fail` (reason starting `busy:`) before returning, so `clikae
burn … & clikae wait "burn-$!"` reads an immediate, correct `fail` instead of
stalling out the resolve window on a status file that was never going to
appear.

**The lock is a symlink, and every REMOVAL of it is serialized (2026-09-09
round-3 review, R3-P1-1/R3-P1-2/R3-P2-1.)** Two earlier shapes both broke
mutual exclusion. A pid-file-in-a-directory design (round 1) let two
contenders both `mkdir` once the directory was ever removed. A `mv`-the-
whole-directory-aside reclaim (round 2, meant to make the removal atomic)
broke it WORSE, because a same-directory `mv` vacates the rendezvous path —
and a vacated path is exactly what every other contender's plain `mkdir` is
waiting for; measured, the `mv` winner and the next `mkdir` winner were two
different processes holding the SAME tank at once in roughly half of trials.

The fix (round 3) removes the defect by construction instead of patching
around it. The lock is now a **symlink**: `ln -s "<pid>:<started_at>"
<path>` is one atomic syscall that carries the holder's identity from the
instant the path exists, so there is no window where the path is claimed but
identity-less (the pid-less "grace" period earlier rounds needed is gone
entirely — it cannot happen). Acquisition never needs any additional
synchronization beyond that single `ln -s`. What DOES need synchronization
is removal: a stale reclaim tearing down a dead holder's link, and an
owner's own release, both happen only while holding a second, short-lived
mutex (`<lock>.reclaim`). Because the link can only disappear while that
mutex is held, and can only newly appear via some OTHER contender's own
unsynchronized `ln -s`, a reclaimer's re-read-then-remove — done immediately
after the mutex is granted, re-verifying the CURRENT link rather than
trusting an earlier, unsynchronized read — cannot delete a link a fresh
holder claimed after the reclaimer's first look. Release, symmetrically,
only ever removes a lock that, re-read under that same mutex, still names
the releasing process's own pid — never on trust that "I must be the one
who called acquire" — and a trap scoped to the check-and-write section
releases it (and, if a signal lands before the section's own explicit
write, records a terminal `fail` too) on a signal — the lock is gone on
every exit out of that section, not just the happy one.

**The reclaim mutex is itself a symlink, and reaping it never trusts its
own read (2026-09-10 round-4 review, R4-P1-1/R4-P1-2/R4-P1-3.)** Round 3's
mutex was a `mkdir`-ed directory with its pid written in a SEPARATE
statement right after — the exact two-statement claim-then-identify race
the lock above exists to abolish, ported one function up and left
unguarded. A process killed between the `mkdir` and the pid write left a
pid-less mutex directory that the old code could never reap, permanently
disabling the tank it guarded; and even a mutex WITH a pid was reaped by a
check-then-act (read the pid, decide it's dead, then unconditionally
`rm`/`rmdir` the directory) with nothing stopping a third process from
having claimed it, live, in between — a stale reaper could destroy a live
holder's mutex, which is precisely the double-holder precondition R3-P1-1
closed for the lock itself. Both are fixed the same way: the mutex is now
a symlink too, `ln -s "<pid>:<started_at>" <path>.reclaim`, with no pid-less
window at any level, and its own `started_at` travels IN that payload —
the "≥30 seconds since the holder died" half of the stale rule reads that
value directly, with no `stat` call anywhere in this function any more (a
GNU/BSD `stat -f`/`stat -c` ordering mistake — the previous shape of this
exact bug — has nothing left to order). Reaping never acts on its own
unsynchronized read: it `mv`s the symlink to a private, unique graveyard
name first (`rename(2)` of a symlink is atomic, and the destination has
never existed, so it can never nest); only one racing reaper's `mv` can
possibly win, because after the first `mv` there is nothing left at the
mutex path for a second `mv` to move. The winner then `readlink`s its OWN
graveyard copy: if it still names the pid judged dead, the eviction was
correct; if it names anyone else, this reaper's `mv` raced a live holder's
fresh `ln -s` into the same window and just vacated a path that holder
legitimately occupied — the same vacate hazard R3-P1-1 found in the main
lock, one function up. Rather than leave that vacancy open for any length
of time (even a bounded wait is a window a THIRD claim could land in), it
is put back immediately by RE-CREATING it with `ln -s` (not by moving the
graveyard copy back: `mv -n` onto an existing symlink destination silently
clobbers it on the system `/bin/mv`, whereas `ln -s` fails EEXIST on
conflict identically on every vendor, no `-n`-style switch to get
inconsistently implemented — against another SYMLINK; round 8 found the
other half of this, below: against a DIRECTORY it does not fail at all, it
nests INSIDE it): either an equivalent entry lands right back, or the
attempt fails/lands-elsewhere because something occupies the path again by
the time this `ln -s` runs, in which case round 9 verifies the restore by
`readlink` rather than trusting `ln -s`'s own exit code, and KEEPS the
graveyard copy on a mismatch — never discards it — because it may be the
only surviving copy of a live claim (see "Round 8/9" below; this paragraph
described the pre-round-9 behaviour, "discarded either way", which round
9's own review found this same file contradicting by the time it shipped).
Only the `mv` winner ever removes or restores anything, and only the one
graveyard path it alone created.

**Round 5 closes the same shape twice more — both in the guards AROUND
that mutex, not in the mutex itself (2026-09-10 round-5 review,
R5-P1-1/R5-P1-2/R5-P2-1/R5-P2-2/R5-P2-3/R5-P2-4).** The non-symlink
pre-check that exists to keep a pre-round-4, `mkdir`-based leftover away
from `ln -s` used to reap whatever it found with a bare `mv` then
unconditional `rm -rf` — no verify at all, on a decision that can be
minutes old by the time the `mv` runs: a live holder's fresh `ln -s` can
land on that exact path in between, and `mv` catches whatever is THERE,
not whatever was there when the decision was made. It now gets the same
discipline as the reap path above it: `mv` to a private graveyard name,
then look at what was actually caught. A symlink caught there is a live
holder's fresh claim, restored immediately the same way; a genuine legacy
directory is checked for a `pid` file (the pre-round-3 marker format) — a
live pid inside is restored by moving the directory back onto a path
re-checked empty immediately before the move, never forced onto one a
fresh claim landed on in the meantime; only a directory with no live
identity inside is discarded outright, as before.

**This whole legacy-directory branch — the paragraph just above — is
DELETED as of round 8/9 (see "Round 8/9" further down): it described a
mixed-version scenario this PR never shipped into, so its population was
always empty, and four straight rounds of P1s against its own removal
sites (R5 through R8) were spent hardening code nothing could ever reach.
Left here, in present tense, as the historical record of what round 5
actually built and round 8 actually deleted — not as a description of the
shipped `_burn_reclaim_mutex_try`, which no longer reads a `pid` file or
reaps a directory at all.**

And `clikae clean`'s own
GC (below) removed the tank lock with **no mutex at all** — a second,
unguarded remover of the one thing this entire design depends on never
having a second remover — closed by giving it the identical
`_burn_reclaim_mutex_try` gate, with one rule specific to a GC rather than
a live acquirer: it SKIPS a busy tank rather than waiting for it.

Two smaller gaps closed in the same round: the mutex's own liveness test
used a bare `kill -0`, one check weaker than the lock it protects (which
also verifies the pid's `started_at` against the process's own start time)
— a pid recycled onto a dead mutex holder's number wedged the mutex, and
the tank it guards, for the recycler's entire lifetime; it now runs the
identical marker check, with a `started_at` reported ahead of `now` (a
clock step in either direction) clamped rather than read as "not due yet."
And a signal landing while a burn already held the reclaim mutex from its
own reclaim path made the signal's own release trap try to RE-acquire a
mutex it already held — correctly refused (the mutex sees its own live pid
and won't evict it), so the release spun its whole retry budget, then did
so again when the signal's own `exit` triggered the separate EXIT trap
stacked behind it (measured: 18-19 seconds to actually exit, the mutex
left leaked for that whole window, self-healing at the mutex's own 30s
stale rule). One process-local flag now records which mutex, if any, this
process currently holds, so a trap firing inside that window acts directly
under it instead of trying to reacquire it. Separately, the "mutex is
busy" branch of the lock's own retry loop had no backoff at all — only the
neighboring "holder is live" branch slept — so a burn blocked behind a
tank recovering from a signal spun at roughly 79% of a core for its whole
timeout; the fix is the same one-second sleep the neighboring branch
already pays.

**The residual, honestly (numbers corrected by round 9 — see "Round 9"
further down for the fix).** This mutex is not mathematically exclusive.
A reaper can still lose the race between its own unsynchronized read and
its `mv`: it evicts a live holder, and if a THIRD claim lands on the
vacated path in the few syscalls before the reaper's restore attempt, that
restore fails and is not retried — two processes are then briefly inside
the same removal critical section at once. **This paragraph originally
read "measured at 0 violations across 300 real `clikae burn` trials …
a retry rhythm no real caller produces" — both halves of that sentence
are false.** Round 9's own review put `clikae clean` (an entirely
ordinary real caller — nobody's synthetic hammer) racing three real
`clikae burn` processes on the same seeded-wreckage arm round 8 had
already run at 0/50, now at four times the trial count: **6 violations
in 130 real trials (≈4.6%)**, each carrying the ordering signature
(`VIOLATION` written strictly between one engine's `ENGINE_IN` and its
own `ENGINE_OUT`) that rules out an instrument artefact, and a paired,
load-matched A/B against the pre-round-9 build found it there at roughly
twice the rate (5/30 vs 2/30) — not a regression from round 9, but not
"no real caller produces it" either. **The actual mechanism was not this
mutex's own residual race at all** — it was a separate, unrelated bug one
level up: `_burn_tank_lock_acquire`'s (and `_clean_tank_lock_gc`'s) own
re-verify-under-the-mutex block decided the LOCK was stale from a
`readlink` (forking `_burn_pid_matches_marker`'s `ps`+`date` in between)
and then bare `rm -f`'d the path — the exact "decide, then trust an
earlier read" shape this mutex exists to prevent, just never applied to
the lock the mutex protects. Round 9 closes it: the lock's own reap now
goes through `_burn_tank_lock_reap_verified`, the identical
`mv`-then-classify discipline this mutex already uses on itself (5/5
deterministic at each of the two sites with a hook). No fresh trial count
for the MUTEX's own bounded residual (described above this note) is
claimed here — round 9 measured the bug that was actually firing and
fixed it, not the mutex's own separate, smaller residual, which remains
un-re-measured after the fix.

**Round 10 re-ran that same arm on the fixed build** (`da975fc`): **0
violations in 100 trials (300 real `clikae burn`, 500 real `clikae
clean`, 142 engines)**, with the witness validated on the same fixture at
**12 violations / 10 trials** when `_burn_tank_lock_acquire` is
neutralised. The pre-round-9 build, run as a paired control at the same
load, also produced 0/50 — at this machine's load (2.6–6.9 on 8 cores,
against round 9's own 7–58) the wild arm is not sensitive enough to
separate the two builds on its own; what actually separates them is the
deterministic rendezvous at each of the two `mv`-then-classify call
sites: **0/5 destroyed on HEAD vs 5/5 on the control**. The worst case this residual can still
produce is bounded and self-correcting: one extra live holder for the
span of one removal critical section, caught by the tank lock's own
owner-only release — two burns briefly sharing one tank (#40, the exact
symptom this whole mechanism exists to prevent), never data loss or a
corrupted status file.

**Round 8 found the legacy-directory branch's own removal sites still
unverified, and it is deleted rather than patched a fifth time (2026-09-11,
KITT ruling on the round-8 review, R8-P1-1/R8-P1-2).** Round 6's rewrite
(above this paragraph in every earlier draft of this doc) classified a
legacy `mkdir`-based mutex directory before ever moving it, and round 7
added a `[ -L "$grave" ]` arm so a live holder's SYMLINK caught racing that
classification's own `mv` would be restored rather than dropped. Round 8
found that restore trusted `ln -s`'s exit code as proof the symlink landed
back at the mutex path — and `ln -s` returns `rc=0` without doing anything
whenever the destination resolves to a directory (measured identical on
GNU coreutils' `ln` and BSD `/bin/ln`): `restored it` printed 10/10 while
the live holder's claim was created as junk inside a foreign directory and
the only surviving copy was then deleted (R8-P1-1). A second guard, added
the same round to keep a foreign symlink-to-directory from being nested
into by an ordinary claim attempt, removed the mutex path with a bare
`rm -f` — no re-test, no mutex, no output — so a live claim landing in its
two-statement window was deleted in total silence, 5/5 (R8-P1-2).

**This PR never shipped, so no released clikae ever created a
directory-shaped reclaim mutex** — the legacy-directory branch's entire
population, a mixed-version run straddling the round-3-to-round-4 cutover,
was always empty. Patching a fifth removal site inside a branch nothing
has ever needed is not the fix; deleting the branch is. What replaces it,
the sibling non-directory branch, and both of the foreign-symlink-to-
directory guards is **one rule**: if the mutex path exists and is not a
symlink whose target is plain data — a directory, a symlink resolving to
one, or a regular file — the reaper never touches it. It refuses loudly,
names the path, and — because the condition never self-heals — refuses
TERMINALLY rather than backing off (see Round 9 below), counted under its
own `foreign-mutex` reason; `clikae clean` reports the same
reason on the same shapes and never removes them either — there is no
`--force` path in this PR, so recovery is "remove it by hand, then retry."
Nothing is ever restored under this rule and nothing non-symlink is ever
removed, which closes R8-P1-1 and R8-P1-2 by construction rather than by a
sixth patch. The one restore site this leaves — a live holder's fresh
symlink claim caught racing the AGE-based eviction of a stale mutex
symlink, described in the residual above — now verifies the same way:
`readlink` the path after `ln -s`, not its exit code, and keep the graveyard copy on a
mismatch instead of discarding the only surviving copy of a live claim.

The mtime-fallback helper this branch needed (round 7's fix for an `echo 0`
sentinel that reaped a genuinely live legacy holder, R7-P2-3) has no other
caller and is deleted with it.

**Round 9 found four things the round-8 rewrite still had wrong, and
closes them (2026-09-11 round-9 review, R9-P1-1/R9-P1-2/R9-P2-1/R9-P2-2).**

*R9-P1-1 — the LOCK's own reap never got the mutex's own discipline.* The
mutex's removal (above) is `mv`-then-classify; the LOCK it protects —
`_burn_tank_lock_acquire`'s re-verify-under-the-mutex block, and
`_clean_tank_lock_gc`'s twin — was still a bare `readlink`-decide-then-
`rm -f "$lock"`, with `_burn_pid_matches_marker`'s `ps`+`date` forks sitting
between decide and remove. The reclaim mutex serialises REMOVERS of the
lock, never CLAIMANTS (a claim is a bare `ln -s`, no mutex at all), so a
live burn's fresh claim landing in that fork-sized window was deleted
while it was inside its own check-and-write — measured through real
`clikae burn`/`clikae clean` binaries, 6 genuine engine overlaps in 130
trials (see the residual note above). Fixed with a new shared helper,
`_burn_tank_lock_reap_verified`: `mv` the lock atomically, then compare
what was actually caught against the identity already judged stale; a
match discards it, a mismatch restores it and verifies the restore by
`readlink` (R8-P1-1's own rule, applied here to the lock). Deterministic
at 5/5 at each of the two call sites with a hook.

*R9-P1-2 — the foreign-mutex refusal is permanent, and two of its three
call sites spun on it at full CPU.* "Refuse and back off like an ordinary
busy mutex" is the rule's own promise, but a foreign object never
self-heals: at the third call site (the ordinary stale-holder path) that
promise was already a real `sleep 1`; the other two (a pre-round-3
directory-shaped lock, and a symlink-to-directory-shaped lock) `continue`d
with no sleep at all, which cost nothing while every foreign object was
still reclaimable (pre-round-8) but became a hot spin the moment round 8
made the refusal permanent — measured 9.79s of CPU (≈89% of a core) and
49,151 duplicate refusal lines in one 10s burn. Since the condition is
permanent by construction, the fix is not a bigger sleep: all three call
sites now detect a foreign reclaim mutex specifically and return a
distinct, TERMINAL code (`_burn_tank_lock_acquire` returns `2`, records
the path in `_BURN_LOCK_ACQUIRE_FOREIGN_MUTEX`) that exits the acquisition
loop immediately — refused once, never retried, never counted against the
ordinary busy-timeout. `cmd_burn` reads this to write a `foreign-mutex:
<path>` reason into the status file and a message that names the actual,
permanent cause instead of "try again shortly" (closing R9-P2-3 the same
motion — the SIGKILL refusal below keeps its own, still-correct wording).
An ordinary busy mutex (someone genuinely mid-check) still gets the plain
`sleep 1` backoff on all three sites, unchanged.

*R9-P2-1 — the foreign-mutex predicate did not implement the rule all
three surfaces (this doc, the code comment, the refusal message) state.*
`[ -e "$1" ] && { [ ! -L "$1" ] || [ -d "$1" ]; }` let one shape through:
a symlink resolving to an EXISTING, NON-DIRECTORY object (a regular file,
a symlink chain to one, `/dev/null`) made `-e` true but both of the other
two conditions false, so it was classified NOT foreign and evicted —
measured, removed rather than refused, exactly the object every surface
promised was untouchable. `-e` alone is the whole rule: this codebase's
own claim is always DATA (`<pid>:<started_at>`), never a real path, so
`-e` on it is always false regardless of liveness, and *anything* the
path resolves to is foreign because nothing here ever writes anything
that resolves to anything. This also removes the predicate's own ENOENT
race (a second/third `stat` misreading a path that vanished mid-check as
foreign instead of vacant) — with one `stat` there is no second call left
to race.

*R9-P2-2 — the CLAIM trusted `ln -s`'s exit code the way the RESTORE used
to.* The whole point of round 8's fix was "verify by `readlink`, not by
`ln -s`'s own exit code" — applied to the restore, twelve lines from the
top of the same function the CLAIM still branched on the bare exit code.
The same hazard applies: a foreign directory arriving in the window
between the `_burn_reclaim_mutex_is_foreign` check and the `ln -s` makes the claim nest INSIDE
it while still returning `rc=0`. Both claim sites — the reclaim mutex's
own, and the tank lock's own — now verify with `readlink` immediately
after `ln -s`, exactly like the restore.

**A `SIGKILL`ed burn denies its tank for up to ~30 seconds, then self-heals
— and the refusal a user reads during it now says so (2026-09-10 round-6
review, R6-P2-4).** `SIGKILL` cannot be trapped, so a burn killed while it
holds the tank lock leaves that lock exactly where it was — mutual
exclusion is never broken, but every burn that tries the same tank until
the lock's own mutex reaches its 30-second stale rule is refused outright,
measured at ~30s total (round 5 measured `+32s`, the fixer `31s`, round 6
`+30s` — the mechanism is the same 30s rule plus one 1s backoff, not a
coincidence). The refusal used to read *"another clikae burn is mid-check
on it right now"* — true for the ordinary busy case this same timeout also
covers, but false here: there is no other burn, it died, and there is
nothing to wait ON except the clock. `_burn_tank_lock_acquire`'s own
timeout gives no way to tell the two causes apart from the refusal site, so
the message now names both rather than asserting the wrong one, and this
paragraph is the "goes in the docs too" half of that fix.

**A `SIGKILL`ed burn also orphans its engine subprocess — the one still-live
route to #40 this whole design exists to prevent, and it is not this lock's
to close (2026-09-10 round-6 review, R6-P2-5).** `burn_tank_busy` keys on
the BURN's own pid; a `SIGKILL` to the burn does not reach the engine
process it launched, which keeps running to completion on the tank. Once
the burn's own `running` status row reads as stale (its pid is gone), the
next burn on that tank is let straight in — while the orphaned engine is
still using it. Reproduced directly: an engine observed still alive 1
second after its burn's `SIGKILL`, finishing 6 seconds after the burn that
launched it died. This is the entire explanation for the one seeded-wreckage
arm of the real-`clikae-burn` trial suite that ever sees a #40 violation at
all — a `SIGKILL` storm with the orphan drained before the next wave is 0
violations in 50 trials; the identical storm with the orphan left running
is 50/50. Nothing in the lock or its reclaim mutex
should try to fix this — the lock's job is serializing who gets to START a
burn, not supervising a process it does not own the lifetime of — but it is
written here because it was, until this round, written nowhere at all.

**Round 10 re-verified clause (a) on the fixed build, then found three
things blocking merge and seven smaller ones (2026-09-12 round-10 review,
R10-P1-1/R10-P2-1/R10-P2-2, plus P3s).**

*R10-P1-1 — `clikae clean`'s own tmux-lock GC died silently under errexit
whenever a burn was running, taking the tank-lock GC down with it.*
`_clean_tmux_gc`'s two probes (`flock -n …; rc=$?` / `lockf -k -t 0 …;
rc=$?`) were the exact bare-statement-under-`set -eo pipefail` shape
R9-P1-1 fixed at `cmd_burn`'s own acquire call, just never grepped for at
the sibling site. A genuinely-held ephemeral lock — which any `clikae
burn`'s tmux wrapper holds for its entire run — made the probe exit
non-zero, and errexit terminated `clikae clean` right there: rc=75
(lockf) or rc=1 (flock), zero lines of output, and `_clean_scrollback_gc`/
`_clean_tank_lock_gc` — the recovery path this very PR documents for
everything above — never ran. Fixed with the same `rc=0; cmd || rc=$?`
shape as `cmd_burn`'s own fix, and the busy branch now names the lock
instead of staying silent (`lib/commands/clean.sh`).

*R10-P2-1 — round 9 added a second graveyard family; nothing sweeps it.*
`_burn_tank_lock_reap_verified`'s own "could NOT restore" branch keeps a
grave (`tank-busy-*.lock.stale.*`) as the only surviving copy of a live
claim, exactly like the reclaim mutex's own grave — but `clean.sh`'s
graveyard loop matched only the mutex family's `*.lock.reclaim.stale.*`
glob, while its comment claimed to cover "every graveyard `_burn_reclaim_
mutex_try` can now create." Fixed by sweeping both globs (they cannot
collide — `.lock.stale.` never appears as a substring of
`.lock.reclaim.stale.…`) and rewriting the comment to name both reapers.

*R10-P2-2 — see R10-P2-2 above this note*: two sentences (one here, one
in CHANGELOG.md) still claimed in the present tense that a foreign-mutex
refusal "backs off exactly like an ordinary busy mutex" — the exact
behavior R9-P1-2, a few dozen lines above in this same file, reversed
into a terminal refusal. Both now say so.

Seven smaller findings, all fixed in the same round: the lock's own reap
call (`:1634`) was safe only because its one caller happened to wrap it
in `|| rc=$?` — it now guards its own `&&`-list tail with `|| true` so it
is safe regardless of how it is called (R10-P3-1); a claim that loses the
race into a directory arriving in the unguarded window between the
foreign check and `ln -s` used to leave a stray symlink INSIDE that
foreign object with no cleanup — it is now removed by name, never
anything else the foreign object contains (R10-P3-2); the CLAIM
readlink-verify's only guard was a text-grepping structural test — a
behavioral test now drives the actual race through a PATH-level `ln`
substitution and asserts on real restore/no-restore behavior, not source
text (R10-P3-3); both reapers' "raced a live claim/holder (pid %s)"
messages could print an empty `(pid )` for a caught empty-target claim,
and overclaimed "live" for a pid-matches/started_at-differs recycled
marker — both now report the raw caught identity and say "did not judge
stale" instead of asserting liveness they never re-checked (R10-P3-4);
both graves' `$$.$RANDOM` naming is now joined by a wall-clock timestamp,
closing the (already small, and shrinking further once R10-P2-1 sweeps
kept graves promptly) collision window between a deliberately-kept grave
and a later pid-recycled process drawing the same `$RANDOM` (R10-P3-5);
the residual paragraph above had no post-fix numbers of its own, inviting
a reader to mistake the pre-fix 6/130 for the current state — the Round
10 numbers are now inline there too (R10-P3-6); and a 50-trial campaign that kept full state after every trial (rather
than deleting clean ones, as the first campaign did) found residual
litter in 27/50 trials — almost entirely mutex-family graves from
ordinary reap-and-discard races, the same shape a pre-round-9 control
build left at a similar rate (28/50), so this is not something round 9 or
10 introduced. Every sampled trial's litter was removed completely by one
subsequent real `clikae clean` run — self-healing was already true, and
is now reachable in practice, not just in principle, because R10-P1-1
means `clean` actually runs while it matters most (R10-P3-7).

### `--wait-for-reset` (#38)

A tank that runs dry minutes before its own reset used to just Stop (under
`--no-reroute`) or hop to the next reserve tank — even when waiting a few
minutes would have let the SAME session finish the SAME task. `--wait-for-reset
<dur>` (`30m`, `2h`, `90s`, or a bare integer of seconds) changes that: when a
tank goes dry AND the vendor's own reset phrase resolves (via
`limit_reset_epoch` — the same two English grammars documented in
`lib/core/limit.sh`, "resets 3:50am (Asia/Tokyo)" / "resets Jul 27 at 5am
(Asia/Tokyo)") to an instant within `<dur>`, `burn` prints one line, sleeps to
it, and re-fires the SAME tank instead of moving on. A reset further out than
`<dur>`, or one the phrase doesn't parse into an instant, falls through to the
normal reroute-or-stop behaviour unchanged.

**This tank is NOT abandoned while it sleeps (2026-09-09 round-1 review,
P1-2.)** The status file says the non-terminal `waiting-reset` for the whole
sleep (`reset_at` carries the target epoch) — never the terminal `dry` #41's
`wait` would read as "this run is over" or #40's `burn_tank_busy` would read
as "this tank is free". On wake, the reset is RE-CHECKED (not blindly
trusted — a relative vendor phrase re-anchored later, or a sleep that woke
early, could mean it hasn't actually landed yet); one bounded extra wait is
given, capped at the original `<dur>`, before falling back to the normal dry
path. Only once a real outcome is known — the re-fire's own done/dry/fail —
does the file go terminal.

## 5. Seeing your fleet

**From a terminal:** `clikae` (the board — traffic-light fuel dots per tank) and
`clikae tanks` (accounts). That's the authoritative view of who's fuelled and who's
dry.

**From inside a Claude Code session that's driving clikae:** the input footer shows
`· N shells ·` — the count of background shells this session is running. Press `↓`
to manage them (`Enter` to view output, `x` to stop). That count is shell-granular,
not tank-aware: it tells you *how many* jobs, and the manager shows *what* each one
is.

**Make the manager self-labeling.** The manager previews the *start* of each
command, truncated. If you lead the background command with the tank + role, every
job identifies itself at a glance:

```bash
# Lead with a [tank·role] token → the ↓ manager shows "[L·deadlinks]" not a generic prefix
tag='[L·deadlinks]'
clikae burn claude L --artifact … --prompt-file … --add-dir …
```

Without it, several jobs that share a leading `cd …` / `VAR=… ` prefix all preview
identically and you can't tell them apart. (A native aggregated roster in clikae is
on the backlog; until then, the token-first convention rides the harness's own view
for free.)

## 6. Cross-account, dry, and identity

- **Each tank burns its own subscription.** Fanning across tanks spends each
  account's quota, not the budget of your main interactive session. That's the
  whole point — the expensive supervisor stays asleep; cheap workers burn whichever
  account still has gas.
- **Infrastructure handling (Claude/Codex adapter burn).** A tool-host connection
  failure such as `timed out negotiating with the code-mode host` retries the
  **same tank**, with no dry mark or reserve hop. `--infra-retries N` defaults to
  2 retries after the initial attempt (0 disables retries; maximum 10).
  `--infra-delay S` defaults to 5 seconds, doubled before each subsequent retry
  (5s then 10s by default; integer 0–86400). `--timeout` applies per attempt.
  Exhaustion exits 1 with JSON `reason: "infra"`; existing keys and reasons stay
  unchanged. `--no-reroute` disables dry hops, not these retries. A fresh artifact
  still proves success; a quota signal still follows the dry path — but if BOTH
  are true of the same reply (the engine wrote a few bytes before hitting its
  limit), the artifact wins the outcome (`ok: true`) while the limit is still
  recorded: `reset` carries the vendor's phrase rather than being silently
  dropped, and — for engines whose dry state persists to disk (codex) — an
  EXISTING dry marker is left in place rather than cleared. A fresh artifact
  never *writes* a new marker on this path, only leaves one alone: a task that
  merely mentions the limit while succeeding cannot mark a healthy tank dry.
  Generic task timeouts without a tool-host signature remain task failures.
  agy's separate capture loop does not use this retry policy.
- **Dry handling.** Claude weekly-limit messages follow the same dry path as
  session limits, including the vendor's verbatim reset time in JSON. `burn` auto-reroutes to the next reserve tank on a dry hit
  (account-aware: it skips siblings that share an already-dried login, and the tank
  an interactive session is live on). `conduct` doesn't reroute — it reports each
  leg as captured / dry / empty so you decide.
- **Same-account fan-out shares one bucket.** Three legs on the *same* tank run in
  parallel but draw from one quota — wall-clock parallelism, not 3× throughput, and
  they go dry together. For independent quota, fan across *different* accounts.
- **Git identity for write jobs.** Before dispatching a `--write` leg that commits,
  set the tank's identity so commits aren't stamped with the engine's account email:
  `clikae git-id claude L --name "You" --email you@example.com`. `clikae env` (which
  `--tank` rides) then exports `GIT_AUTHOR_*` / `GIT_COMMITTER_*` for that shell.

## 7. The boundary — what still needs a human

clikae proves the *plumbing*: a job ran, on which account, produced which file.
It cannot judge:

- **Output quality** — whether an audit is correct, whether generated code is good.
  A neutral grader (another model, or you) decides.
- **Runtime behaviour** — a UI that renders, a server that answers. `burn` only fits
  tasks whose success is a *file you can name*.
- **An API error that looks like output.** A transient `API Error: …` string written
  to stdout is non-empty, so a naive "has output" check can read it as success —
  glance at short results before trusting them.

That irreducible human (or independent-model) judgement is a feature, not a gap:
clikae stays a switcher, the conductor stays the brain.

## 8. Model-tiering by task risk

Dogfooding a real multi-model fleet (a full app build across claude + codex + agy)
produced a working rule for which model tier to put where:

| Role | Model tier | Why |
|---|---|---|
| Orchestrator / verifier | High-capability (e.g. claude Max) | Plans, judges output, makes cross-task decisions — mistakes here cascade |
| Implementer | Mid-tier (e.g. claude Sonnet / codex) | Net-new trust-critical work: new integration code, security-adjacent paths |
| Mechanical grunt | Cheap (e.g. agy via stdin, a sub-Sonnet model) | Reformatting, summarising, boilerplate — already well-specified, easily verified |

**Red line:** don't drop below the mid tier for net-new, trust-critical integration
work. "Cheap" makes sense for tasks where the output is fully verifiable by
inspection or by a test; it is risky for tasks where the verifier itself would need
to be as capable as the implementer to catch a subtle bug.

**Parallelism ≠ redundancy.** Fanning the same task across accounts (same tier)
gives you speed + a dry-tank fallback, not a correctness vote. For a correctness
vote, use `clikae conduct` and a *different* model tier per leg — then a neutral
third model grades the outputs, not the same one that produced them.

## 9. Independent verification — the neutral-grader principle

The orchestrator must **independently verify** a sub-agent's claims rather than
accept its self-report. This matters because a model that produced output is a
poor judge of whether that output is correct: it tends to rate its own work
confidently even when it has made a subtle error (the "confident-wrong" failure mode).

Practical checks in a clikae fleet:

- **Grep / stat the artifact directly** before trusting a "done" self-report. If
  the file doesn't exist or is empty, the job failed regardless of what the agent said.
- **Run the test suite or a targeted invariant check** from the orchestrator after a
  write leg — not from the same leg that wrote the code.
- **Use `clikae conduct`** (N legs, same task) and route the outputs through a
  *separate* model acting as grader — a model that only sees the outputs, not the
  reasoning that produced them. A grader reading N blind outputs spots errors the
  producer's self-assessment misses.
- **Do not infer correctness from tone.** A confident, well-structured completion
  message ("I've implemented X, added tests, and updated the docs") is not evidence
  the implementation is correct. Grep for the invariants; run the binary.

The orchestrator's job is to hold the epistemic standard the workers cannot hold
for themselves.

## 8. Quick recipes

```bash
# Best-of-N audit across accounts — read-only, parallel, you pick the winner
clikae conduct --prompt-file review.md \
  --leg codex/H --leg claude/C --leg claude/L --add-dir "$PWD"

# Headless codegen with automatic failover when a tank runs dry
clikae burn claude C --artifact out/feature.ts \
  --prompt-file task.md --add-dir "$PWD" --timeout 900

# Carry a live session onward when you hit a wall (same engine resumes; another = brief)
clikae to L          # next fuelled tank, same conversation
clikae to codex      # cross-vendor: a written brief, summarised on-device
```

See also: [grammar.md](grammar.md) (the language), [usage.md](usage.md) (full
reference), [EXPECTATIONS.md](EXPECTATIONS.md) ("is this a bug?" — deliberate
surprises), and the `conductor` Claude Code skill for session-driven leg routing.

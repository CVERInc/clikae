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
  "reset": null,            // the vendor's verbatim reset phrase, when there is one
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

**Guaranteed to reach a terminal state (2026-09-09 round-1 review, P1-1.)**
The FIRST `running` write installs an `EXIT`/`INT`/`TERM`/`HUP` trap that
writes a terminal `fail` (with the exit code in `reason`) unless one was
already published — so an early argument-validation failure, an unhandled
error from a sourced helper, or the process being killed all leave the file
saying `fail`, never a `running` that nothing will ever change again. A `wait`
caller still has to handle a status file from an OLDER clikae (or one written
before this fix): see `stale` below.

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
trap existed (see above) — a new burn should never leave one of these behind,
but `wait` does not get to assume every status file on disk came from the
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
either has written `running` — a per-tank `mkdir`-based lock (atomic even on
bash 3.2, no `flock`/`lockf` dependency) now wraps the check-and-write, held
only across those two statements, never across the engine run itself. A lock
left by a since-dead holder is reclaimed rather than blocking forever.

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

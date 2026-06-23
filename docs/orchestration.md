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

agy is half-in: **`conduct` can fan a read-only leg to it** (cheap, fast breadth —
`--leg agy/<tank>`), but `burn` and the conductor legs can't. agy's login is one
**global** Keychain entry, so there's no per-shell env to switch and **`burn` can't
reroute it** ("not burnable" ≠ "not usable"). The conduct leg sidesteps that by
running on whatever agy tank is **active** (it never switches — a leg naming another
tank is reported, not run, since the `~/.gemini` swap is machine-wide and exclusive,
so two agy tanks can't run in parallel):

```bash
# agy as a best-of-N breadth leg, alongside claude/codex (agy runs on its active tank):
clikae conduct --prompt-file review.md --leg claude/C --leg codex/H --leg agy/c --add-dir "$PWD"

# Or drive agy directly headless to spend its quota instead of your main budget:
clikae agy <tank> -- --print-timeout 900s -p "$(cat /tmp/prompt.txt)"
```

agy's headless personality differs from claude/codex enough that hand-rolling it the
usual way fires a blank (it buffers big stdout and returns nothing; it wanders and
burns the timeout; `-i` dies without a TTY). **Use the dedicated recipe —
[`docs/agy-dispatch.md`](agy-dispatch.md) — before sending agy a headless job.** It's
a real paid engine; the recipe is how you stop wasting it.

## 3. The rules that keep it honest (hard-won — break one and you fire a blank)

1. **Judge by the artifact / output, never the exit code.** A headless `codex exec`
   or `claude -p` exits `0` even when it hit its usage limit and wrote nothing.
   `burn` judges by the artifact's presence + fresh mtime; `conduct` by the
   captured output; the legs by `--out` content. Never trust `$?`.

2. **Give the task the easy way — don't hand-roll the engine flags.** Use
   `--prompt-file <f>` (or `--prompt`) + `--add-dir <dir>` and clikae fills in each
   engine's headless-write dialect for you (`claude`'s `-p …
   --dangerously-skip-permissions --add-dir`, `codex`'s `exec -C … -s
   workspace-write`). Hand-writing `-- -p '…'` is the #1 way to ship a job that
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
- **Dry handling.** `burn` auto-reroutes to the next reserve tank on a dry hit
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

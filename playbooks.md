# Playbooks — wielding the fleet

Every other page documents a *capability*. This one maps **situations to moves**: which
play to reach for, and the exact call. If you are an agent driving clikae, this is your
decision layer — [AGENTS.md](https://github.com/CVERInc/clikae/blob/ba8c33a40e23ac1e86b4356c655e05eef1b019c1/AGENTS.md) and [orchestration.md](/orchestration.md) give
the mechanics and the non-negotiable rules; this gives the *when*.

The through-line: an account switcher gives you another **login**. clikae gives you a
**fleet you orchestrate** — route by cost, verify across vendors, run in a clean room,
survive a dry tank. Every play below leans on the rules in
[orchestration.md](/orchestration.md) and [agy-dispatch.md](/agy-dispatch.md); read those
first if a call surprises you.

**Reading the commands below.** Each call is `clikae <engine> <tank> …`: the **engine**
is the CLI (`claude`, `codex`, `agy`), the **tank** is one account/config for it. Names
like `worker`, `work`, `g`, `acme` are **placeholders** — run `clikae tanks` to list
yours and `clikae` (the board) to see which still have fuel. Which engine you name is
just which account you're routing to; the play is the same whichever it is.

---

## A review you can trust — with no self-bias

**Reach for this when** the session that produced the work can't audit it fairly — to a
writer, *handled* reads as *correct*. You want eyes without your assumptions.

**The move** — run the review in a clean room, on a different model family:

```bash
# agy (Gemini underneath) browses live and writes a report; it holds no memory of your work.
clikae agy g -- --print-timeout 900s -p "$(cat /tmp/audit-prompt.txt)"
```

For a clean room on the *same* family: `clikae claude <tank> --ephemeral` — the session
runs, but the tank's long-term memory never learns it happened.

**Verify / gotcha:** read the report file, never the exit code. Triage the findings —
agy is a grader, not an oracle, and will confidently flag things that violate a decided
call. Apply fixes with your main engine; never auto-apply agy's.

**Why a switcher can't:** it gives you a second *login*. This gives you a second
*perspective* — another vendor's model, carrying none of your session's baggage.

---

## Grunt work off your main quota

**Reach for this when** a well-specified, easily-checked job (reformat, summarise,
boilerplate, a mechanical transform) is burning the quota of the model you need for the
hard part.

**The move** — burn it on a cheap tank, verified by the artifact:

```bash
clikae burn claude worker \
  --artifact out/result.json --prompt-file /tmp/task.md --add-dir "$PWD"
```

**Verify / gotcha:** success = the artifact appears (or its mtime changes). Never trust
the exit code — `codex exec` / `claude -p` exit `0` on a dry tank having written nothing.
Don't hand-roll `-- -p '…'` (it runs read-only and can't write); let `--prompt-file` +
`--add-dir` fill in each engine's write dialect.

**Why a switcher can't:** it stops at "you're logged into the other account now." burn
routes the *job* — re-fires it on the next reserve tank when one runs dry, and skips the
account your interactive session is on. The expensive supervisor stays asleep; the cheap
workers burn whatever account still has gas.

---

## A high-stakes call — best-of-N with a real vote

**Reach for this when** one model's confident answer isn't enough to bet on (a design
decision, a security-adjacent review). You want a vote, not a speed-up.

**The move** — fan the SAME read-only prompt across *different families/tiers*, then have
a separate model grade the outputs:

```bash
clikae conduct --prompt-file /tmp/review.md \
  --leg claude/main --leg codex/work --leg agy/g --add-dir "$PWD"
```

**Verify / gotcha:** conduct never judges — it hands you every leg's output. Route those
through a *neutral grader* (a model that sees only the outputs, not the reasoning that
produced them); it catches the confident-wrong error a producer's self-assessment misses.
The agy leg runs on its currently-active tank only.

**Why a switcher can't:** fanning the same prompt across the same account is parallelism,
not a correctness vote. The vote needs *different vendors* plus a *third grader* — that's
orchestration, not switching.

---

## Keep a long job alive past a dry tank

**Reach for this when** an unattended, multi-minute job must finish *somewhere* even if
the tank you start it on hits its usage limit.

**The move** — burn it; the reserve walk is automatic:

```bash
clikae burn codex work \
  --artifact build/out.tar --prompt-file /tmp/job.md --add-dir "$PWD" --timeout 1800
```

**Verify / gotcha:** artifact present = done; dry on *every* reachable tank = a real
failure (not rerouted — it would fail the same everywhere). Make the task idempotent so
a re-fire costs nothing. (This is the same `burn` as *Grunt work off your main quota* —
a job that is both cheap and long is both plays at once; one call does the cost-routing
and the dry-tank failover.)

**Why a switcher can't:** it makes *you* notice the wall and re-drive by hand. burn's
reserve *is* the failover — account-aware, artifact-checked, hands-off.

---

## Separate worlds, one keystroke

**Reach for this when** you run work for several clients or personas and a leak between
them — a wrong git identity, a cross-loaded MCP connector, a shared memory — would be a
real breach.

**The move** — one tank per world; wall the sensitive ones off:

```bash
clikae claude acme          # that client's login, MCP connectors, memory, git-id — nothing else's
clikae solo claude acme     # make it standalone: never shareable, never in a burn/relay set
```

**Verify / gotcha:** `clikae memory status` shows what a tank shares; a `solo` tank
refuses `share`. Commits carry the tank's identity only if you set it with
`clikae git-id` (see [orchestration.md](/orchestration.md) §6).

**Why a switcher can't:** it swaps a *login*. Each clikae tank is a whole isolated world
— memory, connectors, commit identity — and `solo` makes that isolation structural, not
a habit you have to remember.

---

See also: [orchestration.md](/orchestration.md) (the rules behind these plays),
[agy-dispatch.md](/agy-dispatch.md) (the cross-family engine, read before using agy),
[memory.md](/memory.md) (the share / isolate / ephemeral dial).

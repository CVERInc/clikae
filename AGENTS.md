# AGENTS.md — driving clikae as an agent

You are likely an AI coding agent (Claude Code, Codex, Antigravity, …) being asked to
use clikae. This file is your front door: read it and you can wield clikae correctly
on the first try. (Human-facing intro is in [README.md](README.md); the language spec
is [docs/grammar.md](docs/grammar.md).)

## What clikae is, in one breath

The human's AI work has two halves. The model half is rented — engine, capability,
quota. The other half is **theirs**: who they are, what they know, where they left
off, what should leave no trace. clikae is the thin, all-local layer that keeps that
half portable, so changing engine or account doesn't mean amnesia. Juggling several
accounts falls out of that; it is **not** the point, and clikae is deliberately not
positioned as an "account switcher" ([docs/VISION.md](docs/VISION.md) is the SSOT —
read it before you write any user-facing copy).

Mechanically it is a small, auditable bash CLI with **no telemetry, no daemon, no
network calls** (one opt-out update check). It only ever sets an engine's config env
var (e.g. `CLAUDE_CONFIG_DIR`); it never logs in for the user and never touches their
data without a backup.

Vocabulary: **engine** = a CLI it manages (claude, codex, agy…). **tank** = one
account/config for that engine. **fuel** = that account's quota. **Soul** = a
vendor-neutral markdown brain the fleet shares (in the fleet = sharing; `solo`
= not — there is no third state). clikae is the verb:
`clikae <engine> <tank>` switches; `clikae <engine> <tank> -- <args>` passes through.

The human's own entry point is bare `clikae` — a board of their recent sessions
across every account and engine, with `clikae resume` reaching back to any past one
by title. You will rarely drive that; know it exists, because it is what a tank is
*for*. A tank is a working identity with memory and history, not a quota bucket.

## Driving it headless (the part you'll actually use)

Three dispatch shapes — full field guide in
[docs/orchestration.md](docs/orchestration.md):

- **`clikae burn <engine> <tank> --prompt-file <f> --add-dir <repo> --artifact <path>`**
  — one unattended task, verified by the **artifact** it produces, auto-rerouted to
  the next reserve tank if one runs dry. Don't hand-roll engine flags; the
  convenience surface fills in each engine's headless-write dialect.

  **Add `--json`.** One object on stdout, every word of progress on stderr, so
  you never parse prose to learn what happened:

  ```sh
  clikae burn codex work --prompt-file t.md --artifact out.md --json \
    | jq -r 'select(.ok) | "\(.engine)/\(.tank) wrote \(.artifact_bytes)B"'
  ```

  `{ok, engine, tank, artifact, artifact_bytes, reason, reset, rerouted_from[],
  elapsed_s, run_id}`. Read `tank`, not the one you asked for — with rerouting
  they are often different, and `rerouted_from` is the trail. `reason`
  distinguishes the two failures that matter: `every reachable tank is dry` (wait
  or add fuel) from `no fresh artifact and no limit` (the task itself failed).
- **`clikae conduct --leg <e>/<t> … --prompt-file <f>`** — fan ONE read-only prompt
  across N accounts in parallel (best-of-N audits/analyses); collect every leg's
  output. clikae never judges — you pick the winner.
- **`clikae to <target>`** — carry a live session onward when a tank runs dry.

Which shape for which situation — the decision layer above these mechanics — is
[docs/playbooks.md](docs/playbooks.md).

## Non-negotiable rules (break one and you fire a blank)

1. **Judge by the artifact/output, never the exit code.** A headless `codex exec` /
   `claude -p` exits `0` even when it hit its usage limit and wrote nothing.
2. **Multi-line prompts go through `--prompt-file`**, not a shell-quoted `-p '…'`
   (nested quotes silently eat the prompt).
3. **A write task needs `--add-dir <repo>`** or the engine can't reach the files.
4. **Don't bypass the human's safety gates.** If a call is blocked (e.g. needs
   `--dangerously-skip-permissions`), that's for the *human* to run — never trick
   your way around it with `cat`→`head`-style substitutions. User excitement is not
   authorization.
5. **Want a memory-less session? That's `--ephemeral`, and nothing else.** To
   spawn a cold reader — an unbiased audit, a reviewer who doesn't know what you
   believe — launch it with `clikae claude <tank> --ephemeral`: that run gets a
   throwaway memory, no skills, and none of the fleet's MCP servers, and the
   tank's Soul is put back afterwards. Add `-- -p "…"` and it writes no
   transcript either; interactively it still does, because Claude Code ties
   `--no-session-persistence` to `--print`.

   Do **not** reach for `clikae solo`. It is the permanent form: it takes the
   tank out of the fleet and off the shared brain **from now on**, for every
   project directory and every *other session already running in them* —
   including, quite possibly, yours. `memory isolate` used to be the trap here;
   an agent ran it on a live tank on 2026-07-12 to get a cold reader and the
   human's session lost its memory mid-flight. That verb has since been retired
   into `solo`, which means the footgun changed names rather than disappearing.

   **Ephemeral changes this run; solo changes from now on.** Same rule across
   engines: for a cold read on another family, use `agy --sandbox` in an empty
   directory, not a rewire.

6. **A solo tank is not yours to dispatch.** Existing ≠ available. Ask, in a
   form you do not have to read by eye:

   ```sh
   clikae memory status --json | jq -r '.[] | select(.dispatchable) | .tank'
   ```

   `dispatchable` is false for a solo tank, and also for one in the impossible
   *solo-and-shared* state — there the wiring does not match the label, so
   nothing about it is safe to reason about. `clikae tanks` lists what exists; it
   does not tell you what you may use. A solo tank is walled out of the fleet by design — `burn` never
   auto-reroutes onto one, `memory share` refuses it, and the fleet's MCP fan-in
   skips it. It is the human's private cockpit, not a spare seat.


## Dispatching cold readers (the sub-agent shape)

`--ephemeral` with `-p` is clikae's sub-agent primitive, and it is meant for you,
not only for a human at a keyboard. Measured 2026-08-15 rather than claimed:

```sh
cd "$(mktemp -d)" && clikae claude h --ephemeral -- -p "<the question>"
```

| what you get | measured |
|---|---|
| runs unattended, answer on stdout | rc=0 |
| cold — no memory, no skills, no fleet MCP | the run announces all three |
| spends THAT tank's quota | yes, which is the point of aiming it at a reserve |
| **leaves nothing in `clikae resume`** | 308 transcripts before, 308 after |
| leaves the Soul untouched | 436 memory files before, 436 after |
| **runs in parallel** | three at once, all rc=0, no residue |

🔴 **One working directory per parallel run.** The memory slot is keyed on `$PWD`,
so two ephemeral runs in the same directory target the same slot — and the second
does not merely fail: its self-heal step reads the first run's symlink as a
crashed leftover and moves the real memory back out from under a live engine.
That is the 2026-07-19 incident, and fanning out cold readers reaches it on
purpose rather than by accident. clikae now takes a lock per slot and refuses the
second run with an explanation instead of a bare `ln:` error — but the lock is a
guard, not a feature. `cd "$(mktemp -d)"` per run is the shape that works.

For ONE prompt across N tanks, prefer `clikae conduct` — it already fans out and
collects every leg. Reach for hand-rolled parallel ephemerals when the prompts
differ.
## agy (Antigravity) is the trap — read its recipe first

agy is the one engine agents fumble most. Its Google login is **one global Keychain
entry**, not a per-shell env var — so there is no `clikae env agy`, and two agy tanks
can never run at once.

**It IS burnable, sequentially** (since v0.10.0): `clikae burn agy <tank>` auto-hops
to the next agy tank on dry, because the Keychain carry made a tank switch
non-interactive. What it can't do is run in parallel — the hop *moves* the one global
active tank. Also fine: a one-shot on the already-active account with
`clikae agy <tank> -- -p`, or a read-only `conduct` leg (`--leg agy/<active-tank>`,
which reports `NOTACTIVE` rather than silently using the wrong account).

Its output buffers (collect via a written file, not stdout), it wanders without a
fenced task + long `--print-timeout`, `-i` dies without a TTY, and dry shows in
`cli.log` not stdout. **Before sending agy a headless job, read
[docs/agy-dispatch.md](docs/agy-dispatch.md).**

## Identity

Commits made through a tank inherit the shell's git identity, not the tank's, unless
you set one: `clikae git-id <engine> <tank> --name N --email E` makes `clikae env`
export `GIT_AUTHOR_*`/`GIT_COMMITTER_*` so commits aren't stamped with the engine's
account email. clikae can only prevent the *next* mis-stamp, never rewrite history.

## Where to look

- [docs/playbooks.md](docs/playbooks.md) — which play for which situation (the decision layer above the mechanics).
- [docs/grammar.md](docs/grammar.md) — the command surface, SSOT.
- [docs/memory.md](docs/memory.md) — the Soul layer, SSOT. Read before touching
  anything under `clikae memory`; §4 holds the locked values (a machine that never
  opted in shares nothing; crossing to a DIFFERENT account is always announced;
  seed by copy, never mutate the source).
- [docs/orchestration.md](docs/orchestration.md) — headless dispatch playbook.
- [docs/agy-dispatch.md](docs/agy-dispatch.md) — the agy recipe (read before using agy).
- `clikae <command> --help` — every command self-documents; trust it over guessing.

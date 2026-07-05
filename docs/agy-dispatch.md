# Driving agy (Antigravity) headless via clikae

A focused recipe for one specific job: **route work to your Antigravity (agy) Pro
account instead of burning your main Claude/codex quota.** agy is a real, paid
engine — use it. But it behaves differently from `claude -p` / `codex exec`, and
most wasted agy quota comes from driving it the wrong way. This page is the
canonical how-to so you don't re-learn it (and re-burn it) every session.

> TL;DR — agy is **global, single-account** — one account active across all
> terminals at a time, never two in parallel. As of 2026-07-05 that no longer
> means "not burnable": `clikae agy <tank>` carries the Google login WITH the
> tank via the macOS Keychain (verified on every switch, no interactive OAuth),
> so `clikae burn agy <tank>` can auto-hop to the next agy tank when one runs
> dry — same contract as burn for claude/codex, just sequential (agy still
> can't run two tanks in parallel).

## The one mental-model fact

agy's Google login is a **single global Keychain entry**, not a per-shell env var.
So:

- There is **no `clikae env agy`** and **no per-shell routing** — `clikae env agy`
  fails on purpose and points you here.
- `clikae agy <tank>` swaps `~/.gemini` (and its login, carried via Keychain)
  **machine-wide** — one agy account is active across *all* terminals at once.
  It's exclusive, not parallel: `clikae burn agy <tank>` walks agy's OWN tanks
  sequentially (dry → switch → retry), never two at once, and `clikae conduct`
  still refuses a leg naming a non-active agy tank (parallelism is a structural
  limit, unrelated to the OAuth friction that used to gate sequential switching).
  See `agy-gemini-shared-quota` notes for why same-account agy↔gemini is a fake
  relay (same quota bucket) — that's still true; it's cross-ACCOUNT tanks that
  now hop for free.

## The canonical headless invocation

```bash
# Switch agy to a tank (machine-wide), then run it headless on that account.
# Prompt goes through a FILE — never cram a paragraph into a shell-quoted -p '…'.
clikae agy <tank> -- \
  --print-timeout 900s \
  --add-dir /abs/path/to/repo  `# only if the task must read/write files outside cwd` \
  -p "$(cat /tmp/agy_prompt.txt)"
```

That's it. The rules below are the difference between this returning real work and
returning a blank.

## Rules that keep agy from firing a blank (hard-won)

1. **Headless agy is `-p` (print mode), never `-i`.** `agy -i` needs a real TTY
   (it's a bubbletea TUI) and dies headless with `could not open TTY`. Any
   agent-driven or background call uses `-p`.

2. **Pass the prompt via a file, not nested quotes.** `-p "$(cat /tmp/foo.txt)"`.
   Nested `sh -c '… -p "…"'` quoting silently eats the prompt and agy answers the
   wrong thing. One layer, file-fed.

3. **Don't collect big output from stdout — let agy write a file.** `agy -p`'s
   stdout return is unreliable for large/structured output: the process stays
   alive at 0% CPU and **buffers everything, emitting nothing**. For anything big,
   tell agy to *write the result to a file itself* (agentic), then read that file.
   Where it lands: `~/.gemini/antigravity-cli/brain/<session-id>/*.md` — `-p`'s
   stdout is often just a one-line pointer to it.

4. **Give a dead task, hard boundaries, and a long timeout.** agy's interactive
   strength — free exploration — is a liability headless: it will wander (e.g. go
   investigate a git diff) and burn the whole timeout writing nothing. Fence the
   prompt explicitly ("don't check git, don't investigate, only do X and write
   Y") and give `--print-timeout 900s` (default ~5 min is too short for real work).

5. **macOS has no `timeout`.** `--print-timeout` doesn't always kill cleanly. For
   unattended jobs, wrap the call in an outer hard kill (e.g. Python
   `subprocess.run(..., timeout=N)`) as a backstop.

6. **`pkill -9 -f "agy -p"` before switching tanks.** `clikae agy <tank>` refuses
   to switch while an `agy` process is live (swapping `~/.gemini` under it would
   corrupt the session). Kill stale/hung print jobs first.

7. **Reading files outside cwd needs `--add-dir <abs path>`** (pre-authorise), or
   feed pure text via stdin (`cat file | agy -p "…"`) so no tool/permission gate
   is hit. A bare `agy -p` that tries to read an un-authorised path **hangs
   forever** waiting on a permission prompt that has no TTY to answer it.

8. **`--dangerously-skip-permissions` is for a *human*, not an agent.** When clikae
   is being driven *by another AI* (e.g. Claude Code), that AI's safety classifier
   blocks an agy call carrying `--dangerously-skip-permissions` — even with a
   `Bash(agy:*)` allow-rule. Plain `agy -p` (no skip flag) passes. If a task genuinely
   needs skip-permissions, the human runs that line (e.g. `!`-prefixed); don't expect
   an agent to self-authorise it.

9. **Rotate tanks across batches to spread the weekly cap.** One global account =
   sequential execution; alternating tanks (`clikae agy 8` / `clikae agy c` / …)
   spreads usage across accounts. Net throughput is round-robin, not parallel.

## What agy is genuinely good at headless

- **One-shot text generation** — translation, transcreation, summaries, copy. Verified:
  it reliably produces single-shot output for well-scoped text tasks. (When asked to
  review zh-TW for Taiwanese voice, attach a Mainland→Taiwan term rubric — agy is
  Gemini underneath and will otherwise drift; treat it as a grader fed an explicit
  rubric, not a native ear.)
- **Live-web QA** — agy has a `read_url_content` tool and really browses (fetches
  URLs, follows links, reads HTML). Good for buyer-journey / i18n / polish sweeps,
  one report file per lens. Smoke-test once (ask it to echo a page's real `<h1>`)
  to confirm it isn't guessing. Plain `curl` is more reliable for a bare liveness
  check — don't spend agy quota on "is the site up?".
- **Big file-writing jobs offloaded from your main quota** — a whole translation
  dictionary, written to a file (rule 3), on the agy bucket, untouched by your
  Claude budget. This is the cost-aware-routing payoff.
- **A cheap breadth leg in `clikae conduct`** — `conduct --leg agy/<tank>` fans a
  read-only audit/analysis prompt to agy alongside claude/codex legs, then hands you
  every leg's output to judge. agy is cheap and fast, so it's a good extra
  perspective for best-of-N. Caveat: the agy leg runs on the **currently active**
  agy tank only (a leg naming another tank is reported, not run — clikae can't
  switch agy in parallel). Its dry state is read from `cli.log`, not stdout.

⚠️ **agy's review suggestions need triage.** It will confidently recommend things
that violate already-decided product calls. Never auto-apply an agy review's fixes —
the orchestrator or a human filters them.

❓ **Unverified (treat with care):** one observation suggests `agy -p` may not run a
fully autonomous multi-step *file-editing* loop the way `claude -p` / `codex exec`
do — it may answer single-shot or defer to an async build and return. Single-shot
text output is confirmed; the agentic edit-and-verify loop is not. If you plan to
use agy as a `burn`-style code-editing worker, validate it with a controlled task
first. See `agy-gemini-shared-quota` for the running ground-truth.

## See also

- `docs/orchestration.md` — the general headless dispatch playbook (burn/conduct/legs).
- `docs/dogfood-agy-headless.md` — the raw dogfooding diaries this recipe distills.
- `clikae agy --help` — the command surface for switching/managing agy tanks.

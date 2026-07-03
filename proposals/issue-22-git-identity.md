# Proposal — issue #22: per-tank git commit identity

> Status: ✅ **SHIPPED in v0.6.0** (the recommended Option A — per-tank git identity,
> exported via `clikae env`). This file is now an **archived reference** kept for the
> design rationale and the §5 honest-limits framing; the live behaviour is what
> matters, not this draft. Pointers to what actually shipped:
>
> - Command: `clikae git-id <engine> <tank> [--name N --email E | --unset]`
>   (`lib/commands/git_id.sh`; help text in `lib/commands/help.sh`).
> - Mechanism: when a tank has an identity, `clikae env` also emits the four
>   `GIT_AUTHOR_*` / `GIT_COMMITTER_*` exports (`lib/commands/env.sh`).
> - Grammar/docs: documented in `docs/grammar.md` §3.3 (management verbs) with the
>   honest limit — env vars beat `git config` but NOT an explicit
>   `git -c user.email=…`, and only future commits are affected.
> - Tests: `tests/bats/git_id.bats`.
>
> Option B (the `status` mismatch warning) was NOT shipped as part of v0.6.0 — it
> remains the cheap follow-up brick described in §3/§4 below. The PowerShell mirror
> is likewise still a follow-up.
>
> _Original draft preserved verbatim below._

---

> Status: **design draft** (no code yet). Origin: HANDOFF.md §13 ("tanks own the
> AI account's state, but NOT the git commit identity"). This proposal turns that
> open question into a recommended path. It does **not** touch git history and is
> not itself shipped.

---

## 1. Problem statement

A clikae **tank** is the control plane for "which identity/state is active per
session" — it holds an AI account's login, memory and quota. But a coding session
produces a *second* identity that the tank does **not** govern: the **git
author/committer** stamped onto every commit.

These two axes are unrelated today:

- The tank tells you *which AI account is driving* (e.g. a tank you think of as
  "chodaict").
- The commit's `user.name` / `user.email` come from `git config` (global) **or**
  from whatever the engine injects at commit time — which can be the engine's
  *own AI-account email* (`git -c user.email=<harness userEmail> commit …`).

GitHub maps a commit to an account by **email**, and that email can be verified on
only one GitHub account at a time. So a session run inside a tank you call
"chodaict" can silently emit commits stamped with the engine's account email →
mis-attribution on GitHub **and** a private address leaked into public history.

This is the one place where "which account am I?" has a durable, public,
hard-to-reverse consequence, and clikae is currently silent there.

### Why this is not hypothetical

It already happened (HANDOFF.md §13, 2026-06-04): a run authored **9 commits**
across `reef` + `bleedblend` whose author/committer email was the engine's account
email (`mr.crazyx2@gmail.com`). All 9 rendered under the wrong GitHub account
(`@lersiann`) instead of the intended `@chodaict` / `<x@cver.net>`. It was fixed
out-of-band with `git filter-repo` + force-push. That cleanup is **not** something
clikae can do — clikae can only ever influence the *next* commit, never re-map old
ones.

### Scope boundary (state once, hold to it)

This is the **authorship** identity axis. It is independent of:

- the **fuel** axis (quota / dry-detection), and
- the **resume** axis (carrying a session, §12 of HANDOFF).

Three different "which account?" questions. clikae owns the first two today; this
proposal is about whether — and how — it should touch the third.

---

## 2. Current behaviour (do-nothing today)

clikae **never** sets `user.name` / `user.email`. A tank's `adapter_export_env`
exports only the engine's config-dir var, e.g.:

```sh
# lib/adapters/claude.sh
adapter_export_env() {
  local profile_dir="$1"
  printf 'CLAUDE_CONFIG_DIR=%s\n' "$profile_dir"
}
```

So `eval "$(clikae env claude <tank>)"` puts a config dir on the shell and nothing
else. Whatever commits that shell produces are stamped by:

1. the engine's injected `-c user.email=…` (if it commits that way), else
2. the user's global `git config user.email` — which, on this maintainer's Mac, is
   `chodaict <x@cver.net>`.

There is no per-tank git identity, no detection of mismatch, and no warning. The
attribution is entirely at the mercy of (1).

---

## 3. The three options

### Option A — Per-tank git identity, exported (highest isolation) ✅ recommended

Let a tank carry an **optional** `git.user.name` / `git.user.email`. When that
tank is activated via `clikae env`, clikae appends `GIT_AUTHOR_*` /
`GIT_COMMITTER_*` exports so every commit made in that shell is stamped with the
tank's intended identity — regardless of what the engine tries to inject.

- **Storage:** a small `git-identity` file inside the tank dir
  (`$CLIKAE_HOME/profiles/<engine>/<tank>/clikae-meta/git-identity`), holding
  `name` + `email`. Per-tank, on disk, alongside the state it belongs to. Absent
  file ⇒ feature off for that tank (safe default).
- **Mechanism — env vars, not `git config`.** Export the four standard git env
  vars rather than mutating any `git config`:
  ```sh
  export GIT_AUTHOR_NAME="…"  GIT_AUTHOR_EMAIL="…"
  export GIT_COMMITTER_NAME="…" GIT_COMMITTER_EMAIL="…"
  ```
  Crucially, **git env vars beat `git config`**, so this pins authorship even when
  the engine commits via the user's global config. (It does *not* beat an explicit
  `git -c user.email=… commit` — see §5.)
- **Set up via a command:** `clikae git-id <engine> <tank> --name … --email …`
  writes the file; `--unset` removes it; bare prints the current value.
- **Safety:** opt-in, explicit, reversible, never silently rewrites the user's
  `git config`. Fits the informed-consent / sudo-style opt-in pattern in MEMORY.

| | |
|---|---|
| **Security** | Strongest. Pins the *intended* identity into the very shell the engine commits from; closes the leak for the normal `git config` commit path. Keeps the private/AI-account email out of public history *by construction*, not by vigilance. |
| **Implementation cost** | Medium. New `git-id` command + a tiny store helper + 4 lines in `env`'s export emission + bats. ~100–150 lines incl. tests. No history rewrite, no `git config` mutation. PowerShell mirror is a follow-up, not a blocker. |
| **UX** | Set once per tank, then invisible — exactly the "quietly help" philosophy. Slight learning curve (a new optional command); zero burden for tanks that don't opt in. Honest framing required (see §5): it pins env-var authorship, not a `-c` override. |

### Option B — Mismatch warning only (detection, no mutation)

Don't change what gets committed. Instead, surface the gap. `clikae status`
(and the board / `--json`) computes "this tank's *intended* identity" vs "the git
identity this shell will actually commit as", and warns when an engine is known to
inject its own account email.

| | |
|---|---|
| **Security** | Weak-to-medium. Detection without prevention — it tells you *after* you might have leaked, and only if you read the warning. A non-interactive / headless run (the exact case the §13 incident was) sees no human to heed the warning. |
| **Implementation cost** | Low–medium. Needs a resolver for "what will this shell commit as" (read `GIT_AUTHOR_EMAIL` → else `git config user.email`) plus a per-engine "known to inject" flag and a tank-intended-identity field. No mutation, so lower blast radius. |
| **UX** | Informational, never blocks. Good as a *complement* to A, poor as the sole fix — it leans on the user noticing, which the incident showed doesn't hold under automation. |

### Option C — Do nothing, document the footgun (status quo)

Leave authorship entirely outside clikae. Document in `docs/troubleshooting.md`:
pin `git config --global user.email`, and never let an engine commit with
`-c user.email=<harness userEmail>`.

| | |
|---|---|
| **Security** | Lowest. Relies wholly on user discipline + global git config. The incident proves an engine can override global config with `-c`, so a pure-doc answer doesn't actually stop the recurrence. |
| **Implementation cost** | Near-zero (a doc paragraph). |
| **UX** | No new surface, no learning curve — but also no protection. clikae stays silent on its most consequential identity axis, which contradicts its "control plane for which identity is active" positioning. |

---

## 4. Recommendation

**Ship Option A as the primary fix, with Option B's mismatch warning folded in as
the cheap second brick.**

Rationale:

- A is the only option that *prevents the next mis-stamp* rather than merely
  describing it. The §13 incident was a headless run with no human in the loop —
  exactly where B's warning is useless and C's "be careful" is empty.
- A is squarely on-thesis: clikae already controls where the engine's
  auth/fuel/memory state lives; git authorship is the most consequential identity
  a coding session emits, and pinning it is the same "control where identity is
  active per session" lever applied to a new axis.
- A is safe by default: no `git config` mutation, no history touch, opt-in per
  tank, fully reversible.
- B is cheap and strictly additive once A's "intended identity" field exists —
  surface the mismatch in `status` so a user who *hasn't* opted into A still gets
  a heads-up. Do B second, not instead.

**Honesty guard (must be in the copy):** clikae can only influence *new* commits.
It cannot fix attribution on existing commits — that requires a history rewrite +
force-push (as was done in §13) and an account-settings change (an email verifies
on one GitHub account at a time). Never claim clikae "fixes attribution"; it
*prevents the next mis-stamp*. Also be explicit that env-var authorship is beaten
by an explicit `git -c user.email=… commit` (§5).

---

## 5. Honest limits (don't oversell)

1. **`git -c user.email=…` still wins.** Git precedence is
   `-c` command-line > `GIT_*` env > `git config`. Option A's env exports beat the
   global-config commit path (the common case) but **not** an engine that commits
   with an explicit per-command `-c user.email=…`. If an engine does that, A
   cannot override it from the parent shell; that case still needs B's warning +
   user/engine-config action. Document this precedence plainly.
2. **Per-shell only.** Like `clikae env`, the exports live in the shell that
   eval'd them; they don't follow the engine into a separately-spawned shell. The
   bare switch / aliases / `.app` run the engine with a prefix assignment, so to
   get git identity onto a long-lived session you `eval "$(clikae env …)"` first
   (same constraint already documented for `env`).
3. **No retroactive fix.** Restated from §4 — clikae touches only future commits.
4. **agy / flag-strategy engines** have no per-shell `env` to ride on. The git-id
   exports can still be emitted by `clikae env` for engines that *have* an env
   path; for agy (global, no per-shell routing) the git-id feature is best-effort
   / out-of-scope in v1, mirroring `env agy`'s existing limitation.

---

## 6. Implementation sketch (Option A + B warning)

Files to touch:

| File | Change |
|---|---|
| `lib/core/profile_store.sh` | Add `git_identity_file <cli> <tank>` (path helper) + `git_identity_read <cli> <tank>` (echo `name<TAB>email` or nothing). Pure path/read helpers, mirroring the existing `profile_dir` family. |
| `lib/commands/git_id.sh` *(new)* | `cmd_git_id <engine> <tank> [--name N --email E | --unset]`. Validates names (reuse `validate_name`), writes/removes the `clikae-meta/git-identity` file under the tank dir. Bare form prints current value. Follows the existing per-command file shape (`env.sh` is the closest model). |
| `lib/commands/env.sh` | After the adapter's `adapter_export_env` loop, if `git_identity_read "$cli" "$tank"` is non-empty, also emit the four `export GIT_AUTHOR_*` / `GIT_COMMITTER_*` lines (quoted via the existing `_env_shquote`). This is the whole of the "exported per-tank identity" behaviour — ~6 lines. |
| `bin/clikae` | Register `git-id` in the §4 reserved-command resolver (`docs/grammar.md`) and route to `cmd_git_id`. Add to `help`. |
| `lib/commands/status.sh` | **Option B brick:** when a tank has a git-identity (or an engine is flagged "injects its account email"), compute "will-commit-as" (`GIT_AUTHOR_EMAIL` ?: `git config user.email`) and show intended-vs-actual, warning on mismatch. Detection only — no mutation. |
| `lib/adapters/_template.sh` + adapters | Optional new meta hook `adapter_meta_injects_git_identity` (default: no) so `status` knows which engines are known to stamp their own email. Claude's adapter can advertise it; others stay silent. |
| `docs/grammar.md` | Add `git-id` to the management-verbs table (§3.3) and the reserved-command list (§4). It is a plain conventional verb (create/inspect tank metadata), not a switching verb — no fuel metaphor. |
| `docs/usage.md` / `docs/troubleshooting.md` | Document the feature + the §5 honest limits (precedence, per-shell, no retroactive fix). The troubleshooting entry doubles as Option C's doc safety-net for tanks that don't opt in. |
| `tests/bats/git_id.bats` *(new)* | Cover: write/read/unset round-trip; `env` emits the four git vars only when the file exists; name validation; absent-file = no git exports (safe default). |
| `powershell/Clikae.psm1` + `Clikae.Tests.ps1` | Mirror (follow-up, not a v1 blocker per the §4 grammar checklist's "where it applies"). |

Sketch of the `env.sh` addition (conceptual):

```sh
# …after the existing adapter_export_env emission loop in cmd_env …
gid="$(git_identity_read "$cli" "$tank")"   # "name<TAB>email" or empty
if [ -n "$gid" ]; then
  gname="${gid%%$'\t'*}"; gemail="${gid#*$'\t'}"
  printf 'export GIT_AUTHOR_NAME=%s\n'    "$(_env_shquote "$gname")"
  printf 'export GIT_AUTHOR_EMAIL=%s\n'   "$(_env_shquote "$gemail")"
  printf 'export GIT_COMMITTER_NAME=%s\n' "$(_env_shquote "$gname")"
  printf 'export GIT_COMMITTER_EMAIL=%s\n' "$(_env_shquote "$gemail")"
fi
```

Conventions to honour (per HANDOFF §4/§7): bash 3.2 compatible, no GNU-isms, quote
everything, shellcheck-clean, no new language dependency, no network/telemetry. The
git-identity file is plain text under `$CLIKAE_HOME` — local-only, auditable.

---

## 7. Open questions for the maintainer

- **Command name:** `clikae git-id` vs `clikae identity` vs folding into
  `clikae init <engine> <tank> --git-name … --git-email …` at create time. (Lean:
  a dedicated `git-id` so existing tanks can adopt it without re-init.)
- **Auto-suggest from the account label?** clikae already reads the AI account
  email via `adapter_account_label`. Should `git-id` *offer* to set the git email
  to match — or deliberately keep them separate (the whole point of §13 is that the
  AI-account email is the *wrong* one to commit as)? Probably: never auto-fill from
  the account label; that's the footgun.
- **Should `status` warn even when no git-identity is set** (pure Option B), for
  the leak-prevention value, or only once a tank opts in? (Lean: warn whenever an
  "injects-its-own-email" engine is active and the resolved commit email differs
  from the global `git config` — that's the highest-signal case.)

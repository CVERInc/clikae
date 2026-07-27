# HANDOFF — clikae

Brief for a fresh contributor (human or AI) picking this project up.

**This file describes the present tense only.** History lives in
[CHANGELOG.md](CHANGELOG.md) (per-release record), [docs/DEVLOG.md](docs/DEVLOG.md)
(the narrative), and `git log`. Nothing here is a trophy case.

---

## 0. The maintenance contract (read before you edit this file)

This document rotted once: it grew to 1089 lines of dated status blocks, kept
`✅ DONE` sections for work shipped months earlier, and its own "READ THIS FIRST"
header was five releases behind. An incoming agent then trusted it. That is the
failure mode this contract exists to prevent.

**Every line in this file is exactly one of three things:**

| Kind | Meaning | Lifecycle |
|---|---|---|
| **LIVE RULE** | A constraint that still binds today | Stays until the constraint stops being true |
| **OPEN** | Known, unsolved, and someone will have to deal with it | Deleted in the same commit that closes it |
| — | Anything else | **Does not belong here** |

Rules:

1. **Closing an OPEN item means deleting its entry**, in the same commit as the
   fix. Do not rewrite it as `✅ DONE`. CHANGELOG records the ship; git records
   the reasoning; this file records only what is still true.
2. **Never write a status block dated to today** ("Current state as of …",
   "shipped tag: vX.Y.Z", "bats currently green at N"). Those decay silently and
   are indistinguishable from fact when stale. Write **how to check** instead:
   `clikae --version`, `bash scripts/test.sh`, `git log`.
3. **Before trusting any claim in here, verify it in code.** If you find a
   mismatch, fix the file first, then continue. A wrong handoff is worse than no
   handoff.
4. **Do not restate what a SSOT already owns.** Point at it:
   `docs/VISION.md` (positioning), `docs/grammar.md` (command surface),
   `docs/memory.md` (Soul), `docs/orchestration.md` + `docs/playbooks.md`
   (headless dispatch), `AGENTS.md` (driving clikae as an agent).
5. **Never cite this file by section number** from code comments or other docs.
   Sections move; the citation dangles and the next reader can't tell whether the
   claim died or just relocated. Make the comment self-contained, or name the
   thing (`clikae_is_target`, the BSD-sed footgun) instead of a `§`.
6. **When a behaviour changes, grep the whole doc tree for the old claim.** The
   2026-07-27 audit found *four* documents still saying agy couldn't be `burn`ed
   ten releases after `clikae burn agy <tank>` shipped — including `AGENTS.md`,
   two lines above a link to the page that corrected it. One doc gets updated at
   ship time; its siblings quietly become liars. The fix is a grep, not a memory.
7. **A finished plan is not a document.** `PLAN.md` and
   `docs/HANDOFF-world-class-gaps.md` were both deleted on 2026-07-27: each had
   declared itself shipped/cleared at the top and then sat in the repo for weeks
   where an incoming agent would read it as live work. If a plan is done, `git rm`
   it — `git log` is the archive.

---

## 1. What clikae is

A small, auditable bash CLI that keeps **your half** of AI CLI work portable —
who you are, what you know, where you left off — across accounts and engines.
Bare `clikae` opens a board of your recent sessions; picking one puts you back on
the right account, session, and directory.

**`docs/VISION.md` is the SSOT for positioning.** Read it before writing any
user-facing copy. Note in particular that clikae is *deliberately not* framed as
an "account switcher" — switching accounts is incidental to never losing your
place.

Vocabulary: **engine** = a managed CLI (claude, codex, agy…). **tank** = one
account/config for that engine. **fuel** = that account's quota. clikae is the
verb. Full grammar: `docs/grammar.md`.

Repo: `~/Developer/clikae/`. MIT. Unofficial community tool, not affiliated with
any CLI vendor.

---

## 2. LIVE RULES — non-negotiable

### 2.1 Toward the user's machine

1. **Check, then act.** Every destructive step (rm, edit shell rc, overwrite
   `.app`) verifies preconditions and stops with a clear message on anomaly.
2. **Back up before editing user files.** Shell rc edits leave
   `*.clikae.bak.<timestamp>`. The user must always be able to undo by hand.
3. **Sentinel-wrap anything written into user-owned files** —
   `# >>> clikae:<id> >>>` … `# <<< clikae:<id> <<<` — so `clikae remove` can
   clean up reliably. Don't change the format without a migration path.
4. **Never log in for the user.** OAuth/password flows are theirs.
5. **Never touch system files.** Only `~/.clikae/`, the user's shell rc, and
   (with `--out`) `~/Applications/`.
6. **If anything is unexpected, stop and report.** Don't paper over errors.
7. **No silent telemetry. Ever.** No daemon, no network calls beyond the one
   opt-out update check.
8. **When a destructive path degrades, say so on the row.** `clean` falls back
   to `rm` when the Trash is unusable; that fallback must always announce
   itself — and it must never do something MORE destructive than it announced: `clean` refuses rather than falling back to a delete.

### 2.2 Code

- **bash 3.2 compatible** (macOS ships 3.2). No `mapfile`, no `${var,,}`.
- **No GNU coreutils-isms.** BSD `sed`/`awk`: `sed -i ''` on macOS vs `sed -i` on
  Linux → prefer `awk` or write-to-tempfile-then-`mv`
  (`lib/core/shell_rc.sh:rc_remove_block`). No `readlink -f`.
  BSD `sed` also strips backslashes from the replacement — `clikae app` was
  broken by exactly this once; substitute via bash parameter expansion instead.
- **`set -eo pipefail`** at the top of standalone scripts. **Never `set -u`** —
  it has burned this project and causes surprises in interactive flows.
- **Quote everything.** Paths contain spaces.
- **Keep the modular layout** (`bin` + `lib/commands` + `lib/core` +
  `lib/adapters`). One file per adapter is the contribution story.
- **Don't re-inline the shared helpers.** Each exists because the same logic was
  duplicated once already: `adapter_command` / `adapter_env_prefix`
  (`adapter_loader.sh`), `rc_wrap_block` (`shell_rc.sh`),
  `resolve_active_profile` (`profile_store.sh`), `live_dir_users` (`proc.sh`),
  `_home_lpad` (display-width padding, CJK-safe).
- **No Python or Node dependency.** The pitch is "every line is auditable bash".
- **Template footgun:** a template's comments must not contain a literal
  `@TOKEN@` with the `@` delimiters, or `${//}` substitution mangles the comment.

### 2.3 Classification

**`clikae_is_target` (`lib/core/profile_store.sh`) is the canonical predicate.**
Never classify an engine by "an adapter file exists" — `antigravity` has a
deliberately thin, resume-only adapter shim while remaining a launch-only
TARGET. Reading adapter-file presence instead of target-ness caused 11
regressions in one sitting. Classification code reads target-ness first.

### 2.4 Verification

- **Never verify bats through a pipe.** `bats | tail; echo $?` reports *tail's*
  exit code, not bats'. See `tests/README.md`.
- **Judge headless work by the artifact, never the exit code.** `codex exec`,
  `claude -p` and `agy -p` all exit `0` even when they hit a usage limit, or
  declined, and wrote nothing. Two refinements learned on 2026-07-27, both of
  which cost a shipped bug:
  - **Prefer a structured marker to the vendor's sentence.** codex writes
    `codex_error_info: usage_limit_exceeded` into its rollout; matching that,
    not the English around it, is what survives the copy being reworded.
  - **A PRESENT artifact is not proof either.** When clikae writes the artifact
    on an engine's behalf (agy, whose headless mode may not write your paths),
    whatever the engine printed lands in the file — including "I declined". burn
    now treats agy's own `no output produced` as a failure for exactly this
    reason, and its success line says CAPTURED, not verified.
- **Never print token prefixes** when diagnosing credentials. Print field
  *presence* only. The claude OAuth token lives in the login Keychain under
  `Claude Code-credentials-<sha256(CONFIG_DIR)[:8]>`, not in `CLAUDE_CONFIG_DIR`.
- **A green local gate is NOT a green build. Go look at CI.** `scripts/test.sh`
  is one OS, a narrower scan, and no matrix; CI is two runners and scans the whole
  tree. Three releases shipped on 2026-07-27 with CI red the whole time, because
  the pre-push hook was green and nobody looked. Check the run — especially any
  job you added yourself, which by definition you have never watched pass.
- **The gate lints itself.** It didn't until 2026-07-27, and the one file it never
  checked was the one that broke: a comment beginning `# shellcheck ` parses as a
  directive. Anything added to the gate must stay inside the gate's own scope.
- **`bash scripts/test.sh` is the gate** — shellcheck at `warning` + bats. It is
  what CI runs. See §6 for what the gate does *not* cover.

### 2.5 Board visual language — LOCKED with the maintainer, do not regress

- **Three sections: Tanks / Solo / Resume** (plus "Also available"). A *section*
  is the badge — solo tanks live in their own block, never a per-row icon.
- **No emoji on the board.**
- **Soul-sharing is not shown inline.** In a fleet, a shared brain is the normal
  state; it isn't worth shouting.
- **Aligned columns**: dot · name · engine · account, display-width padded
  (`_home_lpad`, CJK-safe). Resume rows use the same columns.
- **No "current shell" marker.** With many tanks open it is noise; `active` is
  still computed for the launch hint and relay source, just not drawn.

### 2.6 Locked values elsewhere

- **Soul / memory** — a machine that never opted in shares nothing; after the
  first `share` the fleet shares by default and `solo` is the way out; crossing to
  a different account is always announced; aggregate-never-mutate-the-source; no phantom continuity (a
  Soul carries context, not the model's capability). SSOT: `docs/memory.md §4`.
- **`clikae solo`** walls a tank out of the fleet: skipped by burn/watch/`to`,
  and `memory share` refuses it. `claude/MFC` is solo and must stay that way.
- **agy quota is PER-ACCOUNT and stacks — unless the accounts share a Google
  family plan, which pools them.** Measured 2026-07-27, three signed-in tanks
  read 34.14% / 100% / 100% weekly. State the family caveat whenever the
  stacking is mentioned; it is the whole reason this looked unresolved for
  months.

### 2.7 Windows / PowerShell

`powershell/` is an **unsupported community port**. Its pester CI job is
`continue-on-error` and never blocks. Do not spend effort syncing it to the
grammar.

**But:** `tests/bats/compat.bats` — a *blocking* gate that greps source and never
runs pwsh — asserts that `$script:ClikaeAdapters` in `powershell/Clikae.psm1`
mirrors `lib/adapters/*.sh` on binary/env-var/strategy, in both directions.

So adding a **switchable** adapter (`env-dir` / `env-file` / `env-var` / `flag`)
requires adding the matching PS table row, or the bash suite goes red. A
**`subcommand`-strategy** adapter does not: that strategy marks a capability shim
on a launch-only target rather than an env-switchable engine (`antigravity`'s
resume hook is the only one), and the test skips it deliberately. This is why the
bash tree has 14 adapter files and the PS table correctly has 13.

(The old handoff asserted "keep them in sync" in one place and "don't spend effort
syncing" in another; this is the reconciled version.)

---

## 3. OPEN

Ordered by what would hurt most if ignored. Delete an entry when you close it.

### OPEN-1 — FLEET self-logout via a refresh-token race (NOT clikae's to fix)

**The mechanism.** Claude's OAuth uses **rotating** refresh tokens: each refresh
issues a new one and invalidates the old. When several sessions on one tank
refresh near-simultaneously, the loser refreshes with a now-stale token, gets
`invalid_grant`, treats it as "I'm logged out", and **clears the Keychain entry
the winner just wrote**. One small race becomes a whole-tank logout with no
silent recovery — only a fresh interactive `/login`.

Evidence from the 2026-06-29 incident: `profiles/claude/L/daemon.log` showed days
of `auth: proactive refresh succeeded`, then `proactive refresh failed,
signalling re-auth required` → `no token found`; **17×** `token still valid
(cross-process refresh or not yet due)` proves multi-process refresh is the
NORMAL state on that tank, so the race is structural, not exotic.

**🔴 Correction, 2026-07-27 — the recorded fix cannot be implemented here.** This
entry used to carry a four-point plan ("daemon owns refresh, single-flight via
`flock`"; "`invalid_grant` must never clear credentials"; "keep proactive refresh
daemon-exclusive") and read as ready-to-build. Every one of those points
describes **Claude Code's** auth daemon. clikae owns no daemon at all — the word
appears in this codebase only in `proc.sh`, where it *detects* Claude's
background workers — and growing one would break a non-negotiable (no daemon, no
network calls). Anyone picking this up on the old text would have spent a day
before noticing. Don't.

**What clikae can do, and has.** The daemon's log lives inside the tank clikae
manages, so the *aftermath* is readable even though the mechanism isn't ours:
`clikae doctor` now names a tank left signed out by a refresh failure, with the
timestamp and the one-line fix, instead of leaving a working account's sudden
death a mystery. It also reports whether each tank has a saved login at all.

**Still open, and it's a decision, not a task:** whether to take this upstream
(the amplifier — treating `invalid_grant` as "clear the credentials" rather than
"re-read, a sibling may have just refreshed" — is a real bug worth reporting),
and whether clikae should discourage the condition at all, e.g. by noticing you
are opening an Nth concurrent session on one tank. The latter is unattractive:
FLEET is a first-class supported pattern here, and warning about it every time
would nag about the thing the tool is for.

**Honest limit — don't oversell in copy.** Multiple *machines* on one account
still evict each other; rotation is server-side. A single machine cannot fix
that, so a dropped tank should be worded "may have been rotated out by another
machine" rather than implying the account broke.

### OPEN-2 — Soul Phase 4, the two thirds still parked (not debt)

Phases 0–3 are done (structure; claude share; codex/agy pointer). Of Phase 4:

- **(b) a per-person default — SHIPPED 2026-07-27.** The gate fired in the most
  useful way possible: the maintainer described the model back as *"everything in
  a tank shares `me` unless I solo it"* — which was the board's story and the
  docs' story, but not the code's, where sharing was opt-in per tank and a new
  tank silently started with no brain. The mental model had walked ahead of the
  implementation, which is a stronger signal than any observation. Consent is now
  once per machine, `solo` is the single way out, and the board names a fleet tank
  that has no brain.
- **(a) the per-ENTRY scope dial** and **(c) conduct/burn waking the cheapest
  sufficient brain with Soul context** are still parked, and the evidence still
  points that way: a session doing customer work on one site read the whole
  business brain and the sharing made its answer *better* — it stopped guessing at
  a platform limit and asked the person who owns the platform.

**Do not build (a) or (c) until something actually wants them.** This is a park,
not an unfinished obligation. The thing that would open the gate is a moment where
you want one FILE out of the brain, not one tank.

### OPEN-3 — the iTerm2 launcher template is unverified (and self-closing)

- **`clikae app`'s iTerm2 template is unverified, and now says so by skipping.**
  AppleScript resolves an app's terminology from that app's own dictionary, so a
  template written in iTerm2's vocabulary can only be COMPILED on a machine that
  has iTerm2 — which is why this never got checked here. It is not a reason to
  drop iTerm2: the path is gated on the app being installed, so the only machine
  that runs it is one where the dictionary resolves, and a bad template would
  fail loudly at `osacompile` rather than yield a broken `.app`. There is now a
  test that compiles each launcher template and SKIPS the iTerm2 one when iTerm2
  is absent, so the first person who has it verifies it for everyone. (Warp is a
  decided non-target, not a gap — `--terminal warp` explains why; default-terminal
  detection shipped 2026-07-27.)

---

## 4. The adapter contract

Every `lib/adapters/<cli>.sh` defines (strings via `echo` unless noted):

| Function | Required? | Purpose |
|---|---|---|
| `adapter_meta_name` | yes | Human-readable name |
| `adapter_meta_cli_binary` | yes | Binary to invoke |
| `adapter_meta_env_var` | yes | Primary env var |
| `adapter_meta_strategy` | yes | `env-dir` \| `env-file` \| `env-var` \| `flag` \| `subcommand` |
| `adapter_meta_description` | yes | One-line description |
| `adapter_export_env <dir>` | yes | Print `KEY=VALUE` lines |
| `adapter_run <dir> [args]` | yes | `exec` the CLI with profile env applied |
| `adapter_init <dir>` | optional | Seed the dir on `clikae init` |

Optional hooks that unlock behaviour rather than existence:
`adapter_start_with_prompt` (this is what marks an engine as *AI* — the new-tank
picker classifies on the presence of this definition **in the file**, since
`load_adapter` provides a default stub at runtime), `adapter_relay`,
`adapter_transcript_path`, `adapter_account_label`, `adapter_migrate_credentials`,
`adapter_memory_dir` / `adapter_memory_pointer_path`, `adapter_flag_args`.

Boilerplate: `lib/adapters/_template.sh`. Reference implementation:
`lib/adapters/claude.sh`. Full guide: `docs/adding-an-adapter.md`.
The alias/`.app` command line is assembled centrally in `adapter_command`
(env prefix + binary + flag suffix) — don't re-inline it.

Adding an adapter also means adding its row to `powershell/Clikae.psm1` — see
§2.7 for why, despite Windows being unsupported.

---

## 5. Honest limits to preserve in copy

Carry these forward whenever the relevant feature is described. Each was learned
the expensive way.

- **The in-use guard** (`live_dir_users`, wired into rename/migrate/remove)
  catches "a session is open right now" — the overwhelming case — but not a
  check-then-open race, and its daemon-vs-interactive split is a command-string
  heuristic.
- **Cross-machine token eviction** is an OAuth fact clikae cannot fix (OPEN-1).
- **agy cannot be a handoff SOURCE** — its sessions are opaque `.pb`. Alert and
  re-dispatch; never promise a session carry off agy.
- **Interactive Claude Code gives no usage-limit signal** — it does not exit,
  returns no exit code, and fires no hook. Silent mid-session interactive
  auto-switching is not reliably possible; detect-and-offer is. Don't
  re-litigate this.
- **clikae can only prevent the *next* git mis-stamp**, never re-map old commits.
  Per-tank git identity ships (`clikae git-id`; `clikae env` exports
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*`), and it is opt-in by design — the safe
  default is to inherit global config, not to hijack `git config`.
- **`clikae env` is per-shell.** Automation must set the tank inline in the same
  command; it does not persist across separate non-interactive shells.

---

## 6. How to verify your changes

```bash
bash scripts/test.sh    # the gate: shellcheck -S warning + bats + pty smoke
```

Three legs, because the first two are structurally blind to the TUI: shellcheck
reads source, bats never presses a key. `tests/tools/pty-smoke.py` drives the real
binary on a real pty in a throwaway `$HOME`, and it gates — locally and in CI.
Run one leg directly while iterating:

```bash
python3 tests/tools/pty-smoke.py prompts   # prompts + the launched engine's stderr
```

Verified on ARM64 Linux (a PineNote over SSH, 2026-07-27): the whole bats suite
and all three pty-smoke modes pass there, including the launched engine keeping
its stderr. CI is x86 ubuntu, so that is a signal CI cannot give — if you have
non-x86 hardware, running the gate on it is a cheap and genuinely useful report.

What the gate still does **not** cover — check by hand when you touch these:

- **The `clean` picker's destructive path.** pty-smoke never confirms a deletion.
- **The real engines.** Adapter tests and pty-smoke both stub the binaries.
- **agy.** One global Keychain login; nothing about it is safely automatable.

🔴 **A new interactive assertion must be proven able to fail.** Put a pre-fix
commit in a `git worktree`, copy the harness in, and watch the check go red. An
assertion that passes on the broken code is decoration — when this net was added,
three of its eight checks passed on the buggy build and only five were real.

Isolated end-to-end without touching your real `~`:

```bash
TMP=$(mktemp -d)
HOME="$TMP" CLIKAE_HOME="$TMP/.clikae" ./bin/clikae init claude work --alias
HOME="$TMP" CLIKAE_HOME="$TMP/.clikae" ./bin/clikae list -p
HOME="$TMP" CLIKAE_HOME="$TMP/.clikae" ./bin/clikae remove claude work --force
rm -rf "$TMP"
```

Lint workflow edits with `actionlint .github/workflows/ci.yml`.
Run bats with `-r` so `tests/bats/adapters/` is included — without it bats does
not recurse into that subdirectory and silently skips the adapter tests.

CI installs bats by **cloning `bats-core`**, not `npm i -g bats` — the latter
hits `EACCES` on the ubuntu runner's global npm prefix and exits 243. Don't
"simplify" that step.

---

## 7. Release recipe

1. Bump `CLIKAE_VERSION` in `bin/clikae`.
2. Move CHANGELOG `[Unreleased]` → `[X.Y.Z] — <date>`; add a fresh
   `[Unreleased]`.
3. Commit, `git tag -a`, push commit **and** tag, `gh release create`.
4. `curl -sL` the **GitHub-generated** tarball, `shasum -a 256` it, and bump
   `url` + `sha256` in **both** `homebrew/clikae.rb` (in-repo) **and** the tap
   repo's `Formula/clikae.rb` (`CVERInc/homebrew-clikae`). The sha must come from
   GitHub's tarball, not `git archive`.
5. Verify: `brew fetch/style/audit CVERInc/clikae/clikae`.

`git pull` the local tap clone first — it has been found a release behind.
Exact commands: `homebrew/RELEASING.md`.

---

## 8. Quick reference

| Thing | Where |
|---|---|
| Repo root | `~/Developer/clikae/` |
| Tank store | `~/.clikae/profiles/<engine>/<tank>/` (override: `$CLIKAE_HOME`) |
| Souls | `$CLIKAE_HOME/souls/<group>/memory` + `PROTOCOL.md` + `members` |
| Shell rc | auto-detected `~/.zshrc` / `~/.bashrc` / `~/.bash_profile` / `~/.profile` / fish |
| `.app` launchers | `~/Applications/<engine> (<tank>).app` |
| Backups | `<rc-file>.clikae.bak.<timestamp>` |
| Logs | none — errors go to stderr |
| CI | `.github/workflows/ci.yml` — shellcheck, smoke ×2, bats ×2, pty-smoke ×2, pester (windows, non-blocking) |
| Positioning SSOT | `docs/VISION.md` |
| Command surface SSOT | `docs/grammar.md` |
| Soul SSOT | `docs/memory.md` |
| Headless dispatch | `docs/orchestration.md` · `docs/playbooks.md` · `AGENTS.md` |

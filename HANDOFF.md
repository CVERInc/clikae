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
   itself. (See OPEN-1 — today that announcement is swallowed.)

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
- **Judge headless work by the artifact, never the exit code.** `codex exec` and
  `claude -p` exit `0` even when they hit a usage limit and wrote nothing. The
  reliable signals are the limit string in the output and a missing artifact.
- **Never print token prefixes** when diagnosing credentials. Print field
  *presence* only. The claude OAuth token lives in the login Keychain under
  `Claude Code-credentials-<sha256(CONFIG_DIR)[:8]>`, not in `CLAUDE_CONFIG_DIR`.
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

- **Soul / memory** — account isolation is sacred (opt-in, per-tank, never
  auto-crossed); aggregate-never-mutate-the-source; no phantom continuity (a
  Soul carries context, not the model's capability). SSOT: `docs/memory.md §4`.
- **`clikae solo`** walls a tank out of the fleet: skipped by burn/watch/`to`,
  and `memory share` refuses it. `claude/MFC` is solo and must stay that way.
- **agy quota: do not claim it stacks, and do not claim it doesn't.** See OPEN-6.

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

### OPEN-1 — `exec … 2>/dev/null` permanently kills stderr in three commands

**Found 2026-07-27.** `exec` without a command makes its redirections permanent
for the shell. Three code paths open a `/dev/tty` fd with `2>/dev/null` attached,
which silently points that process's stderr at `/dev/null` for the rest of its
life:

| Site | Scope |
|---|---|
| `lib/commands/home.sh:1566` | the whole board process |
| `lib/commands/resume.sh:360` | the whole `clikae resume` run |
| `lib/commands/clean.sh:782` | the whole `clikae clean` run |

(`lib/commands/relay.sh:43` uses the same idiom but runs inside a command
substitution, so its damage is contained. Fix it anyway — it's a loaded gun.)

Verified consequences:

- **An engine launched from the board loses its entire stderr.** Pressing Enter
  on a row execs through to `claude`/`codex`/`agy`, which inherits fd 2 =
  `/dev/null`. Crashes, node warnings, OAuth errors, "command not found" — all
  discarded. `clikae claude <tank>` run directly from the shell is unaffected.
  Confirmed with a stub engine writing to both streams.
- **`clean`'s Trash-fallback disclosure is guaranteed silent.** `_clean_to_trash`
  falls back to `rm` (permanent) when the Trash is unusable, and
  `CLEAN_TRASH_FELL_BACK` exists solely so the caller can say so — via
  `log_warn`, i.e. stderr. In the interactive path that warning can never
  appear. This breaks LIVE RULE 2.1.8.
- **Three `read -rp` prompts are invisible** (bash writes `-p` prompts to
  stderr), which reads as a hang: `home.sh:1211` (`n` new tank — the symptom
  that surfaced this), `home.sh:1055`/`1058` (`a` rename), `home.sh:1542`
  (`m` memory group).
- **Every `log_err`/`log_warn`/`log_fail` in a board-launched subcommand is
  muted**, including `init`'s "Tank already exists" — a typo'd name fails with
  no output at all.

Fix is to split the redirections: open the fd, and handle failure without
attaching `2>/dev/null` to the `exec`.

### OPEN-2 — the gate cannot see any of OPEN-1

`bash scripts/test.sh` passes clean — shellcheck at `warning` and the entire bats
suite — with all of OPEN-1 shipped. Neither tool can observe interactive TTY
behaviour, so neither ever will catch this class.

`tests/tools/pty-smoke.py` exists for exactly this — its docstring names "the
smoke layer bats can't reach … exactly where the board regressed in dogfood more
than once" — but:

1. **Nothing invokes it.** Not `scripts/test.sh`, not `.github/workflows/ci.yml`.
   It self-describes as "a developer tool, not CI".
2. **It deliberately only sends navigation/cancel/quit keys**, never Enter on a
   row and never `n`/`a`/`m`/`d`. Every bug in OPEN-1 lives in the keys it skips.

The harness built to catch this class of regression stops one keystroke short of
it and isn't run. Wiring it in — and letting it press the mutate keys against a
sandbox `CLIKAE_HOME` — is the durable fix.

### OPEN-3 — FLEET self-logout via OAuth refresh-token stampede

**Found 2026-06-29 diagnosing a real incident. Fix decided, not implemented**
(there is no `flock` anywhere in the tree — verified 2026-07-27).

FLEET here means *multiple concurrent sessions burning the same tank* — one
person, their own account, many parallel sessions.

Claude's OAuth uses **rotating** refresh tokens: each refresh issues a new one
and invalidates the old. When N sessions on one tank refresh near-simultaneously:

1. Process A refreshes `RT0` → gets `RT1`, writes it to the Keychain. ✅
2. Process B, a few hundred ms later, refreshes with the now-stale `RT0` →
   `invalid_grant`.
3. **B treats `invalid_grant` as "logged out" and clears the Keychain entry**,
   wiping the good `RT1` A just wrote.
4. The daemon's next proactive refresh finds nothing → `auth_required`.

With both tokens cleared there is no silent recovery — only a fresh interactive
`/login`.

Evidence from the incident: `profiles/claude/L/daemon.log` shows days of
`auth: proactive refresh succeeded`, then `proactive refresh failed, signalling
re-auth required` → `no token found`; **17×** `token still valid (cross-process
refresh or not yet due)` proves multi-process refresh is the *normal* state on
that tank, so the race is structural, not exotic. Observed refresh round-trip
~6.3s.

The decided fix (keep it simple — FLEET is not a frequent state):

1. **Daemon owns refresh, single-flight via `flock`** on a lockfile in the tank's
   config dir. Sessions only READ the Keychain; on a 401 they ask the daemon and
   retry. Exactly one actor rotates the single-use token.
2. **`invalid_grant` must never directly clear credentials.** Take the lock,
   re-read the Keychain, adopt a fresher token if a sibling already refreshed;
   escalate to `auth_required` only after confirming none exists. This alone
   defuses the amplifier.
3. **Keep proactive refresh, but make it daemon-exclusive — do not switch to
   lazy.** Lazy would make N cold-starting sessions all 401 at once and each eat
   the ~6.3s latency. The disease was "proactive done by many", not "proactive".
   Lock only the critical section; serve-stale-while-revalidate.
4. **Not doing: daemon-death failover.** Considered and rejected; revisit only if
   daemon OOM under FLEET proves common.

**Honest limit — don't oversell in copy.** Multiple *machines* on one account
still evict each other; rotation is server-side. clikae can only make one
machine's concurrent sessions safe, and word a dropped tank as "may have been
rotated out by another machine" rather than implying the account broke.

### OPEN-4 — `clikae <typo>` exits 0

An unrecognised first argument logs an error to stderr, prints the full help, and
**returns 0** (`bin/clikae`, the unknown-command fallback). Scripts cannot detect
a typo. Inconsistent with the rest of the surface — `clikae mcp status` returns 1.
Compounded by OPEN-1 when invoked from the board.

### OPEN-5 — new-tank picker: broken preselect, duplicated engine

- **Preselect never matches.** `_home_choose` compares the caller's bare engine
  name (`codex`) against the annotated option string (`"codex  (AI)"`), so the
  cursor always lands on the first row regardless of which tank you pressed `n`
  from. Verified.
- **`agy` and `antigravity` are listed as two separate engines** in
  `_home_newtank_choices`, one of them tagged `(tool)`, though `cmd_init` routes
  both to `_agy_init`.

### OPEN-6 — agy: login isolation proven, quota stacking unresolved

**Login isolation is real and solid.** The `_agy_kc_*` Keychain carry holds two
distinct Google accounts per tank (service `gemini`, account `antigravity`;
verified by hash comparison and `cli.log applyAuthResult: email=…`).

**Quota is the open question.** The only hard fact is that agy's `/usage` shows
*byte-identical* figures for two different accounts. That proves the **display**
is identical, not that consumption is shared. Two live readings: (a) Google sells
per-account tiers, so a literal global pool contradicts the paid product; (b) the
identical display is most likely a preview artifact, which would mean quota does
stack and the UI simply doesn't show it.

**Only a burn-test settles it** (maintainer, real terminal): record each
account's weekly %, burn one account's weekly down meaningfully, then re-check
the other — unchanged ⇒ per-account, drops too ⇒ shared. Until then **docs must
claim neither direction**. Independent of quota, agy's honest positioning is a
*breadth* leg (one entry → Gemini + Claude + GPT-OSS); the binding burst
constraint is the 5-hour window regardless.

### OPEN-7 — `clikae auto` is claude-only

Auto-carry on a dry tank is BETA and claude-only. codex and agy cannot carry
themselves onward. codex dry-detection now exists (`lib/core/limit.sh` parses the
limit string), so extending `auto` to codex is no longer blocked on detection.

Related, still unbuilt: **auto-relay of a dropped parallel task.** When one tank
in a parallel burn dries, re-queueing *that specific task* to a live tank needs
the orchestrator to track a task↔tank map. `to`/`relay` carry a *session*; this
is a *headless task* — a different shape, a pool/scheduler concern. Encourage
idempotent, artifact-verified tasks so a dropped one can simply re-fire.

### OPEN-8 — Soul Phase 4 (PARKED, dogfood-gated — not debt)

Phases 0–3 are done (structure; claude share; codex/agy pointer). Phase 4 =
(a) a per-**entry** scope dial (`share|isolate|evaporate` on a single memory
file, vs today's whole-tank share); (b) a per-person default + per-area override
policy; (c) conduct/burn integration so the orchestrator wakes the
cheapest-sufficient brain *with* the shared Soul context.

The plan gates this behind living in Phase 1 first. **Do not build Phase 4 until
the `me` group has been used long enough to prove its shape.** This is a park,
not an unfinished obligation.

### OPEN-9 — smaller known gaps

- **`clikae app`**: Warp is unsupported (no clean command-launch story), and
  there is no default-terminal auto-detection. `--terminal terminal|iterm2|ghostty`
  covers the rest. **The iTerm2 template has never been machine-verified** —
  iTerm2 isn't installed on the maintainer's Mac; it is one template file if it
  needs tweaking.
- **agy Keychain coordinates are never verified by CI.** `antigravity.bats` stubs
  `security`, so the copy mechanics are tested but the service-name assumption
  (`gemini`/`antigravity`) is only ever confirmed by live dogfood. A read-only
  `clikae doctor` keychain-coordinate check is the suggested permanent guard.
- **The board's `?` help overlay omits `R`.** `R` opens the full cross-tank resume
  picker (`home.sh`, the key loop) but `_home_help_overlay` never lists it, so the
  one screen whose job is "here are all the keys" is missing one. Every other bound
  key is there. (Docs list it; the in-app legend doesn't.)
- **Engine naming is inconsistent across surfaces.** `clikae list` says `agy`,
  `clikae doctor` says `antigravity`, and `clikae list --json` emits
  `"cli":"agy"` alongside `"path": …/profiles/antigravity/…` — so a consumer
  joining `cli` to `path` breaks.
- **`docs/DEVLOG.md` stops at v0.6.0** (2026-06-14). It is explicitly a
  history, so it is not wrong — just silent about everything since, including
  the Soul layer and the 2026-07-11 repositioning.

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
- **Cross-machine token eviction** is an OAuth fact clikae cannot fix (OPEN-3).
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
bash scripts/test.sh          # the gate: shellcheck -S warning + bats
```

What the gate does **not** cover — check by hand when you touch these:

- Anything interactive: the board, the resume picker, the clean picker. See
  OPEN-2; `python3 tests/tools/pty-smoke.py home|resume` is the closest tool.
- stdout-vs-stderr behaviour of any prompt or warning.
- The real engines. Adapter tests stub the binaries.

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
| Logs | none — errors go to stderr (see OPEN-1) |
| CI | `.github/workflows/ci.yml` — shellcheck, smoke ×2, bats ×2, pester (windows, non-blocking) |
| Positioning SSOT | `docs/VISION.md` |
| Command surface SSOT | `docs/grammar.md` |
| Soul SSOT | `docs/memory.md` |
| Headless dispatch | `docs/orchestration.md` · `docs/playbooks.md` · `AGENTS.md` |

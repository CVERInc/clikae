# HANDOFF — clikae

This document briefs a fresh AI coding assistant (or human contributor) on how to continue this project. Read it end-to-end before changing anything.

---

## 0. What this project is

**clikae** (ｷﾘｶｴ, 切り替え — "switching") is a small bash CLI that lets one person juggle multiple accounts/configs for any CLI tool that uses an environment variable for its settings (e.g. `CLAUDE_CONFIG_DIR`, `GH_CONFIG_DIR`, `KUBECONFIG`).

It does three things per profile:

1. Creates an isolated config directory at `~/.clikae/profiles/<cli>/<profile>/`.
2. Optionally writes a sentinel-wrapped shell alias to the user's shell rc (`<cli>-<profile>`, e.g. `claude-work`).
3. On macOS, optionally generates a double-clickable `.app` launcher that opens Terminal with the right env vars and a custom window title.

The repo is at `~/Developer/clikae/`. License: MIT. It's labelled as an unofficial community tool (not affiliated with Anthropic or any CLI vendor).

---

## 1. Working principles (NON-NEGOTIABLE)

These mirror how this project was built and must be preserved:

1. **Check, then act.** Every destructive step (rm, edit shell rc, overwrite .app) must verify preconditions and stop with a clear message on anomaly. Never silently overwrite the user's data.
2. **Back up before editing user files.** Shell rc edits create `*.clikae.bak.<timestamp>`. The user must always be able to undo by hand.
3. **Sentinel-wrap any block you write into user-owned files.** Use the existing `# >>> clikae:<id> >>>` … `# <<< clikae:<id> <<<` pattern so `clikae remove` can clean up reliably.
4. **Never log in for the user.** OAuth / password flows are theirs. Never type credentials, never auto-accept terms.
5. **Never touch system files.** Only `~/.clikae/`, the user's shell rc, and (with `--out` override) `~/Applications/`.
6. **If anything is unexpected, stop and report.** Don't paper over errors. Don't try alternate approaches without asking the user.
7. **No silent telemetry. Ever.**

---

## 2. Status — last tag `v0.4.0` (SHIPPED 2026-05-30)

> **⭐ READ FIRST (2026-06-01): the fuel-tank grammar landed on
> `feat/relay-and-status`** (committed, not pushed). clikae is now **the verb** —
> `clikae <engine> <tank>` is the bare switch (no `run`), `clikae to <target>`
> carries a session onward (merges relay+handoff), `clikae tanks` lists, and agy
> folds into the same verbs (`init agy`/`agy <tank>`/`remove agy`/`agy --release`,
> no subcommand tree). Vocabulary is **engine/tank/fuel** everywhere (disk
> `profiles/` + core fn names unchanged). **`docs/grammar.md` is the SSOT** for all
> of this — read it before touching the command surface; §10 holds the open
> "memory control plane" frontier (share/isolate/evaporate + a local-model
> translator). bats **200/200**, shellcheck clean. The prose below predates this
> and describes the relay/status/app work it's built on; still accurate as history.
>
> Resolved since: ✅ **`feat/agy-limit-detection` merged** (`bd05f75`); ✅ **bats
> hardened** so every assertion counts (`set -e` + `|| false` on `[[ … ]]`, see
> `tests/README.md`); ✅ **Windows is now community/unsupported** — clikae is a
> macOS/Linux bash tool, the PowerShell module is an unsupported community port
> (its CI job is `continue-on-error`, never gates), so **don't spend effort
> syncing PS to the grammar**. Still open (needs a greenlight, not a guess):
> **implement** any §10 memory mode (ephemeral / per-`to` injection / canonical —
> designed + ship-order agreed, not yet built).

> **UNRELEASED work on branch `feat/relay-and-status` (not yet tagged).** Two new
> commands landed since v0.4.0, fully bats-covered (suite now **83 tests**, was
> 71) and shellcheck-clean at `warning`:
>
> - **`clikae relay <cli> [<from>] <to>`** — the headline. Hand a live session to
>   another profile and keep going on *its* quota (clikae's origin story: a second
>   account exists because one runs out mid-task). New optional adapter hook
>   `adapter_relay <from_dir> <to_dir>` in `lib/adapters/claude.sh`: it slugs `$PWD`
>   the way Claude Code does (`[^A-Za-z0-9]`→`-`), finds the current dir's most
>   recent `projects/<slug>/<id>.jsonl` transcript under the source profile, copies
>   it into the target profile, and `exec`s `claude --resume <id>` under the target
>   `CLAUDE_CONFIG_DIR`. Non-destructive (copy, never move). Adapters without the
>   hook fall back to a plain start under the target. `cmd_relay` auto-detects
>   `<from>` from the live env var when only the target is given.
>   **⚠️ NEEDS REAL-CLAUDE DOGFOOD:** the resume path was verified with a stubbed
>   `claude` binary (transcript copy + correct `--resume <id>`/`CLAUDE_CONFIG_DIR`
>   argv), NOT yet against the real CLI resuming a transcript copied across config
>   dirs. Confirm `claude --resume <id>` actually picks up a cross-profile-copied
>   transcript before tagging. If a claude version needs more than the jsonl (e.g.
>   a `.claude.json` index entry), extend `adapter_relay`.
> - **`clikae status [<cli>]`** — shows which profile each CLI is on *in this
>   shell* by resolving the live env var back to a profile (`(default)` = unset,
>   `(external)` = points outside the store). Foundational for the v1.0 GUI.
>   Shared resolver `resolve_active_profile` lives in `lib/core/profile_store.sh`
>   (used by both status and relay — don't re-inline it).
>
> Both are wired into the dispatcher (`bin/clikae`), `help`, and `docs/usage.md`;
> CHANGELOG `[Unreleased]` describes them.
>
> - **`clikae app --terminal <terminal|iterm2|ghostty>`** — the `.app` launcher
>   can now open iTerm2 or Ghostty, not just Terminal.app (closes most of §9.2 /
>   roadmap #6). `lib/commands/app.sh` was refactored: a `_app_render_script`
>   dispatch picks a per-terminal AppleScript template
>   (`lib/templates/launcher.{,iterm2.,ghostty.}applescript.tmpl`). Terminal.app &
>   iTerm2 use their scripting APIs; **Ghostty can't open a window from the CLI on
>   macOS** (`ghostty` only runs `+actions`), so its launcher is an AppleScript
>   `do shell script "open -na Ghostty.app --args --title=… -e /bin/zsh -lc '…'"`.
>   Default target overridable via `$CLIKAE_TERMINAL`. Target must be installed
>   (checked via /Applications, ~/Applications, then `mdfind` bundle-id) else a
>   clear failure. **NB on templates:** the existing convention is that a
>   template's comment must NOT contain the literal `@TOKEN@` (with @ delimiters)
>   or the `${//}` substitution mangles the comment — I hit this; the new template
>   comments refer to tokens without the @s. **Ghostty path is fully tested**
>   (mechanism verified end-to-end incl. a space-containing config path; bats
>   asserts the generated launcher). **iTerm2 path is NOT machine-verified here**
>   (iTerm2 isn't installed on the maintainer's Mac) — the maintainer's partner
>   (profile b) will dogfood it; if iTerm2's `create window with default profile
>   command` needs tweaking, it's all in the one template file. **Warp is still
>   not supported** (no clean command-launch story) — left as a small follow-up.
>
> - **macOS menu bar app skeleton (`gui/ClikaeMenuBar/`, v1.0 track).** SwiftPM +
>   AppKit `NSStatusItem` app — **builds with the Command Line Tools, no Xcode
>   needed** (`cd gui/ClikaeMenuBar && swift build`; verified, `Build complete!`).
>   `Clikae.swift` shells out to the CLI (`/bin/zsh -lc "clikae …"` so GUI PATH
>   resolves) and parses `clikae list -p` / `clikae status`; `main.swift` builds
>   the menu (profiles per CLI, active check-marked, click → `clikae run`, per-CLI
>   Relay submenu → `clikae relay`, Refresh, Quit). Launches via Ghostty
>   (`open -na Ghostty.app --args -e /bin/zsh -lc "…"`), Terminal.app fallback.
>   **NOT runtime-tested here** — it's a menu-bar agent needing a real login /
>   window-server session, so I only compile-verified it (running it headless
>   would crash on the WindowServer connection). Next: package as a signed
>   LSUIElement `.app` bundle, login-item toggle, per-CLI terminal preference.
>   `.build/` is gitignored.
>
> - **`flag` strategy + 2 new adapters (now 13).** New adapter strategy `flag`
>   for CLIs with no config-dir env var (the dir is passed as a CLI flag). Added
>   via optional hook `adapter_flag_args <dir>`; the alias/`.app` command is now
>   assembled centrally in `adapter_command` (env prefix + binary + flag suffix),
>   used by both `alias.sh` and `app.sh` — don't re-inline. New adapters:
>   **`codex`** (env-dir `CODEX_HOME` — the product pivot: route cheap/dirty work
>   to a cheaper model/vendor; see §10.1) and **`vercel`** (flag,
>   `--global-config`). `clikae status` shows `(n/a)` for flag CLIs. **PowerShell
>   mirrored** (codex+vercel in the table, `flag` handling in
>   env/function/invoke/shortcut, new `Get-ClikaeFlagArgs`); Pester count 11→13.
>   **PS NOT locally tested** (no pwsh on the Mac) — windows CI is the verifier.
>   bats 71→**91**. NB: **`antigravity` was investigated and deliberately NOT
>   added** — `~/.antigravitycli` is just a symlink into `~/.gemini`, there's no
>   `antigravity` CLI binary and no clean config-dir env var; needs real info
>   before an adapter can be written.
>
> Still TODO before a v0.5 tag: real-claude relay verification, iTerm2 dogfood
> (partner has iTerm2), optional Warp target, codex dogfood (user will install
> it), GUI runtime dogfood + `.app` packaging, the bigger product arc (see §10.1
> below: ambient auto-relay + free naming/account labels + `clikae rename`), and a
> roadmap decision on whether relay deserves its own headline in README's roadmap
> list.

**HEAD state (read this first — updated 2026-06-20).** The latest release in-tree is
**`v0.6.1`** (branch `release-v0.6.1`, pending tag + push by the maintainer).
`v0.6.0` (2026-06-14) shipped the vertical-orchestration feature set: `clikae
conduct`, `clikae git-id`, `clikae burn --prompt-file/--prompt/--add-dir`, and
the orchestration playbook (`docs/orchestration.md`). **`v0.6.1`** (2026-06-20)
is a hardening patch on top of that — no new command surface:

- ✅ **`conduct --leg` name validation** — path-escape bug fixed; slugs can't leave the out-dir.
- ✅ **`proc` interactive-vs-background guard** — env-block false positives fixed.
- ✅ **`_app_shell_squote`** — single-quote handling corrected; `.app` launchers
  work for paths/prompts with apostrophes.
- ✅ **`codex` cwd trailing-slash matching** — sessions with/without trailing slash
  both surface in the Continue list.
- ✅ **`state-version` migration message** — garbled failure message fixed; v1→v2
  migration path pinned in bats.
- ✅ **`$CLIKAE_LIMIT_PATTERN` in headless output-dry path** — env override now
  honoured consistently in both transcript and output-dry detection paths.
- ✅ **PowerShell adapter-drift test** — bats now guards the PS adapter table
  against bash-adapter additions, catching cross-language drift early.
- ✅ **`conduct --help` honesty test** — bats asserts the help text discloses its
  read-only, non-judging limits.
- ✅ **Orchestration playbook expanded** (`docs/orchestration.md`) — cost-aware
  model-tiering guidance and independent-verification principles added.
- ✅ **Demo board hardened** — ToS-safe multi-engine demo, sandbox path removed.
- ✅ **`homebrew/RELEASING.md`** — exact publish commands captured in-repo.

The tree is clean and CI is green — **6 jobs**: shellcheck, smoke (ubuntu+macos),
bats (ubuntu+macos), and pester (windows). `bats -r tests` = **408/408**
(verified locally 2026-06-20, 0 failures). The live punch-list
is `docs/HANDOFF-world-class-gaps.md`; the older §2 below is v0.4-era context.

**Release recipe (for next time you cut a tag) — what `v0.4.0` did:** bump
`CLIKAE_VERSION` in `bin/clikae`; move CHANGELOG `[Unreleased]` → `[X.Y.Z] —
<date>` and add a new empty `[Unreleased]`; commit "Release vX.Y.Z"; `git tag -a`
+ push commit & tag; `gh release create` with notes; **then** `curl -sL` the
GitHub tarball, `shasum -a 256` it, and bump `url`+`sha256` in **both**
`homebrew/clikae.rb` (in-repo) **and** the tap repo's `Formula/clikae.rb`
(separate repo at `~/Desktop/GitHub/homebrew-clikae` → `CVERInc/homebrew-clikae`;
the sha256 must come from GitHub's generated tarball, not `git archive`). Verify
with `brew fetch/style/audit CVERInc/clikae/clikae`. NB: keep the local tap clone
`git pull`ed — it was found stale (a release behind) when cutting v0.4.

**Shipped in `v0.4.0`:**

- **Four more built-in adapters (now 11 total)** — `az` (env-dir
  `AZURE_CONFIG_DIR`), `npm` (env-file `NPM_CONFIG_USERCONFIG`), `terraform`
  (env-file `TF_CLI_CONFIG_FILE`) and `pulumi` (env-dir `PULUMI_HOME`). The
  env-file pair seeds an empty config file on `init` (like kubectl). PS adapter
  table + Pester count kept in sync. NB: `vercel` was considered but uses a
  `--global-config` flag (no clean env var), so it needs `flag`-strategy support
  in the alias/app generators first — left as an open item, not added.
- **v0.4 Windows / PowerShell module** — `powershell/Clikae.psm1` plus a Pester
  suite (`powershell/Clikae.Tests.ps1`) and a `windows-latest` CI job. 21 Pester
  tests pass under **both** PowerShell 7 (`pwsh`) and Windows PowerShell 5.1
  (`powershell`). Full detail in §3's v0.4 entry. There is no Windows machine in
  the loop — CI on windows-latest IS the verification path.
- **`clikae migrate` in-use guard** — refuses (NOT bypassable by `--force`,
  never blocks `--dry-run`) when the live `$<ENVVAR>` points at a dir slated to
  move. See the migrate note in the v0.2 list below; bats coverage added.
- **CI maintenance** — `actions/checkout` v4→v5 (the v4 pin runs on the
  deprecated Node 20 runtime) and the new pester job. NB: the `shell:` key cannot
  take a `${{ matrix.* }}` expression — that's why the windows job uses two
  explicit-shell steps, not a matrix. Validate workflow edits with `actionlint`.

Added in **v0.3** (publish polish — all of §3's v0.3 milestones are done; tagged):

- **Homebrew tap is live.** `brew install CVERInc/clikae/clikae` works, served
  from `github.com/CVERInc/homebrew-clikae`. Both the tap's `Formula/clikae.rb`
  and the in-repo `homebrew/clikae.rb` track **v0.3.0** (url + sha256 verified
  against the tagged tarball). On each new tag, bump `url`+`sha256` in **both**.
- **`clikae migrate --keep-login`** (opt-in). On macOS, claude stores its OAuth
  token in the login **Keychain**, NOT in `CLAUDE_CONFIG_DIR`. The keychain
  service is `Claude Code-credentials-<sha256(config-dir path)[:8]>`, so moving
  the dir orphans the token → a one-time re-login per migrated profile.
  `--keep-login` copies the token from the old path's keychain slot to the new
  one, via an optional adapter hook `adapter_migrate_credentials <old> <new>`
  (claude-only, in `lib/adapters/claude.sh`; other adapters simply don't define
  it). Off by default; documented; covered by bats (macOS-only test stubs
  `security`). The token never leaves the Keychain.
- **Docs split.** README trimmed to what+why + 30-second demo + links; install /
  full usage / `migrate` guide / how-it-works moved into `docs/installation.md`
  and `docs/usage.md`; new `docs/troubleshooting.md`.
- **`docs/claude-on-macos.md`** records two macOS-specific Claude Code behaviours
  found while dogfooding (Keychain-stored login token keyed by the config-dir
  path; "Welcome back" box vs compact logo driven by `.claude.json` counters +
  `CLAUDE_CODE_FORCE_FULL_LOGO`). Confirmed against Claude Code 2.1.156.
- Tagged **`v0.3.0`** with a matching GitHub Release; merged to `main`.

Added in **v0.2** (all of §3's v0.2 milestones are done):

- Six more built-in adapters: `gh`, `gcloud`, `docker`, `helm` (env-dir),
  `kubectl` (env-file), `aws` (env-var). Total: 7.
- `clikae migrate [<cli>]` — adopts a hand-rolled config-dir + alias setup
  (the `~/.claude-acct-{a,b}` pattern) into clikae. See `lib/commands/migrate.sh`.
  **Known sharp edge:** migrate *moves* the config dir, so it must not run while
  that CLI is using the dir — notably, do NOT migrate `claude` from inside a
  `claude` session whose `CLAUDE_CONFIG_DIR` is one of the dirs being moved (you
  saw the dir out from under the live process; it can recreate an empty dir at
  the old path → split state). Run it from a fresh shell with the CLI idle.
  Documented in `docs/usage.md` and `docs/troubleshooting.md`. **Guarded as of
  v0.4:** `migrate` now refuses (not bypassable by `--force`) when the live
  `$<ENVVAR>` points at a dir slated to move, with bats coverage in
  `tests/bats/migrate.bats`.
  (The macOS Keychain sharp edge and its `--keep-login` fix shipped in v0.3 —
  see the v0.3 section above.)
- `bats-core` suite under `tests/bats/` (now 71 tests; isolated
  `$HOME`/`$CLIKAE_HOME`),
  wired into CI on `ubuntu-latest` + `macos-latest`. CI installs bats by cloning
  `bats-core` into `~/.local` (NOT `npm i -g bats` — that hits EACCES on the
  ubuntu runner's global npm prefix, exit 243). CI is green on both OSes.
  **Run bats with `-r`** (`bats -r tests/bats`) — without it bats does NOT
  recurse into `tests/bats/adapters/`, silently skipping the adapter tests. The
  CI step was fixed to use `-r` (it had been skipping that subdir).
- All sourced libs carry a `# shellcheck shell=bash` directive; the tree is
  shellcheck-clean at `warning`.
- Two helpers added to kill duplication: `adapter_env_prefix` (adapter_loader.sh,
  used by alias/app/migrate) and `rc_wrap_block` (shell_rc.sh, used by
  rc_add_block/migrate). Don't re-inline these.
- **Bug fixed:** `clikae app` never compiled on macOS — the launcher command was
  substituted via `sed`, but BSD `sed` strips backslashes from the replacement,
  so escaped quotes collapsed and the AppleScript was invalid. Now substituted
  via bash parameter expansion (backslash-escape before quote-escape). This is
  exactly the BSD-sed footgun in §4 — heed it.
- Published to **github.com/CVERInc/clikae** (public, MIT), tagged **`v0.2.0`**
  with a matching GitHub Release. `<your-handle>` is resolved to `CVERInc`
  everywhere. Open question §9.4 (org) → CVERInc; §9.2 (AWS strategy) →
  `env-var`/`AWS_PROFILE`, with the `env-file` alternative documented in
  `lib/adapters/aws.sh`.

Homebrew tap (v0.3): **DONE.** The `homebrew-clikae` tap repo now exists at
`github.com/CVERInc/homebrew-clikae` (public, MIT) with `Formula/clikae.rb`
(tracks v0.3.0, sha256 verified). `brew install CVERInc/clikae/clikae` installs,
`brew test`/`brew audit`/`brew style` all pass. The in-repo `homebrew/clikae.rb`
is now just the source-of-truth copy; on each new tag, bump `url`+`sha256` in
**both** the in-repo copy and the tap's `Formula/clikae.rb` (the tap repo's
README documents the refresh steps).

Shipped in v0.1:

- Dispatcher: `bin/clikae` (sources `lib/core/*` then `lib/commands/<cmd>.sh`).
- Commands: `init`, `app`, `alias`, `run`, `list`, `remove`, `info`, `adapters`, `help`, `version`.
- Core libs: `log.sh`, `profile_store.sh`, `shell_rc.sh`, `adapter_loader.sh`.
- One built-in adapter: `claude` (CLAUDE_CONFIG_DIR / env-dir strategy).
- AppleScript launcher template at `lib/templates/launcher.applescript.tmpl`.
- `install.sh` (curl-bash + local-checkout install to `$PREFIX/share/clikae` with `$PREFIX/bin/clikae` symlink).
- Homebrew formula template (`homebrew/clikae.rb`) — needs URL + sha256 once first tagged release exists.
- `.github/workflows/ci.yml` — shellcheck + smoke test matrix (Linux + macOS).
- README, LICENSE (MIT), CHANGELOG, `.gitignore`.
- Developer docs at `docs/adding-an-adapter.md`.

Smoke-tested end-to-end in a sandbox HOME: `init --alias` → `list` → `remove --force` cleans dir + alias block + leaves a `.bak`.

**Known placeholders** (status):

- ~~`<your-handle>`~~ — resolved to `CVERInc` (v0.2).
- `REPLACE_WITH_RELEASE_SHA256` in `homebrew/clikae.rb` — filled for the v0.2.0
  tarball (v0.2); re-fill on each new tagged release.
- The `2026 clikae contributors` line in `LICENSE` is fine as a placeholder; some maintainers prefer `<their name>`.

---

## 3. Next milestones (priority order)

> **Where we are now (2026-05-30):** v0.1–v0.4 all SHIPPED. The next open work,
> roughly in priority order: (1) the **v0.4 follow-ups** — a PowerShell `migrate`
> equivalent, PSGallery publish + a `.psd1` manifest, `.lnk` UX polish; (2)
> **`vercel` adapter**, which first needs `flag`-strategy support in the
> alias/app generators (it has no clean config env var, only `--global-config`);
> (3) **`clikae status`** + the **v1.0 SwiftUI menu-bar GUI**. Still needing a
> maintainer decision (ask, don't decide): fish-shell support, and iTerm2/Warp
> detection for `clikae app` (§9).

### v0.2 — quality + more adapters  ✅ DONE (shipped, see §2)

All five items below were completed in v0.2 and are kept here as a record of what
"done" covered. The next open milestone is **v0.3**.

Goals: prove the project is robust, expand CLI coverage. Roughly half-a-day to a day.

1. **`bats-core` tests** under `tests/bats/`.
   - `init.bats`, `alias.bats`, `app.bats` (macOS-only, skip on Linux via `if [[ $OSTYPE != darwin* ]]`), `list.bats`, `remove.bats`, `adapters/claude.bats`.
   - Test isolation: each test sets `HOME=$(mktemp -d)` and `CLIKAE_HOME="$HOME/.clikae"`.
   - Use real `bin/clikae`, not a stubbed copy.

2. **Wire up CI properly.** The existing `.github/workflows/ci.yml` runs shellcheck and a smoke test. Add a `bats` job that runs the test suite on both `ubuntu-latest` and `macos-latest`.

3. **`clikae migrate` command** for users who hand-rolled the old `~/.claude-acct-{a,b}` + `~/.zshrc` alias block pattern (some early users — including the original author — have this). Detect it, propose a rename to `~/.clikae/profiles/claude/{a,b}/`, rewrite the alias block to clikae's sentinel format. Print a clear preview + confirm prompt.

4. **More built-in adapters** (each is ~10 lines, see `_template.sh`):
   - `gh` (GitHub CLI) — env-dir, `GH_CONFIG_DIR`
   - `gcloud` — env-dir, `CLOUDSDK_CONFIG`
   - `kubectl` — env-file, `KUBECONFIG` (note the file vs dir difference — see `_template.sh` for the `env-file` pattern)
   - `docker` — env-dir, `DOCKER_CONFIG`
   - `helm` — env-dir, `HELM_CONFIG_HOME`
   - `aws` — env-var, `AWS_PROFILE` (the value is the profile NAME, not a directory — strategy is `env-var`)

5. **Bug-magnet edge cases to add tests for:**
   - Profile names with `.` (allowed) and with `-` (allowed).
   - Re-running `clikae alias` for an existing alias should replace, not duplicate (this is already implemented — verify it).
   - `clikae remove` when only the alias exists, no dir. Or only the .app, no alias. Each piece is removed independently if present.
   - `clikae app` overwriting an existing .app without `--force` must fail clearly.
   - macOS bash 3.2 compat (no `mapfile`, no `${var,,}`, no `&> /dev/null`).

### v0.3 — publish polish

Goals: smooth install path + good first impression. About a day.

1. ~~**Create a Homebrew tap repo** (separate repo: `homebrew-clikae`). Move `homebrew/clikae.rb` there as `Formula/clikae.rb`. Fill in `url` (tagged release tarball) and `sha256`. Document `brew install <handle>/clikae/clikae` in README.~~ ✅ DONE — live at `github.com/CVERInc/homebrew-clikae`; `brew install CVERInc/clikae/clikae` verified (install + test + audit + style all green).

2. ~~**Polish docs/**: split README into `docs/installation.md`, `docs/usage.md`, `docs/troubleshooting.md`. Keep README short and focused on "what + why".~~ ✅ DONE — README trimmed to what+why / 30-second demo / doc links; install + full usage + troubleshooting moved into `docs/`.

> Out of scope for the assistant: the demo GIF / asciinema recording and any
> promotion (e.g. a Show HN post) are manual, maintainer-only steps — they need
> a human at a real terminal and a judgement call on timing. They are
> deliberately not listed as roadmap tasks; the maintainer handles them when the
> code and docs are ready.

### v0.4 — Windows  ✅ SHIPPED (`v0.4.0`, 2026-05-30)

Implemented as `powershell/Clikae.psm1` (note: named `Clikae`, not the old
`ClaudeProfiles` sketch, since the tool is generic). Same conceptual API,
PowerShell mechanics:

- ✅ PowerShell aliases can't carry env vars → it writes **sentinel-wrapped
  functions** into `$PROFILE` (e.g. `claude-work`), idempotently, with a backup.
- ✅ No `.app` equivalent → `New-ClikaeShortcut` generates `.lnk` shortcuts via
  `WScript.Shell` (Windows-only; guarded by `Test-ClikaeWindows`).
- ✅ Verbs: `New-`/`Get-`/`Remove-`/`Invoke-ClikaeProfile`, `Add-ClikaeFunction`,
  `Get-ClikaeAdapter`, `Get-ClikaeProfileEnv`. The 11-adapter table mirrors
  `lib/adapters/*.sh` — **keep them in sync when adding a bash adapter.**
  (env-file entries carry a `File` key for the seeded filename — `config` for
  kubectl, `npmrc` for npm, `terraformrc` for terraform.)
- ✅ Pester suite `powershell/Clikae.Tests.ps1`, run in CI on `windows-latest`
  under both PowerShell 7 (`pwsh`) and Windows PowerShell 5.1 (`powershell`).
  Watch for 5.1 gotchas: no `$IsWindows` automatic (StrictMode throws on it —
  use `Test-ClikaeWindows`), and Pester 5 must be installed (5.1 ships v3.4).

Still open for a future PR: a `migrate` equivalent, PowerShell Gallery
publishing (no manifest/`.psd1` yet), and `.lnk` UX polish. There is no Windows
machine in the maintainer's loop, so this was authored and verified entirely via
the windows-latest CI runner — extend that job rather than hand-testing.

### v1.0 — macOS menu bar GUI

`gui/ClikaeMenuBar/` — SwiftUI menu bar app.

- Treat the CLI as the source of truth. The GUI just shells out to `clikae list`, `clikae run`, `clikae app`. Don't reimplement profile-storage logic in Swift.
- Show currently-running profile per CLI (this needs `clikae status` — add it to the CLI in v0.2 or v1.0). For Claude that'd mean inspecting which `CLAUDE_CONFIG_DIR` is set in any running terminal session — tricky; consider scope before designing.

---

## 4. Code conventions

- **bash 3.2 compatible** (macOS ships with bash 3.2; can't assume 4+). No `mapfile`, no `${var,,}` (lowercasing), no `[[ … =~ … ]]` BASH_REMATCH array if avoidable.
- **No GNU coreutils-isms.** macOS ships BSD sed/awk. Specifically:
  - `sed -i ''` on macOS, `sed -i` on Linux → prefer `awk` or write-to-tempfile-then-mv (see `lib/core/shell_rc.sh:rc_remove_block`).
  - No `readlink -f`.
- **All scripts pass `shellcheck`.** CI already enforces this at warning level. If you need to silence a warning, justify with a comment.
- **`set -eo pipefail`** at the top of every standalone script (not in sourced libs — those will inherit, but `set -u` causes too many surprises in interactive flows).
- **Quote everything** — paths can contain spaces (e.g. `Application Support`).

---

## 5. The adapter contract (memorise this)

Every adapter file at `lib/adapters/<cli>.sh` must define these functions (all return strings via `echo` unless noted):

| Function | Required? | Purpose |
|---|---|---|
| `adapter_meta_name` | yes | Human-readable name |
| `adapter_meta_cli_binary` | yes | Binary to invoke |
| `adapter_meta_env_var` | yes | Primary env var |
| `adapter_meta_strategy` | yes | One of `env-dir`, `env-file`, `env-var`, `flag`, `subcommand` |
| `adapter_meta_description` | yes | One-line description |
| `adapter_export_env <dir>` | yes | Print `KEY=VALUE` lines (newline-separated) |
| `adapter_run <dir> [args]` | yes | `exec` the CLI with profile env applied |
| `adapter_init <dir>` | optional | Seed the dir when `clikae init` runs |

See `lib/adapters/_template.sh` for boilerplate and `lib/adapters/claude.sh` for a real implementation. The full strategy guide is in `docs/adding-an-adapter.md`.

> **Cross-language mirror:** the Windows PowerShell module keeps a parallel
> adapter table (the `$script:ClikaeAdapters` hashtable in
> `powershell/Clikae.psm1`). When you add or change a bash adapter, add/change
> the matching entry there too, or Windows users silently lose that CLI. The PS
> Pester suite asserts the table has the same 11 CLIs as the bash side.

---

## 6. How to verify your changes

```bash
# Lint
shellcheck bin/clikae lib/**/*.sh install.sh

# Smoke test (no install needed)
./bin/clikae version
./bin/clikae help
./bin/clikae adapters

# Isolated end-to-end (doesn't touch your real ~)
TMP=$(mktemp -d)
HOME="$TMP" CLIKAE_HOME="$TMP/.clikae" ./bin/clikae init claude work --alias
HOME="$TMP" CLIKAE_HOME="$TMP/.clikae" ./bin/clikae list -p
HOME="$TMP" CLIKAE_HOME="$TMP/.clikae" ./bin/clikae remove claude work --force
# Inspect: $TMP/.zshrc (or .bashrc/.profile depending on $SHELL) should be empty,
# and $TMP/.clikae/profiles/ should be empty.
rm -rf "$TMP"

# Full local install
PREFIX="$HOME/.local" ./install.sh
clikae info
```

For v0.2+ once bats is set up:

```bash
brew install bats-core
bats tests/bats
```

For the Windows PowerShell module (v0.4+), if you have PowerShell:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path powershell/Clikae.Tests.ps1
```

No local PowerShell? The `pester` CI job runs this on `windows-latest` under
both PS 7 and Windows PowerShell 5.1 on every push — that's the verification
path. Lint workflow edits locally with `actionlint .github/workflows/ci.yml`.

---

## 7. Things you might be tempted to do — DON'T

- **Don't refactor the dispatcher into a single 800-line script.** The modular layout (bin + lib/commands + lib/core + lib/adapters) is intentional — it makes each piece testable in isolation and lowers the barrier to a community-contributed adapter (write one file, drop in `lib/adapters/`).
- **Don't add a Python or Node dependency** — the whole pitch is "every line is auditable bash".
- **Don't store secrets or call out over the network.** Profile data stays local. There is no telemetry, no auto-update, no analytics.
- **Don't change the sentinel format** without a migration path. People will have existing alias blocks in their rc files.
- **Don't `set -u`** at the top level — it's tripped us once already (the very first version of `install-claude-launcher-apps.sh` errored on `$APPS_DIR` mid-echo for reasons that still aren't fully explained, but moving to `set -eo pipefail` made it go away).

---

## 8. Quick reference

| Thing | Where |
|---|---|
| Repo root | `~/Developer/clikae/` |
| Profile store (per user) | `~/.clikae/profiles/<cli>/<profile>/` (override root: `$CLIKAE_HOME`) |
| Shell rc (auto-detected) | `~/.zshrc` / `~/.bashrc` / `~/.bash_profile` / `~/.profile` |
| .app launchers | `~/Applications/<cli> (<profile>).app` |
| Backups | `<rc-file>.clikae.bak.<timestamp>` next to the rc file |
| Logs | none (this is a sync CLI, errors go to stderr) |
| Windows module (v0.4) | `powershell/Clikae.psm1` + `Clikae.Tests.ps1`; writes funcs into `$PROFILE`, backups `$PROFILE.clikae.bak.<ts>` |
| CI | `.github/workflows/ci.yml` — shellcheck, smoke×2, bats×2, pester (windows)×1 |

---

## 9. Open questions for the maintainer

Still genuinely open (an assistant should **ask first**, not decide):

1. **`clikae app` for non-Terminal users** — some macOS folks use iTerm2 or Warp. Idea: detect default terminal and pick the right `tell application` target, or accept a `--terminal-app` flag. (Partly addressed: `clikae app --terminal` already supports `terminal`/`iterm2`/`ghostty`; Warp + auto-detect still open.)

Already resolved (kept for the record):

- ~~**fish shell support**~~ → **DONE (2026-05-31).** `clikae alias` detects fish via `detect_shell_kind` and emits fish syntax `alias <name> 'env VAR=val <binary>'` (fish has no inline `VAR=val cmd`; `adapter_command_fish` routes through `env`). rc path + sentinel removal already worked. `rc_add_block` now `mkdir -p`s the rc's parent (fish's `~/.config/fish/`). Tests in `tests/bats/alias.bats`.

- ~~**AWS adapter strategy**~~ → `env-var` / `AWS_PROFILE` (the `env-file` /
  `AWS_CONFIG_FILE` alternative is documented in `lib/adapters/aws.sh`).
- ~~**GitHub org/user naming**~~ → **CVERInc**; all `<your-handle>` placeholders resolved.

---

## 10. Original goal (for context)

This project started as a personal need: the maintainer has two Anthropic Claude subscriptions (one Max plan's quota wasn't enough, so they added a second) and wanted both usable from the CLI on one Mac without log-in collisions. Manual setup worked. Then it became clear the same pattern solves the problem for many other CLIs, and there's no existing tool that does it generically.

Stay close to that origin story — small, sharp, useful. Resist scope creep.

Good luck.

---

## 10.1 Product direction (decided with the maintainer, 2026-05-31 session)

The maintainer reframed clikae's core during this session. Capture for whoever
continues — these are decisions, not musings:

1. **From "multi-account switcher" to "fuel-tank / model router."** The headline
   value is **routing work to a cheaper model/vendor** ("let the cheaper one do
   the dirty work") and **continuing when a tank runs dry** — not just juggling
   two Claude logins. The maintainer thinks the multi-vendor/model case (Claude ⇄
   Codex ⇄ Antigravity…) may matter MORE than multi-Claude. Hence `relay`
   (continue on another tank) is the flagship, and cross-vendor adapters (codex
   added; antigravity pending real config info) are first-class, not afterthoughts.
   "油箱" (fuel tank) = a profile/account/model you can burn; clikae supports a
   pool of them.

2. **UX philosophy: "quietly help, then tell me what you did."** Ambient,
   hide-and-assist, with transparency after the fact and authorization before
   anything outward. Build toward that, not a chatty/manual feel.

3. **Auto-switch reality (researched via claude-code-guide — IMPORTANT, don't
   re-litigate):** an INTERACTIVE Claude Code TUI hitting its usage limit does
   **not exit**, returns **no exit code**, and **no hook fires** for usage limits
   (hooks are PreToolUse/Stop/Notification/etc., none for quota). So an external
   tool **cannot cleanly auto-switch mid-conversation**. What IS feasible:
   (a) headless/print mode (`claude -p --output-format json`) can be wrapped to
   detect a limit and auto-relay (JSON schema undocumented → test empirically);
   (b) transcript-watching to NOTICE you were limited and proactively OFFER to
   relay; (c) best-effort interactive output/transcript scraping (fragile).
   **Maintainer chose: "盡量自動" — best-effort auto including interactive**, but
   it must stay transparent + opt-in. So the design is: detect → offer (interactive)
   / auto after one-time consent (headless). Don't promise silent mid-session
   interactive switching; it isn't reliably possible.

4. **Naming (maintainer's stated TOP priority): kill `a`/`b`.** Free naming
   already works (`a`/`b` were just this user's choice). Decided: **free naming +
   auto-detected account label** (read the logged-in account, e.g. claude's
   `.claude.json` email, and show it in `list`/`status`) **+ a new `clikae rename`
   command**, and **purge a/b from all docs/examples** in favour of meaningful
   names. NB: `rename` for claude MOVES the profile dir → same macOS-Keychain
   re-key issue as `migrate`, so it must reuse `adapter_migrate_credentials`
   (the `--keep-login` carry-over). Treat rename like a mini-migrate.

**Built so far (branch `feat/relay-and-status`):** (a) ✅ **naming refactor** —
`adapter_account_label` hook (claude reads `.claude.json` `oauthAccount.emailAddress`
via grep/sed, no jq), surfaced as an ACCOUNT column in `clikae list` and `status`;
new `clikae rename <cli> <old> <new>` = mini-migrate (move dir + rewrite alias,
preserving a custom alias name else swapping the default; reuse
`adapter_migrate_credentials` for claude's Keychain; in-use guard not bypassable
by `--force`). bats in `tests/bats/rename.bats`. Docs updated; a/b purged from the
*recommended-naming* surface (legacy a/b examples in `docs/claude-on-macos.md` are
left — they document the real `~/.claude-acct-{a,b}` migration + keychain hashes).

**Still not built (next, roughly prioritised):** (b) **ambient relay** —
detect-and-offer on interactive, auto on headless, behind an explicit opt-in (the
maintainer wants best-effort-auto; remember interactive can't be fully automated —
no usage-limit signal, see point 3 above); (c) **`antigravity` adapter** once its
config mechanism is known (only a `~/.gemini` symlink today); (d) ~~fish support~~
**DONE 2026-05-31** (see §9); (e) the existing v0.5 TODO list in §2 (PS
`.psd1`/migrate, GUI `.app` packaging, Warp).

**Update 2026-05-31 (later session) — several "still not built" items above are now DONE.**
Confirmed via real dogfooding and shipped on `feat/relay-and-status`:
- (b) **ambient relay** — `clikae watch` + `pool` SHIPPED (detect→offer, auto-after-consent).
- **All three limit markers CONFIRMED** (claude/codex/agy) and encoded; agy's is special —
  `agy -p` exits 0 with empty output, marker only in `~/.gemini/antigravity-cli/cli.log`.
- **`watch antigravity`** (log-scan detection of a dry agy tank) SHIPPED — alert-only, since
  agy can't be a handoff *source* (opaque `.pb`); auto-relay-from-agy remains unbuilt.
- **Real claude cross-account `relay` DOGFOOD-CONFIRMED** — A→B carried a live session and
  resumed on B's quota with context intact (was previously only stub-verified).
- (d) **fish support** SHIPPED.
Still genuinely open: antigravity full adapter (likely stays launch-only), vercel adapter,
`status` polish + v1.0 GUI, Windows follow-ups (PS `.psd1`/migrate, mirror watch/pool), Warp.

---

## 11. ✅ DONE (shipped v0.5.5) — `rename`/`migrate`/`remove` in-use guard only covered the CURRENT shell (phantom-tank bug)

> **Resolved:** `lib/core/proc.sh::live_dir_users` scans all same-uid procs for the
> tank's env var and is wired into rename/migrate/remove (interactive holder →
> hard-fail; daemon/spare → soft warn). Tests in `tests/bats/{rename,migrate,remove}.bats`.
> Original writeup kept below for context.


**Found 2026-06-03 by dogfooding (maintainer hit it live).** Renaming claude
`b`→`L` and `a`→`C` left **phantom `a`/`b` tanks** that kept reappearing on the
board. Root cause confirmed on disk + via `ps eww`:

- The in-use guard in `cmd_rename` (`lib/commands/rename.sh`, the `${!envvar}`
  block) — and the equivalent in `migrate` — **only checks the env var of the
  shell running `clikae`**. It does NOT see a live interactive session, or the
  background `claude daemon run` + `--bg-spare`/`--bg-pty-host` workers, that hold
  `CLAUDE_CONFIG_DIR=<old>` in **another** terminal/process tree.
- So: maintainer ran `rename` from shell A (var not `=b`) → guard passed → `mv`
  succeeded → a still-open claude session in shell B (env still `=b`) kept writing
  to the old path → **recreated an empty/stub tank at the old name.** Same class
  of bug noted for `migrate` in §2 (v0.2 list) — the guard there has the same hole.
- Proven nuance: after the **interactive** session closed, the stale **daemon/
  spares** alone did NOT recreate the dir. So the hard culprit is a live
  interactive TUI; daemon/spares are a softer signal.

**The fix (tractable, ~50–80 lines incl. bats):**

1. Add a core helper, e.g. `lib/core/proc.sh::live_dir_users <dir> <envvar>` —
   scan same-uid processes for `<envvar>=<dir>`. macOS: `ps eww -o pid=,command=`
   then read env per pid; Linux: `/proc/<pid>/environ` (NUL-split). Pure
   `ps`/grep, bash 3.2, BSD-safe. (We already proved the detection works:
   `ps eww -p <pid> | tr ' ' '\n' | grep CLAUDE_CONFIG_DIR=…`.)
2. In `cmd_rename` (and reuse in `migrate`, `remove`): after the existing
   current-shell check, scan all processes for `<old_dir>`. **Classify by command
   string:** an interactive TUI holding `=old` → **hard-fail** (data-integrity,
   `--force` can't bypass, like today's guard); only `daemon run`/`--bg-spare`/
   `--bg-pty-host` holding `=old` → **soft warn** ("quit Claude Code fully first").
3. **agy exception:** agy has no per-tank env var (it's the `~/.gemini` symlink);
   `_agy_rename` should instead refuse if any `antigravity` process is running.
4. Tests: stub `ps` the way the suite already stubs `pgrep` (per the v0.5.3 note
   "helpers now stub pgrep so agy tests are host-independent").

**Honest limits (don't oversell in copy):** catches "a session is open right
now" — the overwhelming case — but not a check-then-open race; daemon-vs-TUI
classification is a command-string heuristic. Recovery for a user who already hit
it: the phantom stub tanks are safe to back up + remove once the old terminal is
closed (the real history lives under the renamed tank).

---

## 12. ✅ DONE (shipped v0.5.5) — the board's "Continue" list was claude-ONLY (cross-engine continuity gap)

> **Resolved:** `lib/adapters/codex.sh` got `adapter_transcript_path` (matches a
> rollout's recorded `cwd`, not a slug) + a recap extractor, so codex sessions now
> show in the board's Continue list (verified live — `clikae` shows codex/H, codex/M).
> Original writeup kept below for context.


**Found 2026-06-03 by dogfooding.** A codex session run through a clikae codex
tank (it edited a repo; the rollout records its `cwd`) shows up on the board only
as a **tank**, never in the **Continue / 續上次** list — even when the board is
opened from that session's own `cwd`. Claude sessions on the same dir DO appear,
each with a recap. So clikae's recent-session resume/recap is, today, **claude
only**.

**Root cause:** `lib/adapters/codex.sh` defines no `adapter_transcript_path` (nor
a recap hook), so the board's Continue builder never scans codex's rollouts. Only
the claude adapter exposes the transcript path the board reads.

**Why it matters:** cross-**engine** continuity is clikae's stated differentiator
(README + positioning). Right now only cross-**tank** switching is engine-wide;
the *session* continuity that makes the board valuable is claude-deep. The pitch
slightly outruns the implementation for non-claude engines.

**The fix (tractable):**
1. Give the codex adapter `adapter_transcript_path <dir>` → resolve the most
   recent `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` whose recorded `cwd`
   matches `<dir>`. **Match on the rollout's `cwd` field, not a path slug** —
   codex does not slug `$PWD` the way claude does.
2. A recap extractor for codex rollouts (or fall back to "<age> ago" when none) so
   Continue rows render like claude's.
3. Then the existing cross-engine board code lists codex sessions for free.

**Out of scope here:** codex over-quota is still un-detectable from disk (see
`lib/core/limit.sh` notes) — that's the *fuel* axis, independent of *resume*. This
TODO is only about surfacing codex sessions in Continue.

---

## 13. OPEN QUESTION — tanks own the AI account's state, but NOT the git commit identity (mis-attribution leak)

**Found 2026-06-04 by an incident, not by clikae code.** A run authored 9 commits
across `reef` + `bleedblend` whose git **author/committer email** was the engine's
own account email (`mr.crazyx2@gmail.com`, the value Claude Code carries as its
system `userEmail`). GitHub maps a commit to an account by that **email**, so all
9 commits rendered under the GitHub account `@lersiann` (which owns that email) —
NOT the maintainer's intended OSS identity `@chodaict` / `x@cver.net`. Fixed
out-of-band with `git filter-repo` + force-push; the gmail is now scrubbed.

**This was NOT a clikae bug** — clikae never set `user.email`; the engine did
(a `git -c user.email=<its account email>` style commit, "too faithfully" using
the email the harness injected). But it exposes a real gap **adjacent to clikae's
thesis**, so it belongs here.

**The conceptual gap.** clikae's job is "control where the *engine's account state*
lives" — a tank = one AI account's profile (see the state-mapping work: tank holds
the engine's MEMORY/login, not just fuel). But a commit has a **second identity
axis** clikae does not touch: the **git author/committer**. Today these are
unrelated:
- the tank says *which AI account* is driving (e.g. a "chodaict" tank), but
- the commit's `user.name`/`user.email` come from `git config` (global) **or** from
  whatever the engine injects — which can be its *AI-account* email, a different
  identity entirely.

So you can be in a tank you think of as "chodaict" and still emit commits stamped
with the engine account's email → silent mis-attribution on GitHub, and a private
address leaked into public history.

**Why it matters to clikae specifically.** clikae already positions itself as the
*control plane* for "which identity/state is active per session". Git authorship is
the most consequential identity a coding session produces, and it's currently
*outside* the tank's control — the one place where "which account am I?" has a
durable, public, hard-to-reverse consequence, and clikae is silent there.

**Possible directions (NOT yet decided — needs maintainer call):**
1. **Per-tank git identity (opt-in).** Let a tank carry an optional
   `git.user.name` / `git.user.email`; `clikae env <engine> <tank>` then exports
   `GIT_AUTHOR_*` / `GIT_COMMITTER_*` (or `-c` overrides) so commits made in that
   shell are stamped with the tank's intended identity. Safe default = do nothing
   (inherit global config); enable explicitly — fits the informed-consent opt-in
   pattern, not a silent default that hijacks `git config`.
2. **Mismatch warning only (cheaper first brick).** `clikae status --json` /
   board could surface "this tank's intended identity vs the git identity the
   shell will actually commit as" and warn when an engine is known to inject its
   account email. Detection without mutation.
3. **Do nothing, document the footgun.** Out of scope; just tell users to pin
   `git config --global user.email` and never let an engine commit with `-c
   user.email=<harness userEmail>`.

**Guard for whoever ships any of this:** an email can be verified on only ONE
GitHub account at a time, so "fixing" attribution by re-binding email is an
account-settings action, not a clikae action — clikae can only influence *new*
commits, never retroactively re-map old ones (that needs history rewrite, as was
done here). Don't claim clikae can "fix attribution" — it can only *prevent the
next* mis-stamp.

**Out of scope here:** this is the *authorship* identity axis. It is independent of
the *fuel* axis (quota/limit) and the *resume* axis (§12). Three different "which
account?" questions; clikae owns the first two today, not this one.

---

## Dogfood (2026-06-03): headless cross-engine dispatch + codex tank-switch reality check

Verified clikae can drive a *different engine headlessly*, end to end: in a single
shell, `eval "$(clikae env codex <tank>)"` then
`codex exec -C <dir> -s workspace-write "<task>"` — codex then created files
autonomously on the selected tank. This is the "route the grunt work to a cheaper
tank" thesis working in practice: one engine orchestrates, another executes.

**Gotcha to document:** tank selection via `clikae env` is **per-shell** (`$CODEX_HOME`)
and does NOT persist across separate non-interactive shells. Automation must set the
tank inline in the *same* command, not in a prior step.

**Tank-switch reality check for codex:**
- **Manual / carried switch: works** — `clikae env|to codex <tank>` moves codex
  between tanks cleanly.
- **Self-switch on dry: not yet** — `clikae auto` is claude-only (BETA). codex cannot
  carry itself onward when a tank runs dry. Consistent with the open item above: codex
  over-quota is un-detectable from disk, so the *fuel* axis is the remaining gap for
  codex; *resume* already works. → A `clikae auto` covering codex needs codex
  dry-detection first.

### Grunt-dispatch friction (2026-06-03 follow-up — routing chores to codex/agy)

Tried offloading real grunt work (a vault link-integrity checker) to codex, and a
text-summary to agy, both via clikae. Four frictions worth fixing/documenting:

1. **codex `exec` (headless) can hang on slow I/O with no clean abort.** The codex
   grunt read ~350 iCloud-synced files; iCloud read latency stalled it. In headless
   `exec` stdin is closed, so it couldn't interrupt its own child (`write_stdin failed:
   stdin is closed … rerun exec_command with tty=true`). It then re-emitted its diff
   every turn, burning tokens. **Reproduced identically by running the same script in a
   plain shell → it's iCloud-read latency, not codex.** Lesson: don't hand codex grunt
   that does slow/iCloud-backed I/O; bound long jobs with an in-script timeout; a
   dispatcher must not assume a headless codex job is abortable mid-run.

2. **agy needs `--dangerously-skip-permissions` to use its tools headlessly** (e.g. to
   read a file), which a sandboxed harness correctly refuses. **Clean pattern: feed
   content via stdin so agy needs no tools** — pure text in/out, no approval gate:
   `cat file | agy -p "<instruction>"`. Worked first try.

3. **`clikae env agy <tank>` → "No built-in adapter for 'agy'"**, yet `clikae tanks`
   *lists* agy tanks (8, R). Inconsistent: `tanks` advertises agy tanks but `env`
   can't put a shell on one (agy is global single-account, so per-shell routing may be
   intentionally unsupported — but then listing agy in `tanks` is misleading). Fix:
   either support `env agy`, or mark agy rows in `tanks` as non-switchable. (agy still
   ran fine on its global default config — just not tank-routed.)

4. (Restated) per-shell `CODEX_HOME` doesn't persist across separate non-interactive
   shells — set the tank inline in the *same* command.

**What worked:** codex *writing* a correct script is good grunt offload; the *running*
of a slow-I/O script is better kept by the dispatcher. agy is a fine cheap summarizer
via stdin. Net: the cheap-tank routing thesis holds, but headless grunt needs
abort/timeout guards and an agy stdin-only convention.

### Dry-tank DURING a parallel multi-engine burn + manual relay — full writeup (2026-06-03)

> Recorded in detail so the next session fully understands what happened and what
> clikae still needs. This is the single most on-point clikae event observed: a fuel
> tank ran dry mid-task during a deliberate "burn every tank at once", and a manual
> relay kept the work going — exactly clikae's reason to exist, done by hand.

**The setup — a deliberate "全油箱同步燒".** 5 workers fired in parallel, each on one
independent distillation task (read a big text file → write one markdown note):
- claude **a** — orchestrator: pre-extracted the inputs, then reviewed + placed outputs.
- claude **b** — `eval "$(clikae env claude b)"; cat in.txt | claude -p "<prompt>" > out.md`
- codex **H** — `eval "$(clikae env codex H)"; codex exec -C /tmp -s workspace-write --skip-git-repo-check "<prompt: read /tmp/in.txt, write /tmp/out.md>" </dev/null`
- codex **M** — same codex pattern, tank M, different task.
- agy (global) — `cat in.txt | agy -p "<prompt>"` (agy is global single-account; `clikae env agy` is broken, see above).

Inputs were pre-extracted to `/tmp` (NOT read from the iCloud vault): codex `exec` hangs
on iCloud reads (earlier section), so every non-orchestrator worker got its text via a
`/tmp` file (codex) or stdin (agy/claude) — no iCloud latency, no tool-permission gate.

**The event — codex tank M ran dry mid-task.** M's background job **exited 0** (looked
like success) but wrote **NO output file**. Its task log showed, mid-run:
`ERROR: You've hit your usage limit. ... try again at Jul 3rd, 2026 11:38 AM.`
i.e. the parallel burn drained tank M's codex/ChatGPT quota partway through.

**⚠️ CRITICAL gotcha for clikae's codex dry-detect:** `codex exec` **exits 0 even when it
hit the usage limit and produced nothing.** Exit code is NOT a reliable success signal.
Reliable signals are: (a) the literal `You've hit your usage limit` string in stdout/stderr,
and (b) the expected output artifact is missing. Any codex dry-detection MUST parse the
limit string and/or verify the artifact — never trust the exit code. Bonus: the message
carries the reset time (`try again at <date> <time>`) → usable to mark the tank
**dry-until-<timestamp>** instead of just "dry".

**The relay (manual — and it worked).** The orchestrator (claude a) noticed M's missing
artifact + the limit error in its log, re-assigned M's dropped task to itself, and
finished it. Nothing lost; the other 3 tanks' outputs were untouched. 4/4 tasks landed
despite one tank drying. That is "swap the dry tank, keep burning" — but done by hand.

**What clikae needs to automate this (the actual product gap):**
1. **codex dry-detect** (the long-open TODO): match `You've hit your usage limit` in
   codex output + verify the artifact; do NOT use exit code. Parse the reset time to set
   a dry-until window so `watch`/pool don't re-pick a tank that won't recover until then.
2. **Auto-relay of a *dropped parallel task*:** when one tank in a parallel set dries,
   re-queue *that specific task* to a live tank (same engine M→H, or cross-engine →
   claude/agy). This needs the orchestrator to track a task↔tank map, not just "switch
   the shell's tank". Today `clikae to`/`relay` carries a *session*; here we needed to
   re-route a *headless task*. Different shape — pool/scheduler concern.
3. **Idempotent, artifact-checked grunt tasks:** this relay was trivial only because each
   task was re-runnable (fixed `/tmp` input path, fixed output path). clikae's pool/relay
   should assume/encourage idempotent tasks whose completion is verified by an artifact,
   so a dropped one just re-fires elsewhere.
4. **Parallel burn is the fastest dry-tank stress test:** firing all tanks at once
   intentionally drains them — great for exercising watch/pool/relay. M dried within a
   single task.

Complements the earlier notes: `clikae auto` is claude-only, and codex over-quota was
"un-detectable from disk". This run shows it IS detectable *from the codex output* (limit
string), just not from exit code or disk — and that manual relay closes the gap today.

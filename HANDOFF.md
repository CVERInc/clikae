# HANDOFF — clikae

This document briefs a fresh AI coding assistant (or human contributor) on how to continue this project. Read it end-to-end before changing anything.

---

## 0. What this project is

**clikae** (ｷﾘｶｴ, 切り替え — "switching") is a small bash CLI that lets one person juggle multiple accounts/configs for any CLI tool that uses an environment variable for its settings (e.g. `CLAUDE_CONFIG_DIR`, `GH_CONFIG_DIR`, `KUBECONFIG`).

It does three things per profile:

1. Creates an isolated config directory at `~/.clikae/profiles/<cli>/<profile>/`.
2. Optionally writes a sentinel-wrapped shell alias to the user's shell rc (`<cli>-<profile>`, e.g. `claude-work`).
3. On macOS, optionally generates a double-clickable `.app` launcher that opens Terminal with the right env vars and a custom window title.

The repo is at `~/Desktop/GitHub/clikae/`. License: MIT. It's labelled as an unofficial community tool (not affiliated with Anthropic or any CLI vendor).

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

**HEAD state (read this first).** The latest tagged release is **`v0.4.0`**
(GitHub Release live; both `homebrew/clikae.rb` and the tap's
`Formula/clikae.rb` track v0.4.0, sha256 `e2d6fdcb…0fa0`, verified via
`brew fetch`/`style`/`audit`). The tree is clean, nothing is mid-flight, and CI
is green on every push — **6 jobs**: shellcheck, smoke (ubuntu+macos), bats
(ubuntu+macos), and pester (windows). CHANGELOG has a fresh empty `[Unreleased]`
section ready for the next cycle.

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
| Repo root | `~/Desktop/GitHub/clikae/` |
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

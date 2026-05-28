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

## 2. Status as of v0.1 (current)

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

**Known placeholders** that need replacing before publishing:

- `<your-handle>` in `README.md`, `install.sh`, `homebrew/clikae.rb`.
- `REPLACE_WITH_RELEASE_SHA256` in `homebrew/clikae.rb` (fill once a tagged release tarball exists).
- The `2026 clikae contributors` line in `LICENSE` is fine as a placeholder; some maintainers prefer `<their name>`.

---

## 3. Next milestones (priority order)

### v0.2 — quality + more adapters

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

1. **Create a Homebrew tap repo** (separate repo: `homebrew-clikae`). Move `homebrew/clikae.rb` there as `Formula/clikae.rb`. Fill in `url` (tagged release tarball) and `sha256`. Document `brew install <handle>/clikae/clikae` in README.

2. **Demo GIF / asciinema** at the top of README. Show: `clikae init claude work --alias`, `claude-work` opening, a second `clikae init claude personal`, `clikae list`, `clikae app claude work` + double-click result.

3. **Polish docs/**: split README into `docs/installation.md`, `docs/usage.md`, `docs/troubleshooting.md`. Keep README short and focused on "what + why + 30-second demo".

4. **Promotion** (optional, the maintainer's call): a Show HN post once GIF and docs are tight. Don't post earlier — first impressions matter.

### v0.4 — Windows

Add `powershell/ClaudeProfiles.psm1`. Same conceptual API, different mechanics:

- PowerShell aliases can't carry env vars → write **functions** into `$PROFILE` instead.
- No `.app` equivalent → optionally generate `.lnk` shortcuts via `New-Object -ComObject WScript.Shell` for the user to pin to Start menu or Taskbar.
- Test under both PowerShell 7 and Windows PowerShell 5.1 if you can.

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
| Profile store (per user) | `~/.clikae/profiles/<cli>/<profile>/` |
| Shell rc (auto-detected) | `~/.zshrc` / `~/.bashrc` / `~/.bash_profile` / `~/.profile` |
| .app launchers | `~/Applications/<cli> (<profile>).app` |
| Backups | `<rc-file>.clikae.bak.<timestamp>` next to the rc file |
| Logs | none (this is a sync CLI, errors go to stderr) |

---

## 9. Open questions for the maintainer (decide before v0.2 starts)

1. **fish shell support** — list it as "PRs welcome" or commit to it? Fish syntax for aliases is different (`alias name 'cmd'`, no `=`).
2. **AWS adapter strategy** — `AWS_PROFILE` env-var or `AWS_CONFIG_FILE` env-file? They behave differently for users who do/don't have `~/.aws/credentials`. Probably need to pick one default and document the other.
3. **`clikae app` for non-Terminal users** — some macOS folks use iTerm2 or Warp. v0.2 idea: detect default terminal and pick the right `tell application` target, or accept a `--terminal-app` flag.
4. **Naming for the GitHub org/user** — if this gets adopted, will it live under your personal handle or get a project org? Affects all the `<your-handle>` placeholders.

If you (the assistant) are unsure about any of these, **ask the maintainer first** before deciding.

---

## 10. Original goal (for context)

This project started as a personal need: the maintainer has two Anthropic Claude subscriptions (one Max plan's quota wasn't enough, so they added a second) and wanted both usable from the CLI on one Mac without log-in collisions. Manual setup worked. Then it became clear the same pattern solves the problem for many other CLIs, and there's no existing tool that does it generically.

Stay close to that origin story — small, sharp, useful. Resist scope creep.

Good luck.

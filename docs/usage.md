# Using clikae

**clikae is a verb** (切り替え, *switching*). The headline action carries no verb
of its own — the program name is the verb:

```bash
clikae <engine> <tank>      # switch <engine> to <tank> and run it
```

An `<engine>` is a CLI with an adapter (run `clikae adapters`); a `<tank>` is a
name you choose (`A-Z a-z 0-9 . _ -` allowed) for one account/config. The fuel
metaphor runs throughout: a tank holds an engine's quota (its *fuel*); when a
tank runs *dry* you carry your work onward with `clikae to`.

Run `clikae help <command>` for the full per-command reference. The full design
of the language is in [grammar.md](grammar.md).

## Quick tour

```bash
# Create a tank for Claude Code, and add the matching shell alias
clikae init claude work --alias

# Switch to it and run — the bare verb (no `run` needed)
clikae claude work
clikae claude work -- --help    # args after -- go straight to the engine

# Or pick up the alias and use that
source ~/.zshrc                 # or your rc file
claude-work

# Generate a macOS launcher you can double-click from ~/Applications
clikae app claude work

# See what you've got
clikae tanks                    # alias: clikae list
#   ENGINE       TANK
#   claude       work
clikae tanks -p                 # also print the tank directory paths

# Tear it all down (tank dir + alias + .app, asks to confirm)
clikae remove claude work
```

## Commands

clikae is the verb, so **switching needs no verb**; management commands keep
plain, conventional verbs.

### Switch (the main thing)

| Command | What it does |
|---|---|
| `<engine> <tank> [-- args]` | Switch `<engine>` to `<tank>` and run it. The bare verb. (`run` is a hidden alias.) |
| `<engine> <tank> --ephemeral` | Switch and run with **ephemeral memory** — this session's long-term memory is a throwaway, discarded on exit; the tank's real memory is left untouched. Login + transcripts are normal. claude only (clikae must know the memory layout). See below. |
| `<engine>` | One tank → use it; several → list them; none → offer to create. |
| `to <target> [tank] [-- args]` | Carry **this shell's current session** onto another tank. Same engine → a real resume; a different engine → a written brief (cold start). clikae announces which. Source is auto-detected (env var, else this directory's most recent session). Forwards relay's `-y`/`--fresh`/`--session`. (`relay`/`handoff`/`continue` are hidden aliases.) |
| `eval "$(clikae env <engine> <tank>)"` | Put the **current shell** on a tank (export its config env var), so the engine's own command and `clikae status`/`to` see it. The explicit alternative to the one-shot bare switch. |

### Make & manage tanks

| Command | What it does |
|---|---|
| `init <engine> <tank> [--alias]` | Create the tank directory; with `--alias`, also write a shell alias. |
| `remove <engine> <tank> [--force] [--keep-data]` | Remove dir + alias + `.app`. `--keep-data` keeps the directory. |
| `rename <engine> <old> <new> [--force]` | Rename a tank (moves the dir, rewrites the alias, carries the login). |
| `migrate [<engine>] [--dry-run] [--force] [--keep-login]` | Adopt a hand-rolled config-dir + alias setup. |
| `alias <engine> <tank> [--name <n>]` | Write (or replace) a shell alias. Default name `<engine>-<tank>`. |
| `app <engine> <tank> [--terminal <app>] [--force] [--out <dir>]` | Generate a macOS `.app` launcher (default `~/Applications`). macOS only. `--terminal`: `terminal` (default), `iterm2`, `ghostty`. |

### Keep burning when a tank runs dry

| Command | What it does |
|---|---|
| `to [target] [tank]` | Carry this shell's session onward when a tank runs dry. **Bare `clikae to`** falls through to the next tank in your burn order (same engine → a real resume; a different engine → a cold-start brief). Your tanks are the reserve — nothing to configure. |
| `auto [ask\|safe\|full]` | **(BETA, claude)** How much clikae carries on its own when a session you launched through it hits the limit. `ask` (default) prompts; `safe` auto-resumes same-engine + asks to cross; `full` just keeps going. The board's `A` key flips it too. |
| `watch <engine> [<tank>] [--auto] [--to <target>]` | Watch a session and fall through to the next tank in the burn order when it runs dry (cross-engine via `--to`). |
| `burn <engine> <tank> --artifact <path> -- <cmd…>` | Run a **headless** task on a tank; verify it by the artifact (not the exit code); on a dry tank, re-fire the same task on the next reserve tank. The headless sibling of `to`/`watch`. See "Headless tasks" below. |

> **Supervised launch (BETA · claude · feedback welcome).** When you start claude
> *through* clikae, clikae stays as the parent. **When that session ends after
> hitting its limit** — quit the dead session in an interactive run; a headless
> `claude -p` exits on its own — clikae carries you onward to the next tank in your
> burn order (per `clikae auto`) in the **same terminal** (one redraw), and your
> conversation continues there. Honest limits: it advances *on exit*, not by killing
> a live session mid-stream (that needs engine support — see issue
> anthropics/claude-code#35744); one hop per run; interactive **codex** can't be
> auto-detected (no file signal) so it's claude-only for now. Nothing runs in the
> background unless you launched it through clikae (no daemon) — deliberate.
> `clikae status` shows what it carried (recent carries). **Tell us how it feels.**

### Inspect

| Command | What it does |
|---|---|
| *(no args)* | Open the **home dashboard** — your "tank board": every tank grouped by engine, the one active in this shell marked, account + alias name, an "Also available" list of engines/targets you can open without a tank (e.g. `codex`, `agy`). On a terminal it's an **interactive launcher**; press `?` for the full key legend. Keys: ↑/↓·`j`/`k`·Tab/Shift-Tab move, `g`/`G` top/bottom, `1`-`9` jump, ⏎ open (a Continue row offers _resume_ vs _switch fresh_), `r` carry session, `x` incognito, `n` new, `a` rename the tank, `d` delete, `/` filter, `h` cycle language, `q`/Esc quit. Piped/scripted it prints the same board as plain text (`CLIKAE_NO_INTERACTIVE` forces that). |
| `lang [en-US\|ja-JP\|zh-TW]` | Show or set the interface language (dashboard + prompts). Persists to `$CLIKAE_HOME/lang`; the board's `h` key flips it live. Resolution when unset: `$CLIKAE_LANG` > saved choice > `$LANG`/`$LC_ALL` > en-US. |
| `tanks [-p\|--paths] [--json]` | List all tanks, with the logged-in account where the adapter can tell. (Aliases: `list`, `ls`.) `--json` emits machine-readable output ({cli, profile, account, path}) for scripts and the GUI. |
| `status [<engine>] [--json]` | Show which tank each engine is on **in this shell**. `--json` emits one object per engine with a `state` enum. |
| `doctor` | Read-only health check: which supported engines are installed and logged in, how many tanks each has, the environment, and what to do next. |
| `info [--json]` | Show install paths, platform, adapters, and tank count. |
| `adapters` | List supported engines with descriptions. |
| `demo` | A 30-second guided tour in a throwaway sandbox — shows isolated tanks, the tank board, and the `to` idea (your tanks are the reserve), then cleans up. Touches nothing real; the accounts are simulated, so it needs no installed engine. |

### Antigravity (agy) — same verbs, one power mode

agy hardcodes `~/.gemini` and ignores env vars, so clikae can't switch it
per-shell like other engines. It folds into the **same verbs** anyway, via an
opt-in symlink-swap power mode (global: one tank active at a time across all
terminals; reversible):

| Command | What it does |
|---|---|
| `init agy <tank>` | First time: warns and asks before taking `~/.gemini` over (backs it up, migrates your current login into a `default` tank), then creates `<tank>`. After: just creates the tank. |
| `agy <tank>` | Switch the active tank (refuses if agy is running) and start agy. Prints a global-switch notice. |
| `remove agy <tank>` | Remove the tank. Removing the **last** tank offers to restore a normal `~/.gemini` and turn the power mode off. |
| `agy --release` | Restore a normal single-account `~/.gemini` from the active tank, keep the tank dirs. |

## Shells

`clikae` auto-detects your shell from `$SHELL` and writes the alias to the right
rc file: **zsh** (`~/.zshrc`), **bash** (`~/.bash_profile` on macOS, else
`~/.bashrc`), and **fish** (`~/.config/fish/config.fish`). For fish it emits fish
syntax — `alias <name> 'env VAR=val <binary>'` — because fish has no inline
`VAR=val cmd`; the result behaves identically. `clikae remove` cleans up the
block in any of them.

## Migrating an existing setup

Already juggling accounts by hand — say a `~/.claude-acct-a` / `~/.claude-acct-b`
pair with aliases in your `~/.zshrc`? `clikae migrate` adopts that into clikae:

```bash
clikae migrate --dry-run   # preview: which dirs move where, which aliases change
clikae migrate             # do it (asks to confirm first)
```

It scans your shell rc for aliases that set the engine's config env var and
invoke the engine. For each one it:

1. moves the referenced config directory under `~/.clikae/profiles/<engine>/<p>/`,
2. rewrites the alias into clikae's managed sentinel block.

The rc file is backed up to `<rc>.clikae.bak.<timestamp>` first, and an existing
clikae tank is never overwritten. Pass an engine name (`clikae migrate gh`) to
migrate a different tool's aliases. Default is `claude`.

> ⚠️ **Don't migrate a config dir that's currently in use.** `migrate` *moves*
> the directory, so if a process is running against it right now (e.g. you run
> `clikae migrate` from inside the very `claude` session whose
> `CLAUDE_CONFIG_DIR` points at the dir being moved), you pull the directory out
> from under that live process — it can fail to write, or recreate an empty dir
> at the old path and leave you with two half-states. Run `migrate` from a fresh
> shell with no instance of that engine active. `--dry-run` is always safe.
>
> As of v0.4, `migrate` guards against the most common form of this: if
> `$CLAUDE_CONFIG_DIR` (or whichever env var the adapter uses) currently points
> at a directory slated to move, it refuses and tells you to retry from a fresh
> shell. The guard is not bypassed by `--force` — it protects your data, it
> isn't a confirmation prompt.

> 🔑 **macOS + claude: expect a one-time re-login per migrated tank.** On
> macOS, Claude Code keeps its login token in the **login Keychain**, not inside
> `CLAUDE_CONFIG_DIR` — and the keychain entry is keyed by the config-dir path.
> Because `migrate` moves the dir to a new path, claude no longer finds the token
> and asks you to log in once for each migrated tank. Your data is intact;
> only the saved login doesn't follow the move. To avoid the re-login, pass
> `--keep-login`, which copies the saved token from the old path's keychain entry
> to the new one (macOS only; it never reads or transmits the token anywhere — it
> stays in your Keychain). macOS may prompt you to allow keychain access.

## Carrying a session when you hit a usage limit — `clikae to`

This is clikae's origin story: you keep a second account precisely because one
account's quota runs out mid-task. `clikae to` lets you carry the work onward —
like swapping a fuel tank — and **keep the same conversation going** on a fresh
quota.

```bash
# You're working on claude tank `a` and just hit its limit. From the same project
# directory, carry the conversation onto another tank and keep going:
clikae to b                     # same engine → a real resume, on b's quota
clikae to codex                 # a different engine → a written brief (cold start)
clikae to codex work            # cross to a specific tank of another engine
```

clikae auto-detects which engine + tank this shell is on: first the live env var,
then — since the bare switch / aliases / `.app` run the engine with a prefix
assignment that never reaches the parent shell — **the tank with this directory's
most recent session** (the one you were just in here). So `switch → work → to`
works from one shell. To pin a shell to a tank explicitly instead, use
`eval "$(clikae env <engine> <tank>)"`. The target resolves **engine-name-first**:
a known engine name crosses to it; anything else is a tank of your current engine.
clikae always **announces which mechanism it used** so resume-vs-brief is never a
guess.

**Same engine (a resume).** For Claude Code, clikae finds the **current
directory's** most recent transcript under the source tank, copies it into the
target tank, and runs `claude --resume <id>` there — so the conversation
continues, but every new turn burns the target tank's quota. The source tank is
left completely untouched (it copies, never moves), so you can always go back.
A preview + confirm is shown before anything moves; `-y` skips it, `--fresh`
switches tanks without carrying, `--session <id>` carries a specific session.

> Carry-over relies on Claude Code's on-disk transcript layout
> (`<config-dir>/projects/<slug>/<id>.jsonl`) and `--resume`. It's verified
> against current Claude Code; if a future version changes that layout, it falls
> back to a fresh start rather than doing anything destructive.

**A different engine (a brief).** A different *model* or *vendor* can't resume a
foreign session — there's no shared transcript format. So clikae writes a
**handoff brief** (what you're doing, what's done, what's next) and starts the
target engine seeded with it as the opening prompt. By default the brief is a
**raw extract** (session metadata + your recent prompts), clearly labelled as
raw. For a proper summary, point clikae at a **local or cheap model** so writing
the brief costs nothing on the tank that just ran dry:

```bash
export CLIKAE_HANDOFF_SUMMARIZER='llm -m my-local-model'   # any stdin→stdout command
clikae to codex                                            # the model writes the brief
```

The summarizer receives, on stdin, an instruction line followed by the tail of
the session transcript, and writes the brief to stdout. If it produces nothing,
clikae falls back to the raw extract so a handoff is never lost. Tune how much
transcript is fed with `$CLIKAE_HANDOFF_LINES` (default `60`). Carrying onward is
**read-only** on the source — it never touches the source session or any tank.

> Under the hood, `clikae to` delegates to `relay` (same engine) or `handoff`
> (different engine). Both remain available as hidden aliases — e.g. `clikae
> handoff claude --out HANDOFF.md` just writes a brief to a file without starting
> anything. Run `clikae help to` / `help relay` / `help handoff` for details.

## Ambient: notice a dry tank and switch (`watch`)

Instead of switching by hand, let clikae watch for the moment a tank runs dry and
fall through to the next one. **Your tanks are the reserve — there's nothing to
set up.** Just watch the current session:

```bash
clikae watch claude            # offer to switch to the next claude tank when dry
clikae watch claude --auto     # switch automatically (asks once for consent)
clikae watch claude --to codex/work   # cross to a specific tank/engine instead
```

When it detects a dry tank it carries onward to the next tank of the same engine
(skipping any that are themselves over quota); cross-engine needs an explicit
`--to`. By default it **asks first**; `--auto` switches
automatically after a **one-time consent** (remembered in
`$CLIKAE_HOME/auto-relay-consent` — delete that file to revoke), and always tells
you what it did.

> **Honest caveat.** An interactive engine hitting its usage limit doesn't exit,
> returns no code, and fires no hook — so the only thing clikae can watch is what
> the limit writes to disk. For claude that's the session transcript; for agy
> it's `~/.gemini/antigravity-cli/cli.log` (agy's `-p` run exits 0 with empty
> output, so the log line is the only signal). codex's limit is **proven not
> persisted** to its transcript, so a dry tank can't be detected for codex from
> disk. Confirm/tune the match the first time you actually get limited:
>
> ```bash
> clikae watch claude --check          # would the pattern fire on this session?
> CLIKAE_LIMIT_PATTERN='…' clikae watch claude   # override the match
> ```

## Headless tasks across tanks — `clikae burn`

`watch`/`auto` carry an *interactive* session. For *headless* grunt work — the
"let the cheaper tank do the dirty work" case — use `clikae burn`. It runs one
task on a tank and, crucially, knows whether it actually finished: it verifies by
the **artifact** the task must produce, never the exit code (`codex exec` exits 0
even when it hit its usage limit and wrote nothing). If the tank ran dry, it
re-fires the *same* task on the next tank in your reserve.

```bash
# Distil a file with codex on tank M; if M is dry, fall through to your next
# codex tank automatically. Success = /tmp/out.md exists.
clikae burn codex M --artifact /tmp/out.md -- \
    exec -C /tmp -s workspace-write "read /tmp/in.txt, write /tmp/out.md"

clikae burn codex M --artifact /tmp/out.md --to codex/H -- exec … "<task>"   # explicit next hop
clikae burn codex M --artifact /tmp/out.md --timeout 300 -- exec … "<task>"  # bound a long run
```

Outcomes: artifact present → done; dry on every reachable tank → fail; ran but
produced no artifact and showed no limit → a real **task failure** (not rerouted —
it would fail the same everywhere). `--no-reroute` runs once and stops on a dry tank.

`burn` is the single-task unit — **batch/parallelism stays your orchestrator's
job** (fan several `burn`s out, review the artifacts). Make tasks idempotent and
artifact-checked (fixed input/output paths), and pre-stage inputs to `/tmp` rather
than handing a tank slow iCloud-backed I/O. agy can't be burned (it's global /
single-account, not per-tank-headless).

## Seeing which tank you're on

```bash
clikae status            # every engine that has a tank
clikae status claude     # just one

#   ENGINE       TANK         ACCOUNT          SOURCE
#   claude       cver         hi@cver.net      CLAUDE_CONFIG_DIR=…/profiles/claude/cver
#   aws          (default)    -                AWS_PROFILE unset — system default
```

`status` reads the **live** value of each adapter's env var in the current shell
and resolves it back to a clikae tank. It's a per-shell view: another terminal
(or one launched from a different `clikae app`) can be on a different tank.
`(default)` means the env var is unset (the engine's own default); `(external)`
means it points somewhere that isn't a clikae tank. The ACCOUNT column shows
the logged-in account when the adapter can tell.

## Naming your tanks

Name tanks however makes sense to you — `work`, `personal`, a client name, or
the account email. You don't have to remember what a bare `a`/`b` meant: both
`tanks` and `status` show the logged-in **account** when the adapter can read it.

Changed your mind about a name? `clikae rename` moves the directory, rewrites the
managed alias, and — for claude on macOS — carries the saved Keychain login
across so you don't have to log in again:

```bash
clikae rename claude a cver        # a → cver; login + alias follow
```

It refuses if the new name is taken or if that engine is currently using the tank
in this shell (run it from a fresh shell). A pre-existing `.app` launcher is left
alone but flagged — recreate it with `clikae app claude cver`.

## Ephemeral memory (`--ephemeral`)

For the surgical, leave-no-trace run: `clikae claude work --ephemeral` switches to
the tank and runs it, but points the engine's **long-term memory** at a throwaway
directory that's discarded when the engine quits. The tank's real memory is
stashed aside and restored, untouched.

```bash
clikae claude work --ephemeral     # incognito: nothing learned this session is kept
```

- **Login and transcripts are normal** — only the *memory store* is throwaway
  (you're still you, the conversation is still logged/resumable).
- **Honest scope:** clikae guarantees the *memory directory* is a throwaway. It
  can't promise the engine "remembers nothing anywhere" — caches, shell history,
  telemetry, the macOS Keychain are outside clikae's reach. So it's *ephemeral
  memory*, not guaranteed total amnesia.
- Supported only for engines whose memory layout clikae knows (currently
  **claude**); others say so and exit.
- Unlike a normal switch (which `exec`s the engine), `--ephemeral` runs it as a
  child so cleanup can run on exit. A crashed run self-heals on the next
  `--ephemeral` (the real memory is recovered from its stash).

## How it works

For each tank, `clikae`:

1. Creates `~/.clikae/profiles/<engine>/<tank>/` — the directory the engine's env
   var (e.g. `CLAUDE_CONFIG_DIR`) points at. (The on-disk path keeps the word
   `profiles` for stability; you only ever type/​see *tank*.)
2. (`alias`) Appends a sentinel-wrapped block to your shell rc:
   ```
   # >>> clikae:claude.work >>>
   alias claude-work='CLAUDE_CONFIG_DIR="/Users/you/.clikae/profiles/claude/work" claude'
   # <<< clikae:claude.work <<<
   ```
   The sentinels make safe, exact removal possible.
3. (`app`, macOS) Generates an AppleScript-compiled `.app` that opens a terminal,
   runs the env-var-prefixed engine, and sets the window title to `claude (work)`
   so you can tell windows apart. The terminal is **Terminal.app** by default;
   `--terminal iterm2` and `--terminal ghostty` target those instead (set
   `$CLIKAE_TERMINAL` to change the default). Terminal.app and iTerm2 are driven
   by AppleScript; Ghostty has no window-opening CLI on macOS, so its launcher
   goes through `open -na Ghostty.app --args … -e …`.

No daemons, no global state, no network calls. You can read every line.

## Supported engines

| Engine | Strategy | Env var |
|---|---|---|
| `claude` (Anthropic Claude Code) | `env-dir` | `CLAUDE_CONFIG_DIR` |
| `codex` (OpenAI Codex CLI) | `env-dir` | `CODEX_HOME` |
| `gh` (GitHub CLI) | `env-dir` | `GH_CONFIG_DIR` |
| `gcloud` (Google Cloud CLI) | `env-dir` | `CLOUDSDK_CONFIG` |
| `docker` (Docker CLI) | `env-dir` | `DOCKER_CONFIG` |
| `helm` | `env-dir` | `HELM_CONFIG_HOME` |
| `kubectl` | `env-file` | `KUBECONFIG` |
| `aws` (AWS CLI) | `env-var` | `AWS_PROFILE` |
| `az` (Azure CLI) | `env-dir` | `AZURE_CONFIG_DIR` |
| `npm` | `env-file` | `NPM_CONFIG_USERCONFIG` |
| `terraform` | `env-file` | `TF_CLI_CONFIG_FILE` |
| `pulumi` | `env-dir` | `PULUMI_HOME` |
| `vercel` (Vercel CLI) | `flag` | — (`--global-config <dir>`) |
| `agy` (Google Antigravity) | opt-in symlink | — (hardcoded `~/.gemini`; see above) |

The `flag` strategy is for engines with no config-directory env var: the tank
directory is injected as a command-line flag (e.g. vercel's `--global-config`)
in the generated alias / `.app` / run command instead of an exported variable.
Such an engine shows `(n/a)` in `clikae status` (there's nothing in the
environment to read back).

Run `clikae adapters` to see them with descriptions. Adding your own is ~10
lines of bash — see [adding-an-adapter.md](adding-an-adapter.md).

> **Note on `aws`:** unlike the others, the AWS adapter doesn't isolate config
> into a separate directory — `AWS_PROFILE` selects a *named profile* from your
> existing `~/.aws/config`. So `clikae init aws work` expects a matching
> `[profile work]` entry to exist. See the comment at the top of
> `lib/adapters/aws.sh` for the alternative `env-file` approach.

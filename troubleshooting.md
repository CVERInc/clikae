---
title: "Troubleshooting"
description: "clikae (CLI-Kae / ｷﾘｶｴ) — An on-ramp for AI coding CLIs: land on your recent sessions across every Claude Code, Codex, Grok & Antigravity account, each with a recap of where you left off."
canonical: "https://clikae.cver.net/troubleshooting"
---
# Troubleshooting

## `clikae: command not found`

The launcher symlink isn't on your `PATH`. `install.sh` puts it at
`$PREFIX/bin/clikae` (default `~/.local/bin/clikae`). Add that directory to your
`PATH` in your shell rc:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new shell or `source` your rc. Confirm with `clikae version`.

## My new alias doesn't work

Aliases are written into your shell rc, which is only read when a shell starts.
After `clikae init … --alias` (or `clikae alias …`), either open a new terminal
or re-source the rc file:

```bash
source ~/.zshrc        # or whichever rc clikae reported writing to
```

clikae picks the rc file from your `$SHELL`:

| Shell | rc file |
|---|---|
| zsh | `~/.zshrc` |
| bash (macOS, if it exists) | `~/.bash_profile` |
| bash (otherwise) | `~/.bashrc` |
| anything else | `~/.profile` |

If your aliases live in a different file (e.g. you keep everything in
`~/.zprofile`), source the clikae block from the file clikae wrote, or move the
sentinel-wrapped block by hand.

## Switching works but the engine won't start: "'claude' isn't installed"

clikae switches **accounts/configs**; it does **not** install the underlying CLI.
If you switch to a tank whose engine binary isn't on your `PATH`, clikae sets the
tank and then stops with a clear message instead of a bare `exec: …: not found`:

```
Switched to claude/work, but 'claude' isn't installed (not on your PATH).
Install it, then retry:  npm install -g @anthropic-ai/claude-code
```

Install the engine (e.g. `npm install -g @anthropic-ai/claude-code`,
`npm install -g @openai/codex`) and run the tank again. If it's installed but
clikae still can't find it, your launcher is probably using a **non-login** shell:
make sure the install dir (`~/.local/node/bin`, `/opt/homebrew/bin`, …) is on the
PATH of the shell that runs clikae. A login shell (`zsh -l`) sources your rc, so a
`.app`/Dock launcher should run `zsh -lc`.

## The `.app` won't open: "cannot be opened because it is from an unidentified developer"

The launcher is compiled locally with `osacompile` and is **not code-signed or
notarized**, so macOS Gatekeeper blocks it on first launch. This is expected for
a tool that builds the app on your own machine. To open it:

- **Right-click (or Control-click) the `.app` → Open → Open.** You only need to
  do this once per launcher; after that double-clicking works.
- Or: System Settings → Privacy & Security → scroll to the blocked-app notice →
  **Open Anyway**.

## `aws` profile doesn't switch

The AWS adapter uses `AWS_PROFILE`, which selects a *named profile* from your
existing `~/.aws/config` — it does **not** create an isolated config directory.
`clikae init aws work` expects a matching `[profile work]` section to already
exist in `~/.aws/config`. If it doesn't, add it (or use the `env-file`
alternative documented at the top of `lib/adapters/aws.sh`).

## I removed a profile but a leftover remains

`clikae remove` deletes the profile directory, the alias block, and the `.app` —
each only if present, each independently. If something survived:

- **Alias still in your rc:** clikae only manages blocks wrapped in its
  sentinels (`# >>> clikae:<cli>.<profile> >>>` … `# <<< … <<<`). A hand-edited
  or hand-written alias outside those markers is left for you to remove.
- **`.app` in a custom location:** if you created it with `--out <dir>`, remove
  it from that directory by hand.
- Used `--keep-data`? That intentionally keeps the profile directory under
  `~/.clikae/profiles/`.

## After migrating, claude's startup screen looks different (macOS)

A migrated profile may open with the **compact** logo while another shows the
**full welcome box** (`Welcome back …` + Tips + What's new). This is **not**
caused by clikae or the move. Claude Code picks the header from counters in that
profile's `.claude.json` (whether you've seen the current release notes and the
Opus 4.8 banner) plus the `CLAUDE_CODE_FORCE_FULL_LOGO` env var — never from the
config-dir path. A well-used profile that has already seen the announcements
shows the compact logo; that state moved with the directory unchanged. To force
the full box, set `CLAUDE_CODE_FORCE_FULL_LOGO=1`. Details and the decompiled
logic: [Claude on macOS](/claude-on-macos.md).

## I want to undo a change to my shell rc

Every rc edit is backed up first to `<rc>.clikae.bak.<timestamp>` next to the rc
file (e.g. `~/.zshrc.clikae.bak.20260605-143000`). Restore the most recent backup:

```bash
cp ~/.zshrc.clikae.bak.<timestamp> ~/.zshrc
```

## Two project folders with non-ASCII names share one Resume list

Claude Code names a project's transcript directory by replacing every byte
outside `[A-Za-z0-9]` with `-`. Two sibling folders whose names differ only in
non-ASCII characters of the same length (`~/專案一` and `~/專案二`, for example)
therefore land in the **same** `projects/<slug>` directory, and the home
board's Continue list — which reads that directory — shows their sessions
merged. clikae reports what is on disk; it cannot tell the two folders apart
after the engine has collapsed them. The workaround is a distinguishing ASCII
element in the folder name (`~/專案一-a`, `~/專案二-b`). Tracked upstream; see
issue #116 for the measurement.

## Developing / running the tests

clikae stays Node-free; local checks use `shellcheck` and `bats`. Run the gate —
it is exactly what CI runs, so a green gate means a green CI:

```bash
brew install shellcheck bats-core
bash scripts/test.sh
```

If you invoke the tools directly instead, **run bats with `-r`**:

```bash
bats -r tests/bats
```

Without `-r`, bats does not recurse into `tests/bats/adapters/` and silently skips
every adapter test — the run still reports success, just with ~50 fewer tests than
you think. (CI was bitten by this once.)

See [HANDOFF.md](https://github.com/CVERInc/clikae/blob/0ffc56953dd1988ffafd263c6751fd8d24904933/HANDOFF.md) for the full verification recipe, including an
isolated end-to-end run that doesn't touch your real `$HOME` — and for what the
gate cannot see (anything interactive: the board, the resume picker, `clean`).

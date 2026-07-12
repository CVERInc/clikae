# Troubleshooting

## `clikae: command not found`

The launcher symlink isn't on your `PATH`. `install.sh` puts it at
`$PREFIX/bin/clikae` (default `~/.local/bin/clikae`). Add that directory to your
`PATH` in your shell rc:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new shell or `source` your rc. Confirm with `clikae info`, which
prints the resolved install paths.

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
`.app`/Dock launcher should run `zsh -lc` — which clikae's own `.app` launchers do.

## The `.app` won't open: "cannot be opened because it is from an unidentified developer"

The launcher is compiled locally with `osacompile` and is **not code-signed or
notarized**, so macOS Gatekeeper blocks it on first launch. This is expected for
a tool that builds the app on your own machine. To open it:

- **Right-click (or Control-click) the `.app` → Open → Open.** You only need to
  do this once per launcher; after that double-clicking works.
- Or: System Settings → Privacy & Security → scroll to the blocked-app notice →
  **Open Anyway**.

## `clikae app` fails with "osacompile not found"

`osacompile` ships with macOS. If it's missing you're almost certainly not on
macOS — the `app` command is macOS-only. Use `clikae alias` (shell alias) or
`clikae run` instead.

## `clikae app` refuses to overwrite an existing launcher

By design — clikae never silently overwrites your files. Re-run with `--force`
to replace it:

```bash
clikae app claude work --force
```

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

## `clikae migrate` broke a running session / a moved dir reappeared empty

`migrate` *moves* the config directory into `~/.clikae/profiles/`. If the CLI
was actively using that directory at the time — the classic case is running
`clikae migrate` from inside the very `claude` session whose
`CLAUDE_CONFIG_DIR` is the dir being moved — the live process loses its
directory and may recreate an empty one at the old path. You end up with the
real data under `~/.clikae/profiles/<cli>/<p>/` and a stray empty dir at the old
location.

To avoid it: **run `migrate` from a fresh shell with no instance of that CLI
running.** `clikae migrate --dry-run` never moves anything, so preview freely.
Since v0.4, `migrate` also refuses outright when the live `$CLAUDE_CONFIG_DIR`
(or the adapter's env var) points at a dir it's about to move — so the most
common trigger now stops with a clear message instead of corrupting state.

To recover if it already happened: quit the affected CLI, delete the stray empty
old directory (after confirming it's empty), and re-source your shell rc — the
rewritten alias already points at the migrated profile.

## After `clikae migrate`, claude asks me to log in again (macOS)

Expected. On macOS, Claude Code stores its login token in the **login Keychain**,
not inside `CLAUDE_CONFIG_DIR` — and the keychain entry is keyed by the
config-dir *path* (`Claude Code-credentials-<sha256(path)[:8]>`). `migrate` moves
the dir to a new path, so claude looks under a new keychain key, finds nothing,
and prompts you to log in. Your settings, history, and projects all moved fine;
only the saved login didn't follow.

Two ways to handle it:

- **Simplest:** just open each migrated profile once and log in again. The old
  keychain entries for the pre-migration paths are now orphaned and harmless; you
  can leave them or delete them in Keychain Access.
- **Avoid it up front:** run `clikae migrate --keep-login`, which copies the
  saved token from the old path's keychain entry to the new one as part of the
  move (macOS only). The token never leaves your Keychain. macOS may pop a dialog
  asking you to allow keychain access — that's expected.

If you already migrated without `--keep-login`, re-running with it won't help:
`migrate` skips profiles it has already moved, so the carry-over step never runs
for them. Just log in once per profile — that's the simplest path.

The full story (keychain key format, manual recovery) is in
[Claude on macOS](/claude-on-macos.md).

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

## Developing / running the tests

clikae stays Node-free; local checks use `shellcheck` and `bats`:

```bash
brew install shellcheck bats-core
shellcheck bin/clikae lib/**/*.sh install.sh
bats tests/bats
```

See [HANDOFF.md](https://github.com/CVERInc/clikae/blob/b082cff4d3e3f0c651dd51bbc558c5805f8b4ef5/HANDOFF.md) §6 for the full verification recipe, including an
isolated end-to-end run that doesn't touch your real `$HOME`.

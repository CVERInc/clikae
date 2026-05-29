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

To recover if it already happened: quit the affected CLI, delete the stray empty
old directory (after confirming it's empty), and re-source your shell rc — the
rewritten alias already points at the migrated profile.

## I want to undo a change to my shell rc

Every rc edit is backed up first to `<rc>.clikae.bak.<timestamp>` next to the rc
file (e.g. `~/.zshrc.clikae.bak.1730000000`). Restore the most recent backup:

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

See [HANDOFF.md](../HANDOFF.md) §6 for the full verification recipe, including an
isolated end-to-end run that doesn't touch your real `$HOME`.

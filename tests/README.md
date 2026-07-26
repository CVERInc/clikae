# tests

[bats-core](https://github.com/bats-core/bats-core) test suite.

## Layout

```
tests/
├── helpers.bash              # shared setup/teardown (isolated $HOME + $CLIKAE_HOME)
├── tools/
│   └── pty-smoke.py          # real-pty driver for the interactive screens (GATED)
└── bats/
    ├── <one .bats per command / core lib>   # init, alias, list, remove, burn, clean, …
    ├── app.bats              # macOS-only, skipped elsewhere
    ├── compat.bats           # bash 3.2 / GNU-ism guards + the PowerShell adapter-table mirror
    ├── tui.bats              # the shared keyboard decoder
    └── adapters/             # claude, codex, extra, session-meta
```

`bats/` is one file per command or core library — roughly forty of them; the names
above are the ones with a rule attached rather than a full listing.

**`tools/pty-smoke.py` is the third leg of the gate.** shellcheck reads source and
bats never presses a key, so both are structurally blind to the TUI — which is where
this project's regressions keep landing. pty-smoke drives the real binary on a real
pty, in a throwaway `$HOME` it builds itself, with `CLIKAE_LANG=en-US` pinned and a
stub engine on `PATH`. It never touches your store and never launches a real engine.

```bash
python3 tests/tools/pty-smoke.py all       # what the gate runs
python3 tests/tools/pty-smoke.py prompts   # just the prompt / stderr checks
```

Its `prompts` mode is the regression net for a specific failure: bash writes
`read -p` prompts to **stderr**, so when the board's stderr was accidentally
redirected to `/dev/null`, three prompts went blank while the process stayed alive
and kept accepting input — a hang that no test could see. Every assertion in that
mode is about something *reaching the terminal*, including the engine's own stderr
after the board `exec`s into it.

**When you add an assertion here, prove it can fail.** Check out a commit from
before the fix into a worktree, copy this file in, and confirm the new check goes
red — an interactive assertion that passes on the broken code is decoration.

Every test runs against a throwaway `$HOME` and `$CLIKAE_HOME` created with
`mktemp`, so the suite never touches your real config or shell rc. `$SHELL` is
pinned to `/bin/zsh` so the detected rc file is deterministic.

## Run

```bash
brew install bats-core        # or: https://bats-core.readthedocs.io/
bats -r tests/bats            # -r recurses into adapters/ (without it, those skip silently)
```

The `app.bats` cases need `osacompile` (a macOS built-in) and are skipped
automatically on Linux.

## Never read the result through a pipe

```bash
bats -r tests/bats | tail -5; echo $?     # ❌ reports tail's exit status — always 0
bats -r tests/bats                        # ✅ the shell sees bats' own exit status
```

A pipeline's exit status is its **last** command's, and `tail`/`head` succeed
whatever they were fed. This has masked real failures here before: a run with five
failing tests reported success because the verdict was read off `tail`. If you need
both the output and the verdict, redirect to a file and check `$?` on its own line:

```bash
bats -r tests/bats > /tmp/bats.log 2>&1; echo "EXIT=$?"
```

## Every assertion must count — the `|| false` convention

bats fails a test only on its **last** command's exit status; an intermediate
assertion that fails is otherwise **silently ignored**, so a stale assertion can
stay green while the code is wrong. We close that gap two ways:

1. **`set -e` in `setup()`** (helpers.bash) persists into the test body, so a
   failing `[ … ]` or any bare command aborts the test immediately.
2. **bash exempts `[[ … ]]` from `set -e`** (`set -e; [[ 1 == 2 ]]` does *not*
   exit — a real bash quirk). So every standalone `[[ … ]]` assertion carries an
   explicit **`|| false`**:

   ```bash
   [[ "$output" == *"some text"* ]] || false      # ✅ fails the test if missing
   [[ "$output" == *"some text"* ]]                # ❌ silently ignored mid-body
   ```

**When you add a `[[ … ]]` assertion, append `|| false`.** Plain `[ … ]` checks
don't need it. If a command in a test body may legitimately return non-zero and
is *not* an assertion, guard it with `|| true`. Sanity check (should print
nothing):

```bash
grep -rnE '^[[:space:]]*\[\[ .* \]\][[:space:]]*$' tests/bats
```

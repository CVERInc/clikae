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

## Proving a guard is load-bearing (`scripts/mutate.sh`)

A green suite says the code behaves on the inputs someone thought to write. It
does not say a guard exists. A test can assert an outcome the code reaches for
some other reason — or never call the function it names at all:

```bash
run bash -c 'wake_ask_once claude work < /dev/null'
```

`bash -c` forks, and shell functions do not cross a fork. That line asserted
that a "command not found" message lacks the word ASKED, which is true however
`wake_ask_once` behaves. It passed for two months. (Fixed 2026-08-16; the other
25 `bash -c` sites in the suite were swept and are all real subprocesses.)

The only evidence that a guard is load-bearing is watching the suite go red when
you take it away. `scripts/mutate.sh` does that for docs/memory.md §4's locked
values — the promises clikae makes about the human's data. It is **not** part of
`scripts/test.sh`: it copies the repo per mutation, so it costs minutes.

```bash
scripts/mutate.sh      # 4 guard(s) proven, 0 hollow
```

Add a row when you add a guard worth that. Two traps, both hit on the first run:

- **A mutation that did not apply looks exactly like a working guard.** The
  first run reported three hollow guards; all three were the ruler (the function
  lived in another file, or I guessed its name). Every row checksums its target
  before and after, and a no-op mutation reports ⛔ rather than a verdict.
- **Use `!` as the `s///` delimiter, never `{}`.** Perl needs balanced braces
  inside `s{}{}`, and a shell function's replacement almost always has an
  unmatched `{` — perl dies of a syntax error, the file is untouched, and you
  land in the trap above.

## Checks the suite cannot make (`scripts/verify-*.sh`)

Some claims are about the real machine, and bats cannot reach them. These are
run by hand, and each reports **three** states — a check it could not perform is
`skip`, never a pass, because the bug being guarded against is a green light
that means "I did not look".

| script | the claim it checks | why not a bats test |
|---|---|---|
| `verify-tmux-birth.sh` | DESIGN-tmux Rule 7: what the tmux **server** inherited at birth | a property of a real server against real macOS TCC; the suite covers the logic with an injected stub |
| `verify-agy-shapes.sh` | the agy adapter's model of agy still matches agy | it parses a self-updating vendor binary's undocumented files; fixtures only prove the parser matches *our* model of the format |

`verify-agy-shapes.sh` is the answer to a specific hole. `antigravity.bats` is
green against fixtures we wrote, so if agy renames a key tomorrow, every one of
those tests still passes. This runs the same extraction against the real files
agy wrote on this machine — including the *rate* (`"workspace"` on 646/646
history lines across 3 tanks, verified 2026-08-16 against agy 1.1.13), because a
single surviving line satisfies `grep -q` while the feature is broken for
everything else.

Its own first draft is worth knowing about. `grep -c` **prints `0` and exits
`1`** when nothing matches, so a `|| echo 0` fallback fired *as well* and the
arithmetic got `"0\n0"` — a syntax error that killed the script mid-run while it
still exited 0. Every individual check was correct; the only thing that could
have caught it was the total. So the script now fails with a distinct code when
it performed no checks at all.

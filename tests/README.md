# tests

[bats-core](https://github.com/bats-core/bats-core) test suite.

## Layout

```
tests/
├── helpers.bash              # shared setup/teardown (isolated $HOME + $CLIKAE_HOME)
└── bats/
    ├── init.bats
    ├── alias.bats
    ├── list.bats
    ├── remove.bats
    ├── app.bats              # macOS-only, skipped elsewhere
    ├── compat.bats           # guards against bash 4+/GNU-isms (bash 3.2 must work)
    └── adapters/
        └── claude.bats
```

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

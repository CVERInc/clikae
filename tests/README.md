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
bats tests/bats
```

The `app.bats` cases need `osacompile` (a macOS built-in) and are skipped
automatically on Linux.

# tests

Reserved for v0.2 — bats-core test suite.

Planned layout:

```
tests/
├── helpers.bash              # common test helpers
├── bats/
│   ├── init.bats
│   ├── alias.bats
│   ├── app.bats              # macOS-only, skipped on Linux
│   ├── list.bats
│   ├── remove.bats
│   └── adapters/
│       └── claude.bats
└── fixtures/                 # sample profile dirs, mock CLIs
```

Run with:

```bash
brew install bats-core
bats tests/bats
```

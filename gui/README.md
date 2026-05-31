# gui

macOS menu bar app for clikae (v1.0 track).

The CLI is the source of truth; the GUI just calls it (`clikae list`,
`clikae status`, `clikae run`, `clikae relay`). It does not reimplement
profile-storage logic in Swift.

## ClikaeMenuBar

A SwiftPM + AppKit menu-bar app — builds with the Command Line Tools, no Xcode
needed. See [ClikaeMenuBar/README.md](ClikaeMenuBar/README.md) for what it does
and how to build/run it:

```bash
cd gui/ClikaeMenuBar && swift build && swift run
```

Current state: a build-verified **skeleton** (lists profiles per CLI, marks the
active one, click-to-launch, per-CLI relay submenu, refresh, quit). Next steps:
a packaged signed `.app`, login-item toggle, terminal preference, richer relay UX.

PRs from Swift developers welcome.

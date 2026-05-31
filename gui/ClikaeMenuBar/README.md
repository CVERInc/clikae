# ClikaeMenuBar

A macOS menu bar app for clikae. It lives in the menu bar (no Dock icon) and is a
thin front end over the `clikae` CLI — **the CLI is the source of truth**; this
app only shells out to it and never reimplements profile logic.

## What it does

Open the menu (the `ｷﾘ` item) and you get, rebuilt live each time:

- every profile grouped by CLI, with the **active** one (per `clikae status`)
  check-marked;
- **click a profile** to launch it — opens a terminal window running
  `clikae run <cli> <profile>`;
- a per-CLI **Relay → …** submenu to hand the active session to another profile
  (`clikae relay <cli> <from> <to>`) when one account hits its usage limit;
- **Refresh** and **Quit**.

It prefers **Ghostty** for the terminal it opens, falling back to Terminal.app.

## Build & run

No Xcode required — it builds with the Command Line Tools via SwiftPM:

```bash
cd gui/ClikaeMenuBar
swift build
swift run            # or: .build/debug/ClikaeMenuBar
```

`clikae` must be on your `PATH` (e.g. `brew install CVERInc/clikae/clikae`). The
app launches `clikae` through a login shell, so it picks up your normal PATH.

Run it from a real login session (it needs a window-server connection to add the
menu-bar item). To quit, use the menu's **Quit** item.

## Status

This is the **v1.0 skeleton** (AppKit `NSStatusItem`, build-verified). It proves
the architecture — drive everything through the CLI — and is intended to grow:
packaging as a signed, double-clickable `.app` (LSUIElement bundle), a login-item
toggle, per-CLI terminal preference, and a richer relay UX are the obvious next
steps. PRs from Swift developers welcome.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Built-in adapters for **GitHub CLI** (`gh`), **Google Cloud** (`gcloud`),
  **Docker** (`docker`), **Helm** (`helm`), **kubectl** (`kubectl`, the first
  `env-file` adapter), and **AWS** (`aws`, the first `env-var` adapter).
- `bats-core` test suite under `tests/bats/` (init, alias, list, remove, app,
  adapters, and bash-3.2 compatibility guards). Each test runs in an isolated
  throwaway `$HOME` + `$CLIKAE_HOME`.

### Fixed

- `clikae app` produced an uncompilable AppleScript on macOS: the command was
  substituted into the template with `sed`, but BSD/macOS `sed` strips
  backslashes from the replacement string, so the escaped `\"` collapsed to `"`
  and terminated the AppleScript string early. Substitution now uses bash
  parameter expansion (and escapes backslashes before quotes), so launchers
  compile and run correctly. This path was never exercised in v0.1.

## [0.1.0] — 2026-05-28

### Added

- Initial v0.1 scaffold: pure-bash CLI dispatcher (`bin/clikae`) with a small
  modular `lib/` (core, commands, adapters, templates).
- `clikae init <cli> <profile>` — create a profile under `~/.clikae/profiles/<cli>/<profile>`.
- `clikae alias <cli> <profile>` — write a managed alias block to the user's shell rc.
- `clikae app <cli> <profile>` — generate a macOS double-click launcher `.app`
  with a custom Terminal window title.
- `clikae run <cli> <profile> [-- args]` — run a CLI with a profile, no alias needed.
- `clikae list`, `clikae info`, `clikae adapters`, `clikae help`.
- `clikae remove <cli> <profile>` — atomically clean up the dir, alias block, and `.app`.
- Built-in adapter for **Anthropic Claude Code** (`CLAUDE_CONFIG_DIR`).
- Adapter template and developer guide for adding new CLIs.
- `install.sh` for `curl | bash` installs and a Homebrew formula template.
- MIT License.

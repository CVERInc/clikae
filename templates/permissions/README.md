# Claude permissions template

`claude.json` is the versioned seed from CVERInc/clikae #76, measured on the
reefbox Linux lane host on 2026-09-12. Shell prefixes are encoded as Claude
`Bash(command *)` rules; wildcard prefixes retain their wildcard. The five
file tools are bare tool names. Deny rules are carried alongside allow rules.
`/home/<user>/*` is expanded at apply time using the current OS username.

Apply with `clikae settings apply` (all Claude tanks), or
`clikae settings apply claude work`. `--dry-run` previews additions; `--check`
returns 1 for missing rules or unreadable/invalid settings. Extra tank rules
are not drift and are never removed. Existing order is retained; missing rules
are appended in sorted order. A compliant file is not rewritten. A changed
existing file is backed up as `settings.json.clikae.bak.*`, then replaced via
a same-directory temporary file and rename. Symlinked settings are skipped.

This seed includes broad shell and file access for headless Linux work. It does
not set `defaultMode` or configure macOS auto-mode classification. Edit the
versioned template to change the baseline; removing a rule from the template
does not revoke it from existing tanks.

`--add-dir` remains a launch flag, not a settings key. For a burn needing these
roots, pass `--add-dir` for each of `~/lanes`, `~/Developer`, `~/.local`,
`~/.config`, and `/tmp` (expand `~` in the invoking shell). No launch recipe is
changed by applying settings. Only Claude currently has a template.

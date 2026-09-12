# Claude permissions template

`claude.json` is the versioned seed from CVERInc/clikae #76, measured on the
reefbox Linux lane host on 2026-09-12 and extended in the #85 round-1 fix
(2026-09-12) with `Bash(CVER_KEY_BACKEND=*)`, `Bash(CVER_KEY_STORE=*)`,
`Bash(SOPS_AGE_KEY_FILE=*)` and `Bash(bash -n *)` — the env-prefixed and
dry-run forms of rules #76 already carried bare, without which a fresh tank
still hits the exact class of failure #76 reported. Shell prefixes are
encoded as Claude `Bash(command *)` rules; wildcard prefixes retain their
wildcard. The five file tools are bare tool names. Deny rules are carried
alongside allow rules. `/home/<user>/*` is expanded at apply time to the
current `$HOME` (so it becomes `/Users/<user>/*` on macOS, not a literal
`/home` path that doesn't exist there).

Apply with `clikae settings apply` (all Claude tanks), or
`clikae settings apply claude work`. `--dry-run` previews additions; `--check`
returns 1 for missing rules or unreadable/invalid settings. Extra tank rules
are not drift and are never removed. Existing order is retained; missing rules
are appended in sorted order. A compliant file is not rewritten. A changed
existing file is backed up as `settings.json.clikae.bak.*`, then replaced via
a same-directory temporary file and rename. Symlinked settings are skipped.
An allow rule that would exactly shadow a deny rule (the identical string in
both lists) is refused instead of written.

This seed includes broad shell and file access for headless Linux work. It does
not set `defaultMode` or configure macOS auto-mode classification. Edit the
versioned template to change the baseline; removing a rule from the template
does not revoke it from existing tanks. **The deny list is advisory, not a
sandbox**: an allow prefix like `Bash(bash *)` can itself run anything the deny
list tries to block (e.g. `bash -c 'sudo …'`), because these are prefix rules
on the literal command string, not a real permission boundary. Treat this
template as "reduce prompt friction for a trusted headless lane", not as
containment. Skip it entirely with `clikae init claude <tank> --no-template`
or `CLIKAE_NO_PERMISSIONS_TEMPLATE=1`.

`clikae settings apply` requires `jq`. A tank whose engine has no template
file, or a run with no `jq` on PATH, is reported and skipped — it never fails
`clikae init`, which always finishes creating the tank either way. An explicit
`clikae settings apply` call still exits nonzero in both cases so scripts can
tell the difference from a successful apply.

`--add-dir` remains a launch flag, not a settings key. For a burn needing these
roots, pass `--add-dir` for each of `~/lanes`, `~/Developer`, `~/.local`,
`~/.config`, and `/tmp` (expand `~` in the invoking shell). No launch recipe is
changed by applying settings. Only Claude currently has a template.

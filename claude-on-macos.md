# Notes: Claude Code on macOS

A record of two macOS-specific Claude Code behaviours that affect (or merely
*look* like they affect) clikae. Both were found while dogfooding `clikae migrate`
on a real dual-account Mac on 2026-05-29, then confirmed from the Claude Code
2.1.156 binary. Kept here so the next person who hits them doesn't have to
re-derive the cause.

The one-sentence summary: **on macOS, a Claude profile is not fully described by
its `CLAUDE_CONFIG_DIR` — the login token lives in the Keychain, and the startup
screen is driven by counters in `.claude.json`. clikae only sets
`CLAUDE_CONFIG_DIR`; it never touches either of those.**

---

## 1. The login token lives in the Keychain, keyed by the config-dir *path*

### What you see

After `clikae migrate` adopts a hand-rolled `~/.claude-acct-*` setup, opening
each migrated profile asks you to **log in again**, even though all your
settings, history, and projects clearly moved across intact.

### Root cause

On macOS, Claude Code does **not** store its OAuth token inside
`CLAUDE_CONFIG_DIR`. It stores it in the **login Keychain**, under a service name
keyed by the config-dir path:

```
Claude Code-credentials-<suffix>
```

where `<suffix>` is the first 8 hex chars of `sha256(<absolute CLAUDE_CONFIG_DIR, no trailing slash>)`.
(The bare `Claude Code-credentials`, no suffix, is the default `~/.claude`.)

`migrate` *moves* the config dir to a new path, which changes the hash, so Claude
looks under a new keychain key, finds nothing, and prompts you to log in. The
token does **not** travel with the moved directory; the old keychain entry is
left orphaned (harmless).

Verified on the maintainer's Mac:

| Config dir | Keychain suffix |
|---|---|
| `~/.claude-acct-a` | `739359e9` |
| `~/.claude-acct-b` | `a646a362` |
| `~/.clikae/profiles/claude/a` | `bb827224` |
| `~/.clikae/profiles/claude/b` | `30621b40` |

Check it yourself:

```bash
# The suffix for any config dir:
printf '%s' "$HOME/.clikae/profiles/claude/b" | shasum -a 256 | cut -c1-8
# The entries currently in your keychain:
security dump-keychain 2>/dev/null | grep -o '"Claude Code-credentials[^"]*"' | sort -u
```

### What clikae does about it

- **By default:** nothing — you log in once per migrated profile. This is a
  one-time cost; fresh `clikae init` + login is unaffected (each profile path
  gets its own keychain slot, which is exactly why accounts don't collide).
- **Opt-in:** `clikae migrate --keep-login` copies the saved token from the old
  path's keychain entry to the new one as part of the move, so the session
  survives. It's implemented as an optional adapter hook
  (`adapter_migrate_credentials`) in `lib/adapters/claude.sh`, off by default.
  The token never leaves your Keychain; macOS may prompt you to allow access.

To recover *after* an already-completed migration (the hook only runs during the
move), just log in once per profile — or copy the slot by hand:

```bash
old="Claude Code-credentials-$(printf '%s' "$HOME/.claude-acct-b" | shasum -a 256 | cut -c1-8)"
new="Claude Code-credentials-$(printf '%s' "$HOME/.clikae/profiles/claude/b" | shasum -a 256 | cut -c1-8)"
secret=$(security find-generic-password -s "$old" -w) \
  && security add-generic-password -a "$USER" -s "$new" -l "$new" -w "$secret" -U
secret=
```

---

## 2. The "Welcome back" box vs the compact logo is **not** a clikae effect

### What you see

A migrated profile (or any "well-used" profile) opens with the **compact** 3-line
logo (robot · `Claude Code vX` · model · cwd), while another profile opens with
the **full welcome box** (`Welcome back <name>!` + account + *Tips for getting
started* + *What's new*). It can look like migration "downgraded" the profile.

It didn't. The two are just at different points in Claude Code's own
announcement-fatigue logic.

### Root cause (confirmed from the 2.1.156 binary)

The startup header picks compact vs full with, in effect:

```js
if (!hasReleaseNotes && !O && !env.CLAUDE_CODE_FORCE_FULL_LOGO) return <compact logo>
else <full welcome box>
```

- `hasReleaseNotes` — true only while `.claude.json`'s `lastReleaseNotesSeen`
  differs from the running version.
- `O` — other announcements, notably the Opus 4.8 launch banner, gated by
  `opus48LaunchSeenCount < 8` (the binary's constant `k9O = 8`); every render
  increments the counter.
- `CLAUDE_CODE_FORCE_FULL_LOGO` — env var that forces the full box.

`firstParty` detection (`Zq()`) reads only env vars (`CLAUDE_CODE_USE_BEDROCK`
etc.), never a path.

**Every input is a counter in `.claude.json` or an env var — none is the
config-dir path.** Since `migrate` moves `.claude.json` byte-for-byte, the same
file renders the same header at the old path or the new one. A profile shows the
compact logo once it has seen the Opus 4.8 banner 8 times *and* its
`lastReleaseNotesSeen` matches the current version — i.e. there's simply nothing
new left to announce. That state is built up by real usage; the move doesn't
create or change it.

### Knobs

- Force the full box for a profile (clean, official env var):

  ```bash
  CLAUDE_CODE_FORCE_FULL_LOGO=1 CLAUDE_CONFIG_DIR="$HOME/.clikae/profiles/claude/b" claude
  ```

  Running this and seeing the box return is itself the proof that the *path*
  was never the cause — same dir, same `.claude.json`, different env var.

- Bring back the Opus 4.8 banner by lowering `opus48LaunchSeenCount` in that
  profile's `.claude.json`.

---

These are intentionally *notes*, not roadmap items: clikae's contract is "set the
CLI's config env var, nothing more," and both behaviours live entirely inside
Claude Code. The only thing clikae acts on here is the opt-in keychain carry-over
in §1.

# Releasing clikae via Homebrew

This file lists the EXACT commands a human runs to publish a clikae release
through the `CVERInc/clikae` Homebrew tap. Nothing here is run automatically.

## Where the two formulas live

- in-repo template: `homebrew/clikae.rb` (reference; not what users install)
- tap formula:      `~/Developer/homebrew-clikae/Formula/clikae.rb` (**this is
  the one users get**)

There used to be a "Current state (vX)" block here pinning the shipped version,
tag, and sha256. It was removed on 2026-08-02 rather than updated: it sat
outside the release ritual, so it was ten releases stale, and its claim that
"the tap working copy equals origin/main" was actively wrong — the working copy
was a release behind, and editing on top of it would have shipped a downgrade.
A fact that no step in the recipe refreshes will always rot; ask git instead.

🔴 **Always `git fetch` the tap working copy before editing the formula.** Your
`~/Developer/homebrew-clikae` can be behind `origin/main` (brew's own clone
under `$(brew --repository)/Library/Taps/` updates independently, so the two
disagree silently). Editing a stale copy publishes a version rollback.

## Verify the published tap end-to-end (human, read-only-ish)

```sh
# 1. Tap the published formula (read-only network):
brew tap CVERInc/clikae

# 2. Audit + style the named formula (offline + a couple online checks):
brew audit --strict CVERInc/clikae/clikae
brew style  CVERInc/clikae/clikae

# 3. Build-and-test install (writes into your local Cellar only):
brew install --build-from-source CVERInc/clikae/clikae
brew test CVERInc/clikae/clikae
clikae version   # must match the tag you just published
```

## Cutting the NEXT release (e.g. v0.6.1)

Run these in order. Steps marked PUSH/RELEASE are the only network-writing
ones — do them deliberately.

```sh
# --- in ~/Developer/clikae ---
# 0. Bump the version string and commit it FIRST (tarball VERSION must match tag):
#    edit bin/clikae   -> CLIKAE_VERSION="0.6.1"
#    edit CHANGELOG.md -> new "## [0.6.1] — YYYY-MM-DD" section above the last one
git add bin/clikae CHANGELOG.md && git commit -m "release: clikae 0.6.1"

# 1. Tag the clean commit and PUSH the tag + branch (creates the GitHub source tarball):
git tag v0.6.1
git push origin main          # PUSH
git push origin v0.6.1        # PUSH (tag)

# 2. Compute the real sha256 of the auto-generated source tarball (read-only):
curl -sL https://github.com/CVERInc/clikae/archive/refs/tags/v0.6.1.tar.gz | shasum -a 256

# 3. Update BOTH formulas' url (v0.6.1) + sha256 (from step 2):
#    - ~/Developer/clikae/homebrew/clikae.rb
#    - ~/Developer/homebrew-clikae/Formula/clikae.rb
#    Commit the in-repo template change:
git add homebrew/clikae.rb && git commit -m "homebrew: bump formula to v0.6.1"

# --- in ~/Developer/homebrew-clikae ---
git fetch origin && git merge --ff-only origin/main   # 🔴 NEVER skip: a stale
                                         # working copy ships a version rollback
brew style  Formula/clikae.rb            # must be clean
git add Formula/clikae.rb && git commit -m "clikae 0.6.1"
git push origin main                     # PUSH (publishes to the tap)

# 4. Verify the published tap (see "Verify ... end-to-end" block above, with v0.6.1).

# --- back in ~/Developer/clikae ---
# 5. Publish the GitHub Release (minor versions; see below for when to skip).
gh release create v0.6.1 --title "clikae v0.6.1 — <the headline>" --notes-file <notes.md>
gh release view v0.6.1                     # confirm it is marked Latest
curl -sS https://github.com/CVERInc/clikae/releases/tag/v0.6.1 | grep -c "<a phrase from the notes>"
```

## The GitHub Release (step 5)

This step lived only in the published releases, not in this file — so v0.17.0
shipped without one until someone noticed. The convention, read off the twenty
releases that already exist rather than invented here:

- **Minor versions get a release; patch versions don't.** v0.16.1 has none and
  that was deliberate; v0.16.0, v0.15.x, v0.13.0 … all do.
- **Title**: `clikae vX.Y.Z — <the one thing this release is>`, lowercase after
  the dash, no marketing. It is the line a stranger reads in the release list.
- **Body**: what a user will now be able to do, then what would have been wrong
  if assumed, with the receipts (numbers, not adjectives). `git log vPREV..vNEW`
  is the raw material; the CHANGELOG entry is a starting draft, not the notes —
  the CHANGELOG is per-change, the release notes are per-story.
- **Read an existing one before writing a new one** (`gh release view v0.16.0`).
  The convention lives in those, not in this paragraph.
- Verify from the **public** view (`curl` the tag page and grep a phrase), not
  from `gh`'s success message.

## Notes / gotchas

- Always commit the version bump BEFORE creating the tag, or the tarball's
  embedded `CLIKAE_VERSION` will not match the tag (the sheersweep v0.3.1
  release was burned by exactly this — see homebrew-release-tag-discipline).
- The in-repo `homebrew/clikae.rb` is a TEMPLATE/reference. The formula that
  users actually install is the one in the `homebrew-clikae` tap repo. Keep
  both in sync, but the tap copy is canonical for publishing.
- `brew audit [path ...]` is disabled in current Homebrew; audit the NAMED
  formula (`CVERInc/clikae/clikae`) after `brew tap`, not the file path.

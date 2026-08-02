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
```

## Notes / gotchas

- Always commit the version bump BEFORE creating the tag, or the tarball's
  embedded `CLIKAE_VERSION` will not match the tag (the sheersweep v0.3.1
  release was burned by exactly this — see homebrew-release-tag-discipline).
- The in-repo `homebrew/clikae.rb` is a TEMPLATE/reference. The formula that
  users actually install is the one in the `homebrew-clikae` tap repo. Keep
  both in sync, but the tap copy is canonical for publishing.
- `brew audit [path ...]` is disabled in current Homebrew; audit the NAMED
  formula (`CVERInc/clikae/clikae`) after `brew tap`, not the file path.

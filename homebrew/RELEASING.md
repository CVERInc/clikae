# Releasing clikae via Homebrew

This file lists the EXACT commands a human runs to publish a clikae release
through the `CVERInc/clikae` Homebrew tap. Nothing here is run automatically.

## Current state (v0.6.0)

- Tag `v0.6.0` exists on GitHub (commit `8761936`) and locally.
- Real tarball sha256 (verified by read-only download):
  `661b3cd84ab0ca470f36aa15614fa32abc6152d19f5b547ceafe580eafa890d0`
- Both formulas already carry that `url` + `sha256`:
  - in-repo template: `homebrew/clikae.rb`
  - tap formula:      `~/Developer/homebrew-clikae/Formula/clikae.rb`
- The tap working copy's `main` is already at `e9a7eff "clikae 0.6.0"` and
  equals `origin/main` — i.e. the tap was already pushed for v0.6.0.

So for v0.6.0 there is nothing left to push. The commands below are (a) the
verification a human should still run, and (b) the full recipe for the NEXT
release.

## Verify the v0.6.0 tap end-to-end (human, read-only-ish)

```sh
# 1. Tap the published formula (read-only network):
brew tap CVERInc/clikae

# 2. Audit + style the named formula (offline + a couple online checks):
brew audit --strict CVERInc/clikae/clikae
brew style  CVERInc/clikae/clikae

# 3. Build-and-test install (writes into your local Cellar only):
brew install --build-from-source CVERInc/clikae/clikae
brew test CVERInc/clikae/clikae
clikae version   # should print 0.6.0
```

## Cutting the NEXT release (e.g. v0.6.1)

Run these in order. Steps marked PUSH/RELEASE are the only network-writing
ones — do them deliberately.

```sh
# --- in ~/Developer/clikae ---
# 0. Bump the version string and commit it FIRST (tarball VERSION must match tag):
#    edit bin/clikae -> CLIKAE_VERSION="0.6.1"
git add bin/clikae && git commit -m "release: clikae 0.6.1"

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

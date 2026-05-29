# Installing clikae

`clikae` is pure bash (3.2+ compatible) with no Python/Node runtime. Pick whichever path fits.

## From source (recommended until the Homebrew tap lands in v0.3)

```bash
git clone https://github.com/CVERInc/clikae.git
cd clikae
./install.sh                 # installs to ~/.local
```

To install system-wide instead:

```bash
PREFIX=/usr/local sudo ./install.sh
```

`install.sh` copies the tree to `$PREFIX/share/clikae` and symlinks
`$PREFIX/bin/clikae`. Nothing else on your system is touched.

## Homebrew (planned for v0.3)

Once the `homebrew-clikae` tap is published:

```bash
brew install CVERInc/clikae/clikae
```

## `curl | bash`

```bash
curl -fsSL https://raw.githubusercontent.com/CVERInc/clikae/main/install.sh | bash
```

This runs the same `install.sh` against `~/.local`. Read it first if you'd
rather not pipe a script straight into bash — every line is auditable.

## Put clikae on your PATH

`install.sh` puts the launcher at `$PREFIX/bin/clikae`. Make sure that directory
is on your `PATH`:

```bash
# ~/.local install
export PATH="$HOME/.local/bin:$PATH"   # add to your shell rc if not already there

# verify
clikae version
clikae info        # shows resolved install paths + profile counts
```

## Uninstall

```bash
rm "$PREFIX/bin/clikae"            # the symlink (e.g. ~/.local/bin/clikae)
rm -rf "$PREFIX/share/clikae"      # the program tree
```

Your profiles live separately under `~/.clikae/` and are left untouched. Remove
them with `clikae remove <cli> <profile>` (which also cleans up aliases and
`.app` launchers) before uninstalling, or delete `~/.clikae/` by hand once
you've removed any aliases from your shell rc.

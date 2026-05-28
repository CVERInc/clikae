#!/usr/bin/env bash
# install.sh — curl | bash entry point for clikae.
#
#   curl -fsSL https://raw.githubusercontent.com/CVERInc/clikae/main/install.sh | bash
#
# Or, if you cloned the repo, just run:
#
#   ./install.sh                 # installs to ~/.local
#   PREFIX=/usr/local sudo ./install.sh
#
# The installer copies clikae's files to <prefix>/share/clikae and symlinks
# <prefix>/bin/clikae -> ../share/clikae/bin/clikae.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
REPO_URL="${CLIKAE_REPO_URL:-https://github.com/CVERInc/clikae.git}"
REF="${CLIKAE_REF:-main}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m  %s\n' "$*" >&2; exit 1; }

[ -n "${BASH_VERSION:-}" ] || die "Please run with bash."

# If invoked from inside a checkout, install from there. Otherwise, clone.
SRC_DIR=""
if [ -f "$(dirname "$0")/bin/clikae" ] 2>/dev/null; then
  SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
  say "Installing from local checkout: $SRC_DIR"
else
  command -v git >/dev/null 2>&1 || die "git is required when installing from a remote URL."
  SRC_DIR="$(mktemp -d -t clikae-install.XXXXXX)"
  say "Cloning $REPO_URL@$REF into $SRC_DIR"
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$SRC_DIR" >/dev/null
fi

DEST="$PREFIX/share/clikae"
BIN_LINK="$PREFIX/bin/clikae"

mkdir -p "$PREFIX/bin" "$(dirname "$DEST")"

if [ -d "$DEST" ]; then
  say "Removing existing $DEST"
  rm -rf "$DEST"
fi

say "Copying clikae -> $DEST"
mkdir -p "$DEST"
cp -R "$SRC_DIR/bin" "$SRC_DIR/lib" "$DEST/"
cp "$SRC_DIR/LICENSE" "$SRC_DIR/README.md" "$SRC_DIR/CHANGELOG.md" "$DEST/" 2>/dev/null || true

chmod +x "$DEST/bin/clikae"
ln -sf "$DEST/bin/clikae" "$BIN_LINK"

say "Installed."
echo ""
echo "  Binary  : $BIN_LINK"
echo "  Library : $DEST"
echo ""

case ":$PATH:" in
  *":$PREFIX/bin:"*)
    echo "  $PREFIX/bin is in your PATH. Try:  clikae help"
    ;;
  *)
    echo "  Note: $PREFIX/bin is not in your PATH."
    echo "  Add this to your shell rc:"
    echo "    export PATH=\"$PREFIX/bin:\$PATH\""
    ;;
esac

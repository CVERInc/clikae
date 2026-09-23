#!/usr/bin/env bats
# tests/helpers.bash must not let the suite see an INSTALLED clikae's tmux
# shim (a PATH entry ending in /lib/shims). Tests take `command -v tmux` as
# the real tmux; on a machine with clikae installed by brew that name resolved
# to the 0.31.0 shim, which predates #106, and two tmux-shim tests went red in
# the pre-push gate on 2026-09-24 while the same suite was green once that
# entry was stripped by hand. setup() calls _strip_installed_shims; these
# tests call it on a PATH they built, so the specimen is never an empty string.

load '../helpers'

_fake_install() {
  FAKE="$BATS_TEST_TMPDIR/Cellar/clikae/0.0.0/libexec/lib/shims"
  mkdir -p "$FAKE"
  printf '#!/bin/sh\necho INSTALLED-SHIM\n' > "$FAKE/tmux"
  chmod +x "$FAKE/tmux"
  export PATH="$FAKE:$PATH"
  hash -r
}

@test "helpers: control — with the fake install on PATH, 'tmux' IS the installed shim" {
  _fake_install
  run tmux -V
  [ "$output" = "INSTALLED-SHIM" ] || { echo "control dead: $output"; false; }
}

@test "helpers: _strip_installed_shims removes the installed shim dir, so 'tmux' is never the previous release's shim" {
  _fake_install
  _strip_installed_shims
  case ":$PATH:" in *":$FAKE:"*) echo "still on PATH: $PATH"; false ;; esac
  if command -v tmux >/dev/null 2>&1; then
    run tmux -V
    [[ "$output" != *INSTALLED-SHIM* ]] || { echo "resolved the fake: $output"; false; }
  fi
}

@test "helpers: the strip keeps every other entry, in order" {
  _fake_install
  local before; before="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/lib/shims$' | paste -sd: -)"
  _strip_installed_shims
  [ "$PATH" = "$before" ] || { echo "PATH changed beyond the shim entry"; false; }
}

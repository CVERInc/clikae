#!/usr/bin/env bats
# tests/bats/stat-flavor.bats: which flags clikae gives stat, decided by `stat --version`.

load '../helpers'

_flavor_with() { # <what `stat --version` prints> <its exit code>
  local bin="$TEST_HOME/statbin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" > "$bin/stat"
  chmod +x "$bin/stat"
  (
    PATH="$bin:$PATH"
    # shellcheck source=/dev/null
    . "$CLIKAE_TEST_ROOT/lib/core/profile_store.sh" 2>/dev/null
    _CLIKAE_STAT_FMT=""
    _clikae_statv
    printf '%s' "$_CLIKAE_STAT_FMT"
  )
}

@test "stat that answers --version takes the GNU flags, whatever it calls itself" {
  [ "$(_flavor_with 'stat (GNU coreutils) 9.4' 0)" = '%Y %n' ]
  [ "$(_flavor_with 'stat (uutils coreutils) 0.10.0' 0)" = '%Y %n' ]
}

@test "stat that refuses --version takes the BSD flags" {
  [ "$(_flavor_with 'stat: illegal option -- -' 1)" = '%m %N' ]
}

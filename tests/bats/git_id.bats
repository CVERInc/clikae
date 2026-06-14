#!/usr/bin/env bats
# tests/bats/git_id.bats — `clikae git-id`: per-tank git commit identity (issue #22).
# Covers the write/read/unset round-trip, that `clikae env` emits the four git env
# vars ONLY when an identity is set (safe default off), and name/field validation.
# (`[[ … ]]` carry `|| false`; see tests/README.md.)

load '../helpers'

@test "git-id: set then show round-trips name + email" {
  clikae init claude work
  run clikae git-id claude work --name "Chodai CT" --email "x@cver.net"
  [ "$status" -eq 0 ]
  [[ "$output" == *"x@cver.net"* ]] || false
  run clikae git-id claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"Chodai CT <x@cver.net>"* ]] || false
}

@test "git-id: bare form on a tank with no identity says so" {
  clikae init claude work
  run clikae git-id claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"No git identity"* ]] || false
}

@test "git-id: --unset removes it" {
  clikae init claude work
  clikae git-id claude work --name N --email e@x.com
  run clikae git-id claude work --unset
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cleared"* ]] || false
  run clikae git-id claude work
  [[ "$output" == *"No git identity"* ]] || false
}

@test "git-id: setting needs BOTH name and email" {
  clikae init claude work
  run clikae git-id claude work --name "Only Name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"email"* ]] || false
}

@test "git-id: refuses an unknown tank" {
  run clikae git-id claude nope --name N --email e@x.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"No such tank"* ]] || false
}

@test "git-id: rejects a tab/newline in a field" {
  clikae init claude work
  run clikae git-id claude work --name "$(printf 'a\tb')" --email e@x.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"tabs or newlines"* ]] || false
}

# --- env integration: the whole point — exports appear ONLY when set ---

@test "env: emits the four git vars when the tank has an identity" {
  clikae init claude work
  clikae git-id claude work --name "Chodai CT" --email "x@cver.net"
  run clikae env claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"export GIT_AUTHOR_NAME="* ]] || false
  [[ "$output" == *"export GIT_AUTHOR_EMAIL="* ]] || false
  [[ "$output" == *"export GIT_COMMITTER_NAME="* ]] || false
  [[ "$output" == *"export GIT_COMMITTER_EMAIL="* ]] || false
  # The value survives an eval (spaces in the name).
  eval "$(clikae env claude work)"
  [ "$GIT_AUTHOR_NAME" = "Chodai CT" ]
  [ "$GIT_AUTHOR_EMAIL" = "x@cver.net" ]
  [ "$GIT_COMMITTER_EMAIL" = "x@cver.net" ]
}

@test "env: emits NO git vars when the tank has no identity (safe default)" {
  clikae init claude work
  run clikae env claude work
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE_CONFIG_DIR"* ]] || false   # the normal export is still there
  [[ "$output" != *"GIT_AUTHOR"* ]] || false          # but no git vars
}

# THE PROOF (the whole point of issue #22): a REAL `git commit` in a shell that
# eval'd `clikae env` is authored by the TANK's identity — and that identity beats
# the repo's own `git config`, which is the §13 incident's exact failure path.
@test "env: the exported identity actually stamps a real commit (beats git config)" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  clikae init claude work
  clikae git-id claude work --name "Chodai CT" --email "x@cver.net"
  local repo="$BATS_TEST_TMPDIR/repo"; mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    # The repo's OWN config says someone else — the env vars must win.
    git config user.name  "Wrong Person"
    git config user.email "wrong@example.com"
    eval "$(clikae env claude work)"
    echo hi > f.txt; git add f.txt
    git commit -q -m "test"
    git log -1 --format='%an|%ae|%cn|%ce' > "$BATS_TEST_TMPDIR/who"
  )
  [ "$(cat "$BATS_TEST_TMPDIR/who")" = "Chodai CT|x@cver.net|Chodai CT|x@cver.net" ]
}

# Eval-injection safety: a hostile name/email survives the env round-trip as DATA,
# never executes. (cmd_git_id already blocks tabs/newlines; quotes/`$()`/`;` must
# pass through harmlessly via _env_shquote.)
@test "env: a hostile git identity is quoted, not executed" {
  clikae init claude work
  local pwn="$BATS_TEST_TMPDIR/pwn" pwn2="$BATS_TEST_TMPDIR/pwn2"
  local nm='a$(touch '"$pwn"')b'                         # a command substitution
  local em="e';touch $pwn2;'@x.com"                      # a quote-break + ;
  clikae git-id claude work --name "$nm" --email "$em"
  eval "$(clikae env claude work)"
  [ ! -e "$pwn" ]                                        # the $() did NOT run
  [ ! -e "$pwn2" ]                                       # the ; did NOT run
  [ "$GIT_AUTHOR_NAME" = "$nm" ]                         # preserved verbatim
  [ "$GIT_AUTHOR_EMAIL" = "$em" ]
}

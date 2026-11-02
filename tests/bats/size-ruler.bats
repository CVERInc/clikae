#!/usr/bin/env bats
# tests/bats/size-ruler.bats: the ruler warns on growth past the limit and never fails.

load '../helpers'

setup_repo() {
  export REPO="$TEST_HOME/ruler-repo"
  mkdir -p "$REPO/lib"
  cd "$REPO" || return 1
  git init -q -b main .
  git config user.email ruler@example.com
  git config user.name ruler
  seq 1 20 > lib/big.sh
  seq 1 3 > lib/small.sh
  git add -A
  git commit -qm base
  git checkout -qb change
}

ruler() { CLIKAE_SIZE_LIMIT=10 run bash "$CLIKAE_TEST_ROOT/scripts/size-ruler.sh" main; }

@test "size ruler: growing a large file warns, with the file and the growth" {
  setup_repo
  seq 21 25 >> lib/big.sh
  git commit -qam grow
  ruler
  [ "$status" -eq 0 ]
  [[ "$output" == *'::warning file=lib/big.sh::'*'25 lines'*'adds 5'* ]] || { echo "$output"; false; }
}

@test "size ruler: a small file, or a large one that shrank, says nothing" {
  setup_repo
  seq 4 6 >> lib/small.sh
  seq 1 15 > lib/big.sh
  git commit -qam change
  ruler
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output"; false; }
}

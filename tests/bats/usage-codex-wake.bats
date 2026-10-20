#!/usr/bin/env bats
load '../helpers'
bats_require_minimum_version 1.5.0

@test "#186: codex --wake skips the git check and re-reads usage" {
  clikae init codex marlin >/dev/null 2>&1
  export WAKE_CODEX_RAN="$TEST_HOME/codex-ran"
  export WAKE_CODEX_PROBES="$TEST_HOME/codex-probes"
  cat > "$TEST_HOME/.testbin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = app-server ]; then
  printf 'probe\n' >> "$WAKE_CODEX_PROBES"
  while IFS= read -r line; do
    case "$line" in
      *'"id":1'*) echo '{"id":1,"result":{}}' ;;
      *'"account/rateLimits/read"'*)
        if [ -e "$WAKE_CODEX_RAN" ]; then used=20; else used=100; fi
        printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":%s,"windowDurationMins":300,"resetsAt":4070908800},"secondary":null}}}\n' "$used" ;;
    esac
  done
  exit 0
fi
[ "$1" = exec ] || exit 64
skip=0; cwd=""
prev=""
for arg in "$@"; do
  [ "$arg" != --skip-git-repo-check ] || skip=1
  [ "$prev" != -C ] || cwd="$arg"
  prev="$arg"
done
if [ "$(git -C "$cwd" rev-parse --is-inside-work-tree 2>/dev/null)" != true ] && [ "$skip" -ne 1 ]; then
  printf "codex cwd '%s' is not inside a git work tree; put the repository first in --add-dir, or pass --codex-skip-git-check.\n" "$cwd" >&2
  exit 1
fi
printf 'ok\n' > "$cwd/wake-ok"
: > "$WAKE_CODEX_RAN"
STUB
  chmod +x "$TEST_HOME/.testbin/codex"

  CLIKAE_CODEX_USAGE_PROBE=1 run clikae usage codex marlin --fresh --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.window_pct == 100 and .source == "vendor"' \
    || { echo "initial reading: $output"; false; }

  CLIKAE_CODEX_USAGE_PROBE=1 CLIKAE_USAGE_TTL=999999 run --separate-stderr clikae usage codex --wake marlin --json
  # shellcheck disable=SC2154  # $stderr is set by bats run --separate-stderr
  [ "$status" -eq 0 ] || { echo "wake failed: $stderr"; false; }
  [ -e "$WAKE_CODEX_RAN" ]
  [ -s "$WAKE_CODEX_PROBES" ]
  echo "$output" | jq -e '.engine == "codex" and .tank == "marlin" and .source == "vendor" and .window_pct == 20' \
    || { echo "re-read did not see refreshed usage: $output"; false; }
}

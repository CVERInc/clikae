#!/usr/bin/env bats

load '../helpers'

bats_require_minimum_version 1.5.0

@test "switch scrollback capture retains 200 lines" {
  clikae init claude scrolltest
  cat <<'INNER_EOF' > "$TEST_HOME/.testbin/claude"
#!/usr/bin/env bash
echo "SCROLLBACK_MARKER_START"
for i in {1..200}; do echo "line $i"; done
sleep 0.2
INNER_EOF
  chmod +x "$TEST_HOME/.testbin/claude"
  
  run script -q /dev/null "$CLIKAE_BIN" claude scrolltest
  
  # strip all carriage returns and terminal escapes
  cleaned=$(echo "$output" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r' | sed -E 's/[^a-zA-Z0-9_ -]//g')
  
  # It should appear twice: once when drawn, once when dumped by awk at the end.
  count=$(echo "$cleaned" | grep -o "SCROLLBACK_MARKER_START" | wc -l | awk '{print $1}')
  
  if [ "$count" -lt 2 ]; then
    echo "Expected at least 2 occurrences of SCROLLBACK_MARKER_START, found $count"
    echo "Output was:"
    echo "$output"
    false
  fi
}

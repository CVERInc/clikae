#!/usr/bin/env bash
# scripts/doc-names-exist.sh — every function a doc NAMES must exist in the code.
#
# WHY THIS IS A GATE AND NOT A HABIT. Three separate defects on 2026-08-15 were
# the same shape: a document naming something the source did not have.
#
#   clikae_spawn_session   3 mentions in DESIGN-tmux, 0 definitions — for two
#                          years, while four call sites hand-rolled the rules it
#                          was supposed to hold and drifted apart.
#   fleet_mcp_prelaunch    its own docstring named switch.sh / run.sh as the
#                          callers; relay.sh had it too and burn.sh had none.
#   window-size latest     Rule 1 described the behaviour and nothing set the
#                          option, so it held on tmux 3.7b and not on 3.4.
#
# A doc that names a function is what an auditor reads INSTEAD of the code. When
# it goes stale it does not merely fail to help — it hides the gap it would
# otherwise expose, because the reader now believes the thing exists. That is how
# the first one survived two years and an audit that was looking for exactly it.
#
# Prose drifts and cannot be checked. A name can.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ALLOW="docs/.doc-names-allow"

# Names shaped like clikae functions, from every doc a reader would trust.
names="$(grep -ohE '\b(clikae_[a-z_]+|tmux_[a-z_]+|_switch_[a-z_]+|soul_[a-z_]+|wake_[a-z_]+|live_[a-z_]+|fleet_mcp_[a-z_]+|_home_[a-z_]+|memory_[a-z_]+|adapter_[a-z_]+)\b' \
  docs/*.md AGENTS.md README.md 2>/dev/null | sort -u || true)"

missing=0
while IFS= read -r fn; do
  [ -n "$fn" ] || continue

  # A filename rather than a function (clikae_ssh_auth.sock).
  if grep -qE "${fn}\.[a-z]" docs/*.md AGENTS.md README.md 2>/dev/null; then continue; fi

  # Deliberately named though it does not exist — a name must be listed WITH a
  # reason to be exempt, so the exemption itself stays reviewable.
  if [ -f "$ALLOW" ] && grep -qE "^${fn}[[:space:]]" "$ALLOW"; then continue; fi

  if ! grep -rqE "^[[:space:]]*${fn}\(\)" lib/ bin/ 2>/dev/null; then
    printf '  ✖ %s — named in a doc, defined nowhere\n' "$fn"
    missing=$((missing + 1))
  fi
done <<NAMES
$names
NAMES

if [ "$missing" -gt 0 ]; then
  printf '\n%d name(s) in the docs point at nothing.\n' "$missing" >&2
  printf 'Either write the function, stop naming it, or add it to %s with a reason.\n' "$ALLOW" >&2
  exit 1
fi
printf '  every function named in the docs exists\n'

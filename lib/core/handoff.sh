# shellcheck shell=bash
# lib/core/handoff.sh — build a portable "handoff brief" from a CLI session.
#
# The point (clikae's origin pain restated): when a tank runs dry mid-task, the
# real loss isn't the conversation — it's that the *next* tank starts blind.
# A handoff brief is a short, vendor-neutral note — what's being worked on,
# what's done, what's next — so any other profile/model/vendor can pick up.
#
# Two ways to produce it:
#
#   1. A summarizer command ($CLIKAE_HANDOFF_SUMMARIZER, or `--summarizer`).
#      It receives, on stdin, an instruction line followed by the tail of the
#      session transcript, and writes the brief to stdout. Point it at a *local*
#      or cheap model (e.g. Apple's on-device model, or `llm -m <local>`) so the
#      brief costs nothing on the tank that just ran dry. Vendor-neutral.
#
#   2. No summarizer → a dependency-free raw extract: session metadata plus the
#      most recent prompts, pulled with grep/sed. Honest but unpolished; it is
#      clearly labelled as raw so nobody mistakes it for a real summary.
#
# Pure bash 3.2 + grep/sed/awk. No jq, no python, no network.

# How much of the (often huge) transcript tail to feed a summarizer / scan for
# the raw extract. Lines, not bytes, so we never cut a JSON object in half.
CLIKAE_HANDOFF_LINES="${CLIKAE_HANDOFF_LINES:-60}"

# Character budget for the cleaned digest fed to a summarizer (~4 chars/token).
# Small on-device models (Apple's is ~4096 tokens) can't take a raw JSONL tail,
# so we feed cleaned text capped to this, leaving room for the instruction and
# the model's own output. Cleaned text is better signal for any model anyway.
CLIKAE_HANDOFF_CONTEXT_CHARS="${CLIKAE_HANDOFF_CONTEXT_CHARS:-8000}"

# Reliable single-value metadata: every transcript line repeats these as plain
# "key":"value" pairs, so a first-match grep is safe (no JSON parser needed).
_handoff_field() {
  # _handoff_field <transcript> <jsonKey>
  grep -aoE "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -n 1 | sed 's/.*":"//; s/"$//'
}

# Best-effort: the text of the most recent user-TYPED prompts. We anchor on
# `"role":"user","content":"` — role immediately followed by a *string* content
# — which is exactly a person's typed turn. Tool results carry an array content
# (`"content":[`) and a "toolUseResult" field; system/slash wrappers are tagged
# (<command-name>, <local-command-caveat>) or flagged "isMeta"; sub-agent turns
# are "isSidechain". We drop all of those so the section shows real prompts, not
# the file dumps and command output that also live under role:user. Still
# best-effort (it truncates a prompt at a literal `"}`), hence the "raw" label.
_handoff_recent_prompts() {
  # _handoff_recent_prompts <transcript> <count>
  # Scan the WHOLE transcript (in a tool-heavy session the last real prompt is
  # many tool-result lines back), then keep the most recent <count>.
  grep -a '"role":"user","content":"' "$1" 2>/dev/null \
    | grep -av '"toolUseResult"' \
    | grep -av '"isMeta":true' \
    | grep -av '"isSidechain":true' \
    | sed 's/.*"role":"user","content":"//; s/"}.*//' \
    | sed 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g; s/\\\\/\\/g' \
    | grep -av '^[[:space:]]*<command-' \
    | grep -av '^[[:space:]]*<local-command' \
    | grep -av '^[[:space:]]*$' \
    | tail -n "$2" || true
}

# Build the compact, plain-text digest fed to a summarizer: the recent real
# prompts plus the assistant's text replies, JSONL/tool noise stripped, capped to
# CLIKAE_HANDOFF_CONTEXT_CHARS (keeping the MOST RECENT). A small on-device model
# can't take a raw JSONL tail (Apple's is ~4096 tokens); cleaned text is also
# better signal for any model — feeding the raw tail produced generic, sometimes
# hallucinated briefs, while this cleaned digest produced specific, accurate ones.
# grep/sed only (no jq/python).
_handoff_clean_tail() {
  local t="$1"
  {
    echo "## Recent user prompts (oldest first)"
    _handoff_recent_prompts "$t" 14 | sed 's/^/- /'
    echo
    echo "## Recent assistant notes (oldest first)"
    grep -a '"role":"assistant"' "$t" 2>/dev/null \
      | grep -aoE '"text":"([^"\\]|\\.)*"' \
      | sed 's/^"text":"//; s/"$//' \
      | sed 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g; s/\\\\/\\/g' \
      | grep -av '^[[:space:]]*$' \
      | tail -n 14 | sed 's/^/- /'
  } | tail -c "$CLIKAE_HANDOFF_CONTEXT_CHARS"
}

# Print the raw (no-model) brief to stdout.
_handoff_raw_brief() {
  local t="$1"
  local sid cwd branch ver first last
  sid="$(_handoff_field "$t" sessionId)"
  cwd="$(_handoff_field "$t" cwd)"
  branch="$(_handoff_field "$t" gitBranch)"
  ver="$(_handoff_field "$t" version)"
  first="$(_handoff_field "$t" timestamp)"
  last="$(grep -aoE '"timestamp":"[^"]*"' "$t" 2>/dev/null | tail -n 1 | sed 's/.*":"//; s/"$//')"

  echo "# Session handoff (raw extract)"
  echo
  echo "> No summarizer configured, so this is a raw extract — reliable metadata"
  echo "> plus recent prompts, not a real summary. For a proper brief, set"
  echo "> \$CLIKAE_HANDOFF_SUMMARIZER to a local/cheap model (see \`clikae handoff --help\`)."
  echo
  [ -n "$cwd" ]    && echo "- **Working dir:** $cwd"
  [ -n "$branch" ] && echo "- **Git branch:** $branch"
  [ -n "$sid" ]    && echo "- **Session:** $sid"
  [ -n "$ver" ]    && echo "- **CLI version:** $ver"
  [ -n "$first" ] && [ -n "$last" ] && echo "- **Span:** $first → $last"
  echo
  echo "## Recent prompts"
  echo
  local prompts
  prompts="$(_handoff_recent_prompts "$t" 5)"
  if [ -n "$prompts" ]; then
    printf '%s\n' "$prompts" | sed 's/^/- /'
  else
    echo "_(no plain-text prompts found in the last $CLIKAE_HANDOFF_LINES lines)_"
  fi
}

# The instruction prefix handed to a summarizer model, ahead of the transcript.
_handoff_summarizer_prompt() {
  cat <<'EOF'
You are writing a HANDOFF BRIEF so a different AI coding assistant (possibly a
different model or vendor) can continue this work after the current one ran out
of quota. Below is a digest of the recent conversation (most recent last). Read
it and write a concise markdown brief with these sections:

  ## Goal — what the user is ultimately trying to do
  ## Done — what's already been accomplished this session
  ## Next — the immediate next step(s) to take
  ## Watch out — gotchas, decisions made, files/commands that matter

Be specific (name files, commands, branches). Do NOT invent anything not in the
digest. Keep it under ~250 words. Output only the brief.

--- RECENT CONVERSATION (oldest first) ---
EOF
}

# Find a LOCAL summarizer already on the machine, so a smart brief is generated
# ON-DEVICE (private, free, offline) out of the box — nothing bundled, nothing
# installed by clikae. Order favours the lightest zero-config path first. Prints
# the command string (for `sh -c`), or returns non-zero if none is found. Never
# picks a cloud model: that stays the user's explicit opt-in via
# $CLIKAE_HANDOFF_SUMMARIZER. The brief is the user's own session content, so
# summarizing it locally means it never leaves the machine to make the handoff.
_handoff_local_summarizer() {
  if command -v apfel >/dev/null 2>&1; then
    printf 'apfel -q\n'; return 0          # Apple on-device model (macOS 26 + Apple Intelligence)
  fi
  if command -v ollama >/dev/null 2>&1; then
    local m; m="$(ollama list 2>/dev/null | awk 'NR==2{print $1; exit}')"
    [ -n "$m" ] && { printf 'ollama run %s\n' "$m"; return 0; }
  fi
  if command -v llm >/dev/null 2>&1; then
    printf 'llm\n'; return 0                # Simon Willison's llm, whatever model it defaults to
  fi
  return 1
}

# handoff_render <transcript> [<summarizer-cmd>]
# Prints the brief to stdout. Summarizer precedence:
#   1. explicit arg ($2, e.g. `--summarizer`)
#   2. configured $CLIKAE_HANDOFF_SUMMARIZER
#   3. a LOCAL on-device model auto-detected on this machine (unless
#      CLIKAE_HANDOFF_AUTOLOCAL=0 turns that off)
# With none of those, a dependency-free raw extract.
handoff_render() {
  local t="$1" summarizer="${2:-$CLIKAE_HANDOFF_SUMMARIZER}" auto=0
  [ -f "$t" ] || { log_err "Transcript not found: $t"; return 1; }

  # Nothing explicit/configured → try a local on-device model before giving up to
  # the raw extract. Announced (never a silent surprise) and trivially overridable
  # ($CLIKAE_HANDOFF_SUMMARIZER, or CLIKAE_HANDOFF_AUTOLOCAL=0); on failure it
  # still falls back to raw, so a handoff is never lost.
  if [ -z "$summarizer" ] && [ "${CLIKAE_HANDOFF_AUTOLOCAL:-1}" = "1" ]; then
    summarizer="$(_handoff_local_summarizer || true)"
    [ -n "$summarizer" ] && auto=1
  fi

  if [ -z "$summarizer" ]; then
    _handoff_raw_brief "$t"
    return 0
  fi

  [ "$auto" -eq 1 ] && log_dim "Brief written on-device by: $summarizer  (override with \$CLIKAE_HANDOFF_SUMMARIZER, disable with CLIKAE_HANDOFF_AUTOLOCAL=0)" >&2

  # Feed the model: instructions + a cleaned, capped digest of the recent
  # conversation, on stdin. The summarizer reads stdin and writes the brief to
  # stdout. A non-zero exit (or empty output) falls back to the raw extract.
  local out=""
  out="$( { _handoff_summarizer_prompt; _handoff_clean_tail "$t"; } \
            | sh -c "$summarizer" 2>/dev/null || true )"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    log_warn "Summarizer produced nothing; falling back to a raw extract." >&2
    _handoff_raw_brief "$t"
  fi
}

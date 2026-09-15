# shellcheck shell=bash
# lib/adapters/codex.sh — adapter for the OpenAI Codex CLI.
# Reference: https://developers.openai.com/codex/config-advanced (CODEX_HOME)
#
# Codex keeps all of its local state — config.toml, auth.json, session history —
# under CODEX_HOME (default ~/.codex). Pointing CODEX_HOME at a per-profile
# directory gives each profile its own login + settings, so this is a plain
# env-dir adapter (same shape as claude).

adapter_meta_name()        { echo "OpenAI Codex CLI"; }
adapter_meta_cli_binary()  { echo "codex"; }
adapter_meta_env_var()     { echo "CODEX_HOME"; }
adapter_meta_strategy()    { echo "env-dir"; }
adapter_meta_description() { echo "OpenAI Codex CLI (auth + config + history in CODEX_HOME)"; }
# Optional: how to install the binary, shown when a switch finds it missing.
adapter_install_hint() { echo "npm install -g @openai/codex"; }

# Optional hook: where to drop a "your long-term memory (Soul) lives at <path>"
# pointer for `clikae memory share` (docs/memory.md). codex keeps its OWN memory
# in opaque sqlite, NOT a markdown dir we can symlink — but it reads `AGENTS.md`
# as instructions, and CODEX_HOME-scoped `$CODEX_HOME/AGENTS.md` is the global
# (per-tank, not per-repo) layer. So we point codex at the shared markdown Soul
# there. Defining THIS hook (instead of adapter_memory_dir) marks an engine as
# pointer-strategy: it reads/writes the shared Soul via the memory protocol
# rather than via a memory-dir symlink.
adapter_memory_pointer_path() {
  printf '%s\n' "$1/AGENTS.md"
}

# Nothing to seed — codex initialises CODEX_HOME on first run / login.
adapter_init() {
  local profile_dir="$1"
  : "$profile_dir"
}

adapter_export_env() {
  local profile_dir="$1"
  printf 'CODEX_HOME=%s\n' "$profile_dir"
}

adapter_run() {
  local profile_dir="$1"; shift
  CODEX_HOME="$profile_dir" exec codex "$@"
}

# Optional hook: how to run codex HEADLESS-with-write for `clikae burn`'s
# convenience form (--prompt-file / --prompt). Codex's headless verb is `exec`,
# its working dir is `-C <dir>`, and `-s workspace-write` makes that dir writable.
# Codex takes a SINGLE working dir, so the FIRST --add-dir becomes -C (the rest
# are ignored — codex's writable root is the cwd under workspace-write). The
# prompt is the trailing positional. Items are NUL-separated so a multi-line
# prompt survives as ONE argv item (newline framing would shatter it).
adapter_burn_flags() {
  local prompt="$1"; shift
  printf 'exec\0'
  [ $# -gt 0 ] && printf -- '-C\0%s\0' "$1"
  printf -- '-s\0workspace-write\0%s\0' "$prompt"
}

# Optional hook: how to run codex HEADLESS READ-ONLY for `clikae conduct`'s
# fan-out. `-s read-only` sandboxes it to reads; --skip-git-repo-check lets it run
# outside a repo. First <dir> is the cwd (-C); the prompt is the trailing data.
# NUL-separated items (multi-line prompt survives as one argv item).
adapter_audit_flags() {
  local prompt="$1"; shift
  printf 'exec\0--skip-git-repo-check\0'
  [ $# -gt 0 ] && printf -- '-C\0%s\0' "$1"
  printf -- '-s\0read-only\0%s\0' "$prompt"
}

# Optional hook: start a session seeded with an initial prompt (for
# `clikae handoff --to codex/<profile>`). Codex takes a positional prompt.
adapter_start_with_prompt() {
  local profile_dir="$1" prompt="$2"; shift 2
  CODEX_HOME="$profile_dir" exec codex "$prompt" "$@"
}

# Optional hook: the logged-in account label, shown by `clikae list` / `status`
# and the dashboard. With ChatGPT auth, codex stores identity in auth.json's
# `id_token` — a JWT whose base64url payload carries the account email. Decode
# with grep/sed/tr + base64 (no jq); API-key logins have no id_token, so they
# just yield nothing. Never propagate a no-match under the caller's `set -eo
# pipefail` (it would abort list/status) — always end at return 0.
adapter_account_label() {
  local f="$1/auth.json" idt payload decoded
  [ -f "$f" ] || return 0
  idt="$(grep -oE '"id_token"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
        | head -n 1 | sed -E 's/.*"id_token"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  [ -n "$idt" ] || return 0
  # JWT = header.payload.signature; the payload is base64url (no padding).
  payload="$(printf '%s' "$idt" | cut -d. -f2 | tr '_-' '/+')"
  [ -n "$payload" ] || return 0
  case $(( ${#payload} % 4 )) in 2) payload="$payload==" ;; 3) payload="$payload=" ;; esac
  # base64 -d (GNU + recent macOS) with a -D fallback for older BSD.
  decoded="$(printf '%s' "$payload" | base64 -d 2>/dev/null || printf '%s' "$payload" | base64 -D 2>/dev/null || true)"
  [ -n "$decoded" ] || return 0
  printf '%s' "$decoded" \
    | grep -oE '"email"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true
  return 0
}

# --- session continuity: surface codex sessions in the board's "Continue" list -
# Codex stores each session as a rollout JSONL under
#   CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl
# whose FIRST line is a `session_meta` carrying payload.id (the session UUID) and
# payload.cwd (the dir it ran in). Unlike claude, codex does NOT slug $PWD into
# the path — so we match on the recorded cwd. Filenames embed a sortable ISO
# timestamp, so a lexical reverse sort is newest-first. We read only line 1 per
# file to decide, keeping the board cheap.

_codex_sessions_dir() { printf '%s\n' "$1/sessions"; }

# _codex_meta_field <file> <field> — pull a string field from the session_meta
# (first line). Never abort the caller under `set -eo pipefail`.
_codex_meta_field() {
  if declare -F reading_cache_run >/dev/null; then
    reading_cache_run "codex-meta-$2" "$1" _codex_meta_uncached "$@"
  else
    _codex_meta_uncached "$@"
  fi
}

_codex_meta_uncached() {
  local first_line=""
  read -r first_line < "$1" 2>/dev/null || true
  if [[ "$first_line" == *'"'"$2"'"'* ]]; then
    local part="${first_line#*\"$2\":\"}"
    printf '%s\n' "${part%%\"*}"
  fi
}

# _codex_find_rollout <dir> <sid> — the rollout file for a session id (the uuid is
# the filename suffix), or empty.
_codex_find_rollout() {
  if [ "${_CLIKAE_BOARD:-0}" = 1 ]; then
    local f; f="$(board_find codex "$1" "$2" 2>/dev/null)" && [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  fi
  local sdir; sdir="$(_codex_sessions_dir "$1")"
  [ -d "$sdir" ] || return 0
  find "$sdir" -type f -name "rollout-*-$2.jsonl" 2>/dev/null | head -n 1
}

# _codex_rollouts_for_cwd <dir> — rollout files under <dir> whose recorded cwd is
# $PWD, newest first. The compare is trailing-slash-insensitive on BOTH sides: a
# rollout written from a path with a trailing slash (or a $PWD that carries one)
# must still match, or the session silently vanishes from the board / can't resume.
# Same normalisation `live_dir_users` already applies (`${dir%/}`).
_codex_rollouts_for_cwd() {
  local sdir f want; sdir="$(_codex_sessions_dir "$1")"
  [ -d "$sdir" ] || return 0
  want="${PWD%/}"
  find "$sdir" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort -r | while IFS= read -r f; do
    local rec; rec="$(_codex_meta_field "$f" cwd)"
    [ "${rec%/}" = "$want" ] && printf '%s\n' "$f"
  done
}

# Resume a codex session by id: `codex resume <uuid>` (verified via codex --help).
# Gates (with adapter_recent_sids) whether the board offers a "resume" affordance.
adapter_resume_args() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  printf 'resume\n%s\n' "$sid"
}

# Optional hook: the inverse of adapter_resume_args — see claude.sh's twin for
# why switch.sh needs this (it replaces the old CLIKAE_LAUNCH_SID environment
# variable, which leaked into every session a tmux server born under it later
# spawned).
#
# adapter_new_session_args is deliberately left undefined here. `codex exec`
# has a `--session_id`/fork option, but it names a session to FORK FROM — it
# requires that session to already exist, which is a different lifecycle from
# handing a brand-new interactive session a caller-chosen id before it starts.
# codex exposed nothing usable for that at the version checked (0.153.4;
# `codex --help` itself hung in this sandbox rather than a real terminal, so
# this was confirmed by inspecting the binary's own strings, not a live run —
# worth re-checking against a real `codex --help` before trusting it further).
# A bare `clikae codex <tank>` keeps the tank-scoped guess (DESIGN-tmux.md
# Rule 2: an engine with no equivalent flag degrades honestly rather than
# pretending to be exact).
adapter_sid_from_args() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "resume" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

# Optional hook: the cwd codex's OWN argv carries, read back out of "$@" for
# `clikae burn`'s raw '-- <cmd...>' mode (#74 round-3 P1-1). Unlike
# --prompt/--prompt-file mode, which composes -C itself from add_dirs[0]
# (adapter_burn_flags above), a raw command's cwd is entirely the caller's:
# `clikae burn codex T -- exec -C /tmp -s workspace-write '…'` — the --help
# example at burn.sh:118 is exactly this shape. Recognises `-C <dir>`, the
# attached `-C<dir>` (codex's own arg parser accepts both, same convention
# git -C does), and the long alias `--cd <dir>`. Returns empty (rc 1) when
# none appear — codex then runs in $PWD like every other engine, and the
# caller (burn.sh) treats that as "no override" rather than guessing $PWD
# itself (an unresolved raw launch must match nothing, not something).
#
# R4 review P3-1: real codex 0.154.0 (clap) also accepts the `=`-joined long
# and short forms, `--cd=<dir>` and `-C=<dir>` — measured against the actual
# binary, not inferred. Without these two cases, `--cd=<dir>` fell all the
# way through to `return 1` (empty launch cwd, which the burn.sh P2-1 fix
# now correctly treats as "unknown" rather than misattributing), and
# `-C=<dir>` matched the looser `-C?*` case below and returned "=<dir>"
# verbatim — a value that can never equal a real cwd, so it silently never
# matched anything either. Both are handled explicitly now, ahead of the
# looser glob.
adapter_cwd_from_args() {
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "-C" ] || [ "$prev" = "--cd" ]; then
      printf '%s' "$a"; return 0
    fi
    case "$a" in
      --cd=*) printf '%s' "${a#--cd=}"; return 0 ;;
      -C=*)   printf '%s' "${a#-C=}";   return 0 ;;
      -C?*)   printf '%s' "${a#-C}";    return 0 ;;
    esac
    prev="$a"
  done
  return 1
}

# This dir's most recent rollout under <dir> (for relay / handoff).
adapter_transcript_path() {
  local f; f="$(_codex_rollouts_for_cwd "$1" | head -n 1)"
  [ -n "$f" ] || return 1
  printf '%s\n' "$f"
}

# _CODEX_USER_MESSAGE_TYPE_RE / _CODEX_AGENT_MESSAGE_TYPE_RE — the anchors
# for "this line records something the human/the model actually typed",
# shared by adapter_title_for_file (below) and adapter_handoff_extract's
# event_msg scan, so nothing in this file disagrees with itself about what a
# codex event looks like (round-1 review P2-2). Codex writes a human-typed
# turn as an event_msg whose payload.type is "user_message" and a model
# reply as an event_msg whose payload.type is "agent_message" — both carry
# the text in "message". _CODEX_AGENT_MESSAGE_TYPE_RE is the SAME anchor
# lib/core/limit.sh already uses for this exact shape (limit.sh:322, whose
# comment at :275-293 says "confirmed against a real rollout"). Before
# round-2 review P2-1, the assistant branch below had its own, UNCONFIRMED
# response_item-only anchor instead of sharing this one — the same "no
# sibling backing this guess" bug round-1 P1-1 found in the user branch,
# just on the other role: a rollout that (like every other codex scanner in
# this repo) records replies as event_msg/agent_message showed as EMPTY
# here while limit.sh read the same file fine.
#
# ` *` (a literal space, starred), not `[ \t]*`/`[[:space:]]*`: `lib/core/
# limit.sh`'s whole codex family (:281, :322, :1160, :1183, and
# tests/bats/limit-codex-status.bats:215's "confirmed against a real
# rollout" fixture) matches a SPACED `"type": "user_message"`, so ` *`
# tolerates that idiom too — the SAME whitespace convention as every other
# codex scanner in the repo, not a fourth one (round-1 review P1-1).
# Round-3 review: that confirmation was against an older/other rollout,
# NOT what this machine's real files look like — the two real 0.154.0
# `codex_exec` rollouts on this box are COMPACT JSON (zero `"type": "`
# occurrences, all `"type":"`, no space after the colon). ` *` matches
# both forms either way, so behaviour is unaffected; this comment used to
# overstate the evidence as "every codex event on this machine does".
_CODEX_USER_MESSAGE_TYPE_RE='"type": *"user_message"'
_CODEX_AGENT_MESSAGE_TYPE_RE='"type": *"agent_message"'

# Optional hook (#33; round-1 P1-1/P2-2/P3-1 and round-2 P2-1/P2-2/P3-2/P3-3
# review fixes folded in): the transcript SHAPE belongs to the adapter.
# Prints one line per MESSAGE of <role> ("user"/"assistant") — several text
# parts in one message join with a space onto one line, unlike claude.sh's
# twin, which prints one line per text BLOCK instead (round-1 review P3-1;
# docs/adding-an-adapter.md spells out the difference) — text only, newest
# last — used by `clikae handoff`'s digest (lib/core/handoff.sh,
# _handoff_extract).
#
# A codex rollout can record the SAME turn in two different ways depending
# on how the session ran, and this hook reads the UNION of both rather than
# betting on one (round-2 review P2-1 for the assistant side; the user side
# already did this in round-1, for the injected-context reason below):
#
#   Shape A — event_msg (the UI event stream; limit.sh's whole codex family
#   — :281, :322, :1160, :1183 — reads ONLY this shape, "confirmed against a
#   real rollout"):
#     {"type":"event_msg","payload":{"type":"user_message","message":"…"}}
#     {"type":"event_msg","payload":{"type":"agent_message","message":"…"}}
#
#   Shape B — response_item (the OpenAI Responses API conversation state):
#     {"type":"response_item","payload":{"type":"message","role":"assistant",
#       "content":[{"type":"output_text","text":"…"}]}}
#     {"type":"response_item","payload":{"type":"message","role":"user",
#       "content":[{"type":"input_text","text":"…"}]}}
#
# `content` in shape B is an ARRAY of typed parts, so the claude-shaped
# `"role":"…","content":"…"` string anchor matches neither role — that was
# the original #33 bug. Round-2 review P3-3: the value scan below only pulls
# a part's "text" when it is immediately preceded by ITS OWN "type" field
# naming the part kind this role writes ("output_text" for assistant,
# "input_text" for user) — matching the field order in the shape shown
# above, the only order this repo has ever seen (no real rollout was
# available to confirm another order exists; see "what we didn't verify"
# below). A bare `"text": *"` key scan also lights up on a DIFFERENT part in
# the same array that merely happens to carry its own "text" key (a
# reasoning part, an image part's alt text, …), which would leak non-reply
# content into a brief meant for another vendor.
#
# USER shape B ALSO carries MACHINE-INJECTED context, not just what the
# human typed, e.g.
#   {"type":"response_item","payload":{"type":"message","role":"user",
#     "content":[{"type":"input_text","text":"<environment_context>cwd=…
#     </environment_context>"}]}}
#   {"type":"response_item","payload":{"type":"message","role":"user",
#     "content":[{"type":"input_text","text":"<user_instructions>AGENTS.md
#     contents here</user_instructions>"}]}}
# so `<environment_context>` / `<user_instructions>` are stripped
# defensively below regardless of which shape produced the line (round-1
# review P2-2) — belt-and-suspenders, the same spirit as claude's own four
# filters for role:user noise.
#
# awk, ONE pass over the whole file. Round-2 review P2-2: the previous
# version built each matched value with a character-by-character
# `seg = seg c` loop — O(1) per character on gawk, but O(line length) PER
# CHARACTER on mawk (Debian/Ubuntu's DEFAULT `awk` on a base image) and
# busybox awk, i.e. O(n²) overall: measured 95.9s for one 1.6 MB line on
# mawk vs 0.33s on gawk for the same input (400 kB was already 4.3s on mawk,
# 48s on busybox awk). `match(rest, /^([^"\\]|\\.)*/)` finds the WHOLE value
# (escapes included) in ONE call — RLENGTH is the value's length, so
# `substr()` lifts it in one shot, leaving nothing for mawk's string-concat
# cost to multiply. This is the same "value body" idiom claude.sh's
# assistant branch already uses via `grep -aoE`, just expressed for awk's
# `match()`. The fixed anchor/key patterns (event_re, role_re, part_keyre)
# stay literal strings either side of a single, non-nested ` *`/`, *` — no
# ReDoS risk, and no need for the index()/substr()-without-regex workaround
# a nested-star `[[ =~ ]]` pattern would need (see adapter_title_for_file
# above for why THAT trap matters for bash's own regex engine).
#
# Escapes: only \n \t \" \\ are unescaped — the SAME subset the claude path
# has always unescaped, never \uXXXX (parity first; see handoff.sh's own
# comment on this — a \uXXXX decoder is a follow-up, not a regression, since
# grep/sed/awk alone can't safely decode one without jq/python).
#
# Silent failure is not allowed (round-1 review P1-1) — but round-2 review
# P3-2: a role with genuinely no turns yet (a brand-new tank the model
# hasn't replied to) is NOT a shape mismatch, and firing the same stderr
# line for both trained a reader to ignore it. So the diagnostic now fires
# only when SCANNED (a line structurally shaped like this role's turn, by
# EITHER shape's anchor) is > 0 while MATCHED (a value actually pulled out
# of one) stays 0 — that combination can only mean the anchors are looking
# at the wrong keys, not "there's nothing here yet" — and it says how many
# lines it saw, so the reader isn't left guessing which. Zero scanned lines
# stays silent. handoff.sh's _handoff_extract no longer swallows a hook's
# stderr (see its own comment), so a real diagnostic still reaches the user.
adapter_handoff_extract() {
  local t="$1" role="$2"
  [ -n "$t" ] && [ -f "$t" ] || return 0
  case "$role" in user|assistant) ;; *) return 0 ;; esac
  local event_re part_type out
  if [ "$role" = user ]; then
    event_re="$_CODEX_USER_MESSAGE_TYPE_RE"; part_type="input_text"
  else
    event_re="$_CODEX_AGENT_MESSAGE_TYPE_RE"; part_type="output_text"
  fi
  out="$(awk -v role="$role" -v event_re="$event_re" -v part_type="$part_type" '
    BEGIN {
      role_re = "\"role\": *\"" role "\""
      part_keyre = "\"type\": *\"" part_type "\", *\"text\": *\""
      kinds_re = "\"content_item_kinds\": *\\[[^]]*\\]"
      scanned = 0; matched = 0; have_prev = 0; prev = ""; kinds_skipped = 0
    }
    $0 ~ event_re {
      scanned++
      rest = $0; keyre = "\"message\": *\""
      if (match(rest, keyre)) {
        rest = substr(rest, RSTART + RLENGTH)
        if (match(rest, /^([^"\\]|\\.)*/)) {
          seg = substr(rest, 1, RLENGTH)
          # round-3 review P3-3: finding the key AND its (possibly empty)
          # value body is a MATCH regardless of whether the value itself is
          # "" — a legitimately empty agent_message is a shape that worked,
          # not a mismatch, so it must not starve `matched` and trigger the
          # loud line below. Only an EMPTY-STRING value is skipped from
          # print+dedup (nothing to show, nothing to compare against).
          matched++
          if (seg != "" && (!have_prev || seg != prev)) {
            print seg; prev = seg; have_prev = 1
          }
        }
      }
      next
    }
    $0 ~ /"type": *"response_item"/ && $0 ~ role_re {
      # round-3 review P2-1, metadata first: a real 0.154.0 rollout tags
      # every response_item with content_item_kinds, and a human-typed turn
      # is the ONLY one with a kind that starts with "user." (machine-
      # injected context — AGENTS.md dumps, environment_context, plugin
      # recommendations — never does). A line carrying this field and no
      # "user."-prefixed kind is skipped WHOLE, before scanned/matched even
      # see it — same "recognized and filtered, not a mismatch" spirit as
      # round-2 P3-2 below, not "the anchors are looking at the wrong keys".
      #
      # round-4 review P2-1: `has_kinds` records whether THIS line carried
      # content_item_kinds at all. When it did, kinds is authoritative — a
      # part that survives to the per-part loop below already passed the
      # "user."-prefix check above, so the per-part prefix filter (which
      # exists only to guess at rollouts with no metadata) must not run on
      # it. Without this, a human prompt that itself opens with a bare tag
      # (`<div>`, `<template>`, `<script setup>`, a Markdown `# ` heading)
      # was silently dropped even though content_item_kinds said "user.text".
      has_kinds = 0
      if (match($0, kinds_re)) {
        kinds = substr($0, RSTART, RLENGTH)
        if (kinds !~ /"user\./) { kinds_skipped++; next }
        has_kinds = 1
      }
      scanned++
      rest = $0; res = ""; have_part = 0
      while (match(rest, part_keyre)) {
        rest = substr(rest, RSTART + RLENGTH)
        if (!match(rest, /^([^"\\]|\\.)*/)) break
        seg = substr(rest, 1, RLENGTH)
        rest = substr(rest, RLENGTH + 2)
        have_part = 1
        # round-3 review P2-1, per-part fallback: parts USED to be joined
        # into one line BEFORE the line-anchored `<environment_context>`
        # filter below ever saw them, so a real rollout whose first part is
        # `<recommended_plugins>` and second is `# AGENTS.md instructions`
        # produced a joined line starting with the FIRST tag only — the
        # filter matched, but everything after the first part (the rest of
        # the injected content, and any real text) rode along, unfiltered.
        # Filtering PER PART before joining, here (not after), is the fix,
        # and it also covers a shape with no content_item_kinds field at
        # all (older/other rollouts) — the case the metadata check above
        # has no way to decide.
        #
        # round-4 review P2-1: this fallback is a GUESS for the no-metadata
        # case only — `!has_kinds` skips it entirely when content_item_kinds
        # already answered the question above, since a human `user.text`
        # part is never filtered by prefix. And even in the no-metadata
        # case, the pattern is narrowed from "any bracketed lowercase tag"
        # (which swallowed a human prompt pasting `<div>`, `<template>`,
        # `<script setup>`, `<table>`, …) to the closed set of injected
        # shapes this file documents by name: `<recommended_plugins>`,
        # `<environment_context>`, `<user_instructions>`,
        # `<permissions instructions>`, and the `# AGENTS.md instructions`
        # heading.
        if (!has_kinds && (seg ~ /^<(recommended_plugins|environment_context|user_instructions|permissions instructions)>/ || seg ~ /^# AGENTS\.md instructions/)) continue
        res = (res == "" ? seg : res " " seg)
      }
      # round-3 review P2-2: the event_msg and response_item rules above are
      # a UNION with no dedup, so a turn recorded in both shapes (a prior
      # report called this a "fallback", but the code is an unconditional
      # union) printed every prompt/note twice. Adjacent dedup (compare
      # only to the immediately PRECEDING printed line, shared across both
      # rules via one `prev`) fixes shape B2 (same turn, both shapes, back
      # to back) and leaves shape B1 (different turns, each in its own
      # shape) alone; the one-sentence trade-off: two turns with
      # byte-identical text that really ARE consecutive (the user typing
      # "continue" twice in a row) collapse into one line too — accepted,
      # since a handoff brief cares about what was said, not how many times.
      if (res != "" && (!have_prev || res != prev)) {
        print res; matched++; prev = res; have_prev = 1
      } else if (res == "" && have_part) {
        # round-4 review P2-1: at least one part matched the shape anchor —
        # the extractor worked — but the injected-tag filter above removed
        # every part (a turn that really is ALL machine-injected context,
        # with no human text alongside it). That is the filter doing its
        # job, not the anchors looking at the wrong keys, so it must not
        # starve `matched` and trigger the loud line at the bottom of this
        # script — same reasoning as the round-3 P3-3 empty-value fix above.
        matched++
      }
    }
    END {
      if (scanned > 0 && matched == 0) {
        printf "handoff: codex extractor scanned %d %s lines, matched 0\n", scanned, role > "/dev/stderr"
      } else if (scanned == 0 && matched == 0 && kinds_skipped > 0) {
        # round-4 review P3-2: content_item_kinds present but naming no
        # "user."-prefixed kind (an empty kinds array, or a future rollout
        # that renames the kind) skips the WHOLE line before scanned++ ever
        # runs, so the diagnostic above never fires — a real shape mismatch
        # went completely silent — the exact thing the "Silent failure is
        # not allowed" comment at :294 above rules out. This fires only when
        # EVERY candidate line for this role was filtered by kinds and
        # nothing was extracted by either shape (matched stays the true
        # union total, including the event_msg branch own count).
        printf "handoff: codex extractor found %d %s response_item line(s) but content_item_kinds named no \"user.\"-prefixed kind on any of them\n", kinds_skipped, role > "/dev/stderr"
      }
    }
  ' "$t" \
    | sed 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g; s/\\\\/\\/g' \
    | grep -avE '^[[:space:]]*<(environment_context|user_instructions)' \
    | grep -av '^[[:space:]]*$' || true)"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# CHEAP recent sessions for the home board: "<epoch-mtime>\037<sid>", newest
# first, capped at [limit] (default 5), for sessions whose cwd is $PWD.
adapter_recent_sids() {
  if [ "${_CLIKAE_BOARD:-0}" = 1 ]; then
    # Snapshot first, live content-scan fallback only on a genuine miss — see
    # claude.sh's twin comment (2026-09-12 round-1 fix review, P1-1).
    local _bout; _bout="$(board_recent codex "$@")"
    if [ -n "$_bout" ]; then printf '%s\n' "$_bout"; return 0; fi
  fi
  local dir="$1" limit="${2:-5}" f sid mt
  # codex's this-dir set is content-matched (a rollout records $PWD in its body,
  # not its path — see _codex_rollouts_for_cwd), so the FILE LIST comes from there;
  # sessions_by_mtime (shared kernel) then stats+sorts it. Read the list into an
  # array line-by-line, never via unquoted word-splitting: tank names are
  # validated (no spaces) but $CLIKAE_HOME rides on $HOME, which ISN'T — a space
  # anywhere in the home path used to shred every path into fragments and
  # silently drop all codex sessions from the board.
  local -a rfiles=()
  while IFS= read -r f; do
    [ -n "$f" ] && rfiles+=("$f")
  done <<EOF
$(_codex_rollouts_for_cwd "$dir")
EOF
  [ "${#rfiles[@]}" -gt 0 ] || return 0
  # plain `read -r mt f` (NOT `IFS= read`) so "<mtime> <path>" splits into two.
  # 🔴 #34 round-2 P3-1: this tail used to be `sid="$( _codex_meta_field "$f" id )"`
  # — a fork AND a file read PER ROW, after the cut. That made the board's ask
  # width a real cost here (measured: 10 -> 200 rows ≈ +85 ms on a 1,000-rollout
  # tank), while home.sh's comment claimed "the widened ask is free" on the
  # strength of agy, the one engine with no such tail. The sid is in the NAME:
  # `rollout-<ts>-<uuid>.jsonl`, the same fact _codex_find_rollout has always
  # used to go the other way (sid -> file), read here through the one function
  # that owns the rule. A name that does not end in a uuid is not a shape codex
  # writes, so it falls back to the body read rather than guessing.
  sessions_by_mtime "${rfiles[@]}" | head -n "$limit" | while read -r mt f; do
    [ -f "$f" ] || continue
    _codex_sid_from_path "$f"; sid="$_CODEX_SID"
    case "$sid" in
      ????????-????-????-????-????????????) : ;;
      *) sid="$(_codex_meta_field "$f" id)" ;;
    esac
    [ -n "$sid" ] || continue
    printf '%s\037%s\n' "$mt" "$sid"
  done
}

# A session's title for the board: codex records the user's prompt as an event_msg
# with payload.type "user_message" carrying "message". Take the first, flatten
# escapes/whitespace (no jq). Empty → the board shows the age instead.
adapter_session_title() {
  local dir="$1" sid="$2" f
  [ -n "$sid" ] || return 0
  f="$(_codex_find_rollout "$dir" "$sid")"
  adapter_title_for_file "$f"
}

# Optional hook: title straight from a rollout FILE (see claude.sh's twin for
# why: cross-project listings can't derive the path from $PWD). Escape-aware
# =~ extraction — the old ${line%%\"*} surgery truncated at an internal \".
# No customTitle-equivalent here: codex's rollout format has no user-rename
# event to prefer (checked 2026-07-12 alongside claude.sh's customTitle fix;
# nothing invented — first user_message stays the only title source).
#
# Anchors on _CODEX_USER_MESSAGE_TYPE_RE, the SAME regex
# adapter_handoff_extract's "user" branch uses above — one model of "what a
# codex human prompt looks like" shared by both (round-1 review P2-2), not
# two independent guesses. Bounded to the first 100 lines, so the
# `[[ =~ ]]` nested-star risk that pushed the whole-file extractor onto
# awk/index()/substr() doesn't apply here.
adapter_title_for_file() {
  if declare -F reading_cache_run >/dev/null; then
    reading_cache_run codex-title "$1" _codex_title_uncached "$@"
  else
    _codex_title_uncached "$@"
  fi
}

_codex_title_uncached() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0

  local re_msg='"message"[[:space:]]*:[[:space:]]*"(([^"\]|\\.)*)"'
  local line_in idx_in=0 max_lines_in=100 title_in=""
  while IFS= read -r line_in; do
    idx_in=$((idx_in + 1))
    [ "$idx_in" -gt "$max_lines_in" ] && break
    if [[ "$line_in" =~ $_CODEX_USER_MESSAGE_TYPE_RE ]] && [[ $line_in =~ $re_msg ]]; then
      title_in="${BASH_REMATCH[1]}"
      break
    fi
  done < "$f" 2>/dev/null

  [ -n "$title_in" ] || title_in="(no preview)"
  title_in="${title_in//\\n/ }"
  title_in="${title_in//\\t/ }"
  title_in="${title_in//\\\"/\"}"
  printf '%s' "$title_in"
}

adapter_find_session() {
  _codex_find_rollout "$1" "$2"
}

adapter_session_cwd() {
  _codex_meta_field "$1" cwd
}

# Optional hook: the canonical session id for a rollout PATH — see claude.sh's
# twin for why this exists (#74 round-1 P1-1). codex's filename is
# `rollout-<ISO-ts-with-dashes-for-colons>-<uuid>.jsonl`: a v4 uuid embeds
# hyphens of its own (8-4-4-4-12), so a naive "everything after the last
# hyphen" (the picker's old shape, resume.sh's `_resume_session_fields`) kept
# only the UUID'S OWN LAST SEGMENT, not the whole id — it never matched what
# burn actually recorded (which reads payload.id from the file body, the
# correct value). A codex uuid is always exactly 36 characters;
# `_clean_session_is_live` (clean.sh) already trusted exactly this fact for
# its live-session guard ("ps only ever shows the bare uuid... keep only its
# trailing 36") — same fact, now the one place every caller reads it from,
# string-only (no file read) so this stays cheap in a per-session scan.
adapter_sid_canonical() {
  _codex_sid_from_path "$1"
  printf '%s' "$_CODEX_SID"
}

# _codex_sid_from_path <rollout-path> -> sets $_CODEX_SID. The same rule as
# adapter_sid_canonical above, in its no-subshell form: adapter_recent_sids runs
# it once per row and a `$( … )` there is a fork per row. `return 0` is not
# decoration — the last command is a test, so without it this function would
# hand its caller rc=1 whenever the name is exactly 36 characters, and THAT is
# the shape `set -e` actually kills (a failing test as a function's last
# command), not the `[ … ] && cmd` an earlier comment blamed.
_codex_sid_from_path() {
  _CODEX_SID="${1##*/}"; _CODEX_SID="${_CODEX_SID%.jsonl}"
  if [ "${#_CODEX_SID}" -gt 36 ]; then
    _CODEX_SID="${_CODEX_SID:$(( ${#_CODEX_SID} - 36 ))}"
  fi
  return 0
}

# Optional hook: EVERY transcript path under this profile dir — no cwd
# filter, no limit, no per-file reads. Used by `clikae burn`'s before/after
# snapshot (#74 P1-2): the session THIS run produced is whichever rollout
# exists after launch that did not exist before — a proven attribution, unlike
# the old "newest transcript with mtime >= attempt start" heuristic, which
# happily picked up a HUMAN's concurrent session in the same tank (R1-P1-2).
adapter_all_transcripts() {
  find "$1/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null
}

# Same raw two-window status evidence used by limit_codex_status — scanning
# rollouts modified in the last 7 days (`_limit_codex_rate_limits`'s
# `-mmin -10080`; see docs/DESIGN-board-fuel-dots.md's Vendor usage cache
# section). P2-4 (round-1 review): this is NOT a live vendor call — no
# `codex` process runs here, ever — so it is honestly `source:"transcript"`,
# never `"vendor"` (the old code claimed vendor regardless, and #72's own
# acceptance criteria named "transcript" as a real, reachable value that
# nothing in the repo ever produced). `cached_at` is set from the winning
# event's OWN timestamp (the 7th field _limit_codex_rate_limits now
# returns), not "now" — usage_read only falls back to "now" when a reading
# carries no usable event time of its own, so a week-old rollout is never
# stamped as freshly read.
adapter_usage() {
  local fields pu _pw pr su _sw sr ts
  fields="$(_limit_codex_rate_limits "$1" 2>/dev/null)" || return 1
  IFS=$'\037' read -r pu _pw pr su _sw sr ts <<< "$fields"
  jq -cn --arg pu "$pu" --arg su "$su" --arg pr "$pr" --arg sr "$sr" --arg ts "$ts" '
    def pct: try tonumber catch null;
    def stamp: try (tonumber | todateiso8601) catch null;
    def norm_stamp: sub("\\.[0-9]+";"") | sub("[+-]00:00$";"Z");
    {window_pct:($pu|pct),weekly_pct:($su|pct),
     window_resets_at:($pr|stamp),weekly_resets_at:($sr|stamp),source:"transcript",
     event_epoch:(if $ts == "" then null else ($ts|norm_stamp|try fromdateiso8601 catch null) end)}'
}

# shellcheck shell=bash
# lib/core/autonomy.sh — how much clikae may do on its own when a tank runs dry.
#
# A user-chosen spectrum (informed-consent, sudo-style — see memory
# feedback-informed-consent-power), stored in $CLIKAE_HOME/autonomy:
#   ask   (default) — on a dry tank, ASK before carrying onward (the consent
#                     moment; choosing "always" here flips to `safe`).
#   safe            — auto-carry to the next SAME-engine tank (a seamless resume);
#                     PAUSE/ask before crossing engines (a lossy cold-start brief).
#   full            — auto-carry to whatever is next in the burn order, including
#                     across engines. The "just keep going" / SU mode.
#
# Only the supervised launch (lib/commands/switch.sh) consumes this — and that's
# BETA, claude-only for now (see docs/DESIGN-runtime.md). The toggle ships WITH its
# consumer so it's never a phantom switch.

autonomy_filev() { _AUTONOMY_FILE="$CLIKAE_HOME/autonomy"; }
autonomy_file()  { autonomy_filev; printf '%s\n' "$_AUTONOMY_FILE"; }

# autonomy_getv -> sets $_AUTONOMY to ask | safe | full.
#
# The board's frame asks this TWICE, and the old form forked three times a call —
# `$(autonomy_file)` twice plus a `tr` — to read one word from a one-line file.
# `$(<file)` is bash's own read: no subprocess at all. The `${//}` strips exactly
# what `tr -d '[:space:]'` did, over the whole content rather than one line, so a
# file that somehow holds a stray newline normalises the same way it always did.
autonomy_getv() {
  local v=""
  autonomy_filev
  if [ -f "$_AUTONOMY_FILE" ]; then
    v="$(<"$_AUTONOMY_FILE")" || v=""
    v="${v//[[:space:]]/}"
  fi
  case "$v" in safe|full) _AUTONOMY="$v" ;; *) _AUTONOMY='ask' ;; esac
}

# autonomy_get -> ask | safe | full  (default ask; unknown content normalises to ask).
autonomy_get() { autonomy_getv; printf '%s' "$_AUTONOMY"; }

# autonomy_set <ask|safe|full> -> persist. Returns 1 on an unknown level.
autonomy_set() {
  case "$1" in
    ask|safe|full) : ;;
    *) return 1 ;;
  esac
  mkdir -p "$CLIKAE_HOME" 2>/dev/null || true
  printf '%s\n' "$1" > "$(autonomy_file)" 2>/dev/null || true
}

# autonomy_label <level> -> a short human description for status/help.
autonomy_label() {
  case "$1" in
    ask)  printf 'ask first' ;;
    safe) printf 'auto same-engine, ask to cross' ;;
    full) printf 'full auto (incl. cross-engine)' ;;
    *)    printf '%s' "$1" ;;
  esac
}

# shellcheck shell=bash
# lib/core/burn_knobs.sh — which model and reasoning effort a burn runs with (#237).
#
# An orchestrator picks a tank by its quota, not by its profile, so until this
# existed a burn ran on whatever the tank happened to declare — or on the
# engine's default when it declared nothing — and nothing in the output said
# which. Writing "Effort: high" in the prompt changes nothing and reads as if
# it did. So every burn now SAYS the model and effort, and where each came from:
#
#   flag        burn's own --model/--effort, or the engine's flag in the argv
#               after `--`
#   env         a variable the engine documents as outranking its settings file
#   profile     the tank's own config, read the way the engine reads it
#   undeclared  none of the above: the engine's default decides
#   unknown     the argv after `--` sets it, in a form that cannot be read with
#               certainty — reported as that rather than as a confident guess
#
# A model name belongs to ONE engine, so burn's --model never crosses a
# cross-engine reroute: the destination's model is --to-model, or a pinned
# model with such a --to is refused before anything starts
# (_burn_knobs_check_hop). An effort level crosses only if the destination
# engine accepts that level too.
#
# What an engine can be told, and how its profile is read, lives with the
# engine — three optional adapter hooks, plus the adapter's own
# adapter_burn_flags, which emits the flags (so a cross-engine reroute
# regenerates them in the new engine's dialect):
#
#   adapter_burn_knobs_check <model> <effort>
#       rc 0 when the engine can honour both (either may be empty = not
#       asked); otherwise rc 1 and one line saying why. An adapter WITHOUT
#       this hook honours neither.
#   adapter_burn_knobs_from_args <argv...>
#       `model=<v>` / `effort=<v>` lines for what the argv itself names, read
#       with the engine's own option syntax, terminator and precedence; a bare
#       `model?` / `effort?` line when the argv sets one but the value that
#       results cannot be read with certainty.
#   adapter_burn_knobs_declared <tank-dir> <model-in-use>
#       `model<TAB><source><TAB><value>`, `effort<TAB><source><TAB><value>` and
#       `note<TAB><text>[<TAB><about>]` lines for what the environment and the
#       profile declare. A note explains an undeclared value: <about> says
#       which — `effort` (the default) or `any` (the model or the effort).
#
# agy has no adapter, so its three answers are spelled out here.
#
# State is cmd_burn's locals, read through bash's dynamic scope — the same
# convention _burn_result and _burn_status_write already use:
#   burn_model_flag / burn_effort_flag     what --model / --effort asked for
#   burn_to_model                          what --to-model asked for
#   burn_model, burn_model_source,
#   burn_effort, burn_effort_source        the effective values
#   burn_knobs_notes                       newline-separated remarks for the log

# The levels agy's own --help lists for --effort (agy 1.5.9).
_BURN_KNOBS_AGY_EFFORTS="low medium high xhigh max"

# _burn_knobs_is_agy <engine>
_burn_knobs_is_agy() { case "$1" in agy|antigravity) return 0 ;; esac; return 1; }

# _burn_knobs_asked -> the flags the caller gave, as text for a message:
# `--model`, `--effort` or `--model/--effort`; empty when neither was given.
_burn_knobs_asked() {
  local out=""
  [ -z "${burn_model_flag:-}" ] || out="--model"
  [ -z "${burn_effort_flag:-}" ] || out="${out:+$out/}--effort"
  printf '%s' "$out"
}

# _burn_knobs_check <engine> — can the engine that is loaded right now (or agy)
# honour what --model/--effort asked for? rc 0 yes (or nothing was asked);
# rc 1 with the reason in _BURN_KNOBS_REFUSAL.
_burn_knobs_check() {
  local eng="$1" why=""
  _BURN_KNOBS_REFUSAL=""
  [ -n "${burn_model_flag:-}${burn_effort_flag:-}" ] || return 0
  if _burn_knobs_is_agy "$eng"; then
    if [ -n "${burn_effort_flag:-}" ] && [[ " $_BURN_KNOBS_AGY_EFFORTS " != *" $burn_effort_flag "* ]]; then
      _BURN_KNOBS_REFUSAL="agy cannot honour --effort $burn_effort_flag: its --effort accepts ${_BURN_KNOBS_AGY_EFFORTS// /, }."
      return 1
    fi
    return 0
  fi
  if ! declare -F adapter_burn_knobs_check >/dev/null 2>&1; then
    _BURN_KNOBS_REFUSAL="$eng cannot honour $(_burn_knobs_asked): clikae has no verified model or effort flag for this engine."
    return 1
  fi
  why="$(adapter_burn_knobs_check "${burn_model_flag:-}" "${burn_effort_flag:-}" 2>/dev/null)" || {
    _BURN_KNOBS_REFUSAL="${why:-$eng cannot honour $(_burn_knobs_asked).}"
    return 1
  }
  return 0
}

# _burn_knobs_check_other <engine> <model> — the same question about an engine
# that is NOT the loaded one (an explicit cross-engine --to), with <model> —
# that engine's own, from --to-model — in place of --model. Asked in a
# subshell so the caller's adapter stays loaded. Same rc / _BURN_KNOBS_REFUSAL
# contract.
_burn_knobs_check_other() {
  local eng="$1" why="" rc=0
  local burn_model_flag="${2:-}"
  _BURN_KNOBS_REFUSAL=""
  [ -n "${burn_model_flag:-}${burn_effort_flag:-}" ] || return 0
  if _burn_knobs_is_agy "$eng"; then _burn_knobs_check "$eng"; return; fi
  # No such engine: the hop itself reports that, in its own words.
  [ -f "$CLIKAE_LIB/adapters/$eng.sh" ] || return 0
  why="$(
    load_adapter "$eng" >/dev/null 2>&1
    _burn_knobs_check "$eng" && exit 0
    printf '%s' "$_BURN_KNOBS_REFUSAL"; exit 1
  )" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  _BURN_KNOBS_REFUSAL="${why:-$eng cannot honour $(_burn_knobs_asked).}"
  return 1
}

# _burn_knobs_check_hop <engine> <to> <argv...> — may this burn, started on
# <engine>, take its explicit --to hop with the model and effort it was given?
# Only a <to> that names another engine is in question. <argv> is what the
# caller put after `--`, read with <engine>'s own option syntax (its adapter
# is the loaded one). rc 0 yes; rc 1 with the reason in _BURN_KNOBS_REFUSAL
# (two sentences, no trailing "Nothing was started.") and a short form in
# _BURN_KNOBS_REFUSAL_REASON.
_burn_knobs_check_hop() {
  local eng="$1" to="$2" dest="" line
  shift 2
  _BURN_KNOBS_REFUSAL=""; _BURN_KNOBS_REFUSAL_REASON=""
  case "$to" in */*) dest="${to%%/*}" ;; esac
  if [ -z "$dest" ] || [ "$dest" = "$eng" ]; then
    [ -z "${burn_to_model:-}" ] || {
      _BURN_KNOBS_REFUSAL="--to-model only applies with a --to that names a different engine (--to <engine>/<tank>); on $eng itself, --model is the one that applies."
      _BURN_KNOBS_REFUSAL_REASON="--to-model without a cross-engine --to"
      return 1
    }
    return 0
  fi
  # What follows `--` goes to every engine this burn launches, byte for byte:
  # a model in it — readable or not — would reach <dest> too, and no flag of
  # burn's can make it one engine's alone. With or without --to-model.
  while IFS= read -r line; do
    case "$line" in
      model=*|'model?')
        _BURN_KNOBS_REFUSAL_REASON="the arguments after -- name a model; --to $to would pass it to $dest unchanged"
        _BURN_KNOBS_REFUSAL="--to $to: the arguments after -- name a model, and they are passed unchanged to both $eng and $dest, so that model cannot be $eng's alone. Take it out of the arguments after -- and name the models with --model (for $eng) and --to-model (for $dest) on a --prompt task, or name none so each tank's profile decides."
        return 1 ;;
    esac
  done < <(_burn_knobs_from_args "$eng" "$@")
  if [ -n "${burn_model_flag:-}" ] && [ -z "${burn_to_model:-}" ]; then
    _BURN_KNOBS_REFUSAL_REASON="--model $burn_model_flag names a $eng model; --to $to needs --to-model"
    _BURN_KNOBS_REFUSAL="--to $to: --model $burn_model_flag names a $eng model, and that reroute would run the task on $dest, where the name means nothing. Add --to-model <m> to name $dest's model, or drop --model so each tank's profile decides."
    return 1
  fi
  if ! _burn_knobs_check_other "$dest" "${burn_to_model:-}"; then
    _BURN_KNOBS_REFUSAL_REASON="$_BURN_KNOBS_REFUSAL"
    _BURN_KNOBS_REFUSAL="--to $to: $_BURN_KNOBS_REFUSAL"
    return 1
  fi
  return 0
}

# _burn_knobs_from_args <engine> <argv...> -> `model=<v>` / `effort=<v>` lines
# (`model?` / `effort?` for one the argv sets unreadably).
_burn_knobs_from_args() {
  local eng="$1"; shift
  if _burn_knobs_is_agy "$eng"; then
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model=*)  printf 'model=%s\n' "${1#--model=}" ;;
        --effort=*) printf 'effort=%s\n' "${1#--effort=}" ;;
        --model|-m) if [ "$#" -ge 2 ]; then printf 'model=%s\n' "$2"; shift; fi ;;
        --effort)   if [ "$#" -ge 2 ]; then printf 'effort=%s\n' "$2"; shift; fi ;;
      esac
      shift
    done
    return 0
  fi
  declare -F adapter_burn_knobs_from_args >/dev/null 2>&1 || return 0
  adapter_burn_knobs_from_args "$@" 2>/dev/null || true
}

# _burn_knobs_resolve <engine> <tank-dir> <argv...> — work out the effective
# model and effort for a launch on this tank. <argv> is what the caller put
# after `--` (the whole command in raw mode, the extras in prompt mode).
# Always rc 0; a knob named both by burn's flag and in <argv> is left for
# _burn_knobs_twice to refuse.
_burn_knobs_resolve() {
  local eng="$1" kdir="$2"; shift 2
  local line kind src val a_model="" a_effort="" unsure=""
  burn_model=undeclared; burn_model_source=undeclared
  burn_effort=undeclared; burn_effort_source=undeclared
  burn_knobs_notes=""; _BURN_KNOBS_TWICE=""
  while IFS= read -r line; do
    case "$line" in
      model=?*)  a_model="${line#model=}" ;;
      effort=?*) a_effort="${line#effort=}" ;;
      'model?')  a_model="?" ;;
      'effort?') a_effort="?" ;;
    esac
  done < <(_burn_knobs_from_args "$eng" "$@")
  # Readable or not, a knob the argv sets is a second naming of it.
  [ -z "${burn_model_flag:-}" ] || [ -z "$a_model" ] || _BURN_KNOBS_TWICE="--model"
  [ -z "${burn_effort_flag:-}" ] || [ -z "$a_effort" ] || _BURN_KNOBS_TWICE="${_BURN_KNOBS_TWICE:+$_BURN_KNOBS_TWICE and }--effort"
  if [ -n "${burn_model_flag:-}" ]; then burn_model="$burn_model_flag"; burn_model_source=flag
  elif [ "$a_model" = "?" ]; then burn_model=unknown; burn_model_source=unknown; unsure="model"
  elif [ -n "$a_model" ]; then burn_model="$a_model"; burn_model_source=flag; fi
  if [ -n "${burn_effort_flag:-}" ]; then burn_effort="$burn_effort_flag"; burn_effort_source=flag
  elif [ "$a_effort" = "?" ]; then burn_effort=unknown; burn_effort_source=unknown; unsure="${unsure:+$unsure and }effort"
  elif [ -n "$a_effort" ]; then burn_effort="$a_effort"; burn_effort_source=flag; fi
  [ -z "$unsure" ] || burn_knobs_notes="the argv after -- sets the $unsure in a form clikae cannot read with certainty, so it is reported as unknown rather than guessed."

  if _burn_knobs_is_agy "$eng"; then
    # agy's --help documents --model and --effort for a session and names no
    # settings.json key for either, so a tank's profile declares neither.
    return 0
  fi
  declare -F adapter_burn_knobs_declared >/dev/null 2>&1 || return 0
  local known_model="" notes=""
  [ "$burn_model_source" = undeclared ] || known_model="$burn_model"
  local any_notes=""
  while IFS=$'\t' read -r kind src val; do
    case "$kind" in
      model)  [ "$burn_model_source" != undeclared ] || [ -z "$val" ] || { burn_model="$val"; burn_model_source="$src"; } ;;
      effort) [ "$burn_effort_source" != undeclared ] || [ -z "$val" ] || { burn_effort="$val"; burn_effort_source="$src"; } ;;
      # A note's text is its second field; the optional third says what it is about.
      note)   if [ "$val" = any ]; then any_notes="${any_notes:+$any_notes$'\n'}$src"
              else notes="${notes:+$notes$'\n'}$src"; fi ;;
    esac
  done < <(adapter_burn_knobs_declared "$kdir" "$known_model" 2>/dev/null || true)
  # A note explains why something reads as undeclared; once a flag or the
  # environment names it there is nothing left to explain.
  [ "$burn_effort_source" = undeclared ] || notes=""
  [ "$burn_model_source" = undeclared ] || [ "$burn_effort_source" = undeclared ] || any_notes=""
  for line in "$any_notes" "$notes"; do
    [ -z "$line" ] || burn_knobs_notes="${burn_knobs_notes:+$burn_knobs_notes$'\n'}$line"
  done
  return 0
}

# _burn_knobs_line <engine> <tank> -> the line a burn opens with.
_burn_knobs_line() {
  local m="${burn_model:-undeclared}" e="${burn_effort:-undeclared}"
  case "${burn_model_source:-undeclared}" in undeclared|unknown) ;; *) m="$m ($burn_model_source)" ;; esac
  case "${burn_effort_source:-undeclared}" in undeclared|unknown) ;; *) e="$e ($burn_effort_source)" ;; esac
  printf 'burn %s/%s: model %s, effort %s' "$1" "$2" "$m" "$e"
}

# _burn_knobs_announce <engine> <tank> — print that line, then any remark the
# adapter had about why something reads as undeclared.
_burn_knobs_announce() {
  log_info "$(_burn_knobs_line "$1" "$2")"
  local note
  [ -n "${burn_knobs_notes:-}" ] || return 0
  while IFS= read -r note; do
    [ -z "$note" ] || log_info "  $note"
  done <<<"$burn_knobs_notes"
}

# _burn_knobs_missing [<source>] -> which of the two has that source
# (default `undeclared`): `model`, `effort`, `model or effort`, or nothing.
_burn_knobs_missing() {
  local want="${1:-undeclared}" out=""
  [ "${burn_model_source:-undeclared}" != "$want" ] || out="model"
  [ "${burn_effort_source:-undeclared}" != "$want" ] || out="${out:+$out or }effort"
  printf '%s' "$out"
}

# _burn_knobs_refuse <engine> <tank> <hop:0|1> <reason> <message> — stop the
# burn: the message on stderr, a terminal `fail` row in the status file, the
# --json object, exit 1. Up front (hop 0) nothing has run, so the object is
# written without _burn_result's left-behind scan — which would report the
# caller's own dirty tree as if this burn had touched it (the same call
# _burn_check_codex_artifact_scope makes). On a reroute hop the earlier tank
# DID run, so _burn_result does the reporting.
_burn_knobs_refuse() {
  local eng="$1" tk="$2" hop="$3" reason="$4" msg="$5"
  log_err "$msg"
  _burn_status_write fail false "$eng" "$tk" "${artifact:-}" "$reason" ""
  if [ "$hop" -eq 1 ]; then
    _burn_result false "$eng" "$tk" "${artifact:-}" "$reason" ""
  elif [ "${as_json:-0}" -eq 1 ]; then
    printf '{"ok":false,"engine":%s,"tank":%s,"artifact":%s,"artifact_bytes":null,"reason":%s,"reset":null,"rerouted_from":[],"elapsed_s":0,"queued_for_s":0,"run_id":null,"resumed":0,%s,"left_behind":[],%s}\n' \
      "$(json_or_null "$eng")" "$(json_or_null "$tk")" "$(json_or_null "${artifact:-}")" \
      "$(json_str "$reason")" "$(_burn_knobs_json)" "$(_burn_lb_meta 0 0 0 0 0)" >&4
  fi
  exit 1
}

# _burn_knobs_gate <engine> <tank> <tank-dir> <hop:0|1> <require:0|1> <argv...>
# — the one door every launch target passes: the tank a burn names (hop 0)
# and each tank it reroutes onto (hop 1). Refuses what the engine cannot
# honour, works out and announces the effective model and effort, then
# applies --require-declared (<require> 1). <argv> is what the caller put
# after `--`.
_burn_knobs_gate() {
  local eng="$1" tk="$2" kdir="$3" hop="$4" require_declared="$5"; shift 5
  local tail="Nothing was started." missing=""
  [ "$hop" -eq 0 ] || tail="The reroute onto $eng/$tk was not started."
  if ! _burn_knobs_check "$eng"; then
    _burn_knobs_refuse "$eng" "$tk" "$hop" "refused: $_BURN_KNOBS_REFUSAL" "$_BURN_KNOBS_REFUSAL $tail"
  fi
  _burn_knobs_resolve "$eng" "$kdir" "$@"
  if [ -n "$_BURN_KNOBS_TWICE" ]; then
    _burn_knobs_refuse "$eng" "$tk" "$hop" "refused: $_BURN_KNOBS_TWICE given twice" \
      "$_BURN_KNOBS_TWICE is given twice — to burn, and again in the argv after --. Name it once. $tail"
  fi
  _burn_knobs_announce "$eng" "$tk"
  [ "$require_declared" -eq 1 ] || return 0
  # Unknown is not declared: the whole point of the flag is knowing what runs.
  missing="$(_burn_knobs_missing unknown)"
  [ -z "$missing" ] || _burn_knobs_refuse "$eng" "$tk" "$hop" "refused: unknown $missing" \
    "--require-declared: the $missing of $eng/$tk cannot be determined — the argv after -- sets it in a form clikae cannot read with certainty. Write it as a plain quoted value, or name it with --model / --effort. $tail"
  missing="$(_burn_knobs_missing)"
  [ -n "$missing" ] || return 0
  _burn_knobs_refuse "$eng" "$tk" "$hop" "refused: undeclared $missing" \
    "--require-declared: $eng/$tk declares no $missing — neither a flag nor its profile names one. Pass --model / --effort, or set it in the tank's profile. $tail"
}

# _burn_knobs_json -> the four members every burn result and status row carry.
_burn_knobs_json() {
  printf '"model":%s,"model_source":%s,"effort":%s,"effort_source":%s' \
    "$(json_str "${burn_model:-undeclared}")" "$(json_str "${burn_model_source:-undeclared}")" \
    "$(json_str "${burn_effort:-undeclared}")" "$(json_str "${burn_effort_source:-undeclared}")"
}

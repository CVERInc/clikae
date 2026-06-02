# shellcheck shell=bash
# lib/core/profile_store.sh — profile directory layout helpers.
#
# Layout:
#   $CLIKAE_HOME/
#     profiles/
#       <cli>/
#         <profile>/      <- the actual config dir that the CLI's env var points at
#     adapters/           <- user-defined adapter overrides (TODO v0.2)

store_root() {
  printf '%s\n' "$CLIKAE_HOME"
}

profiles_root() {
  printf '%s/profiles\n' "$CLIKAE_HOME"
}

# profile_dir <cli> <profile>
profile_dir() {
  printf '%s/profiles/%s/%s\n' "$CLIKAE_HOME" "$1" "$2"
}

# profile_exists <cli> <profile>
profile_exists() {
  [ -d "$(profile_dir "$1" "$2")" ]
}

# Validate that <cli> and <profile> are sane names (no slashes, no leading dot, no whitespace).
validate_name() {
  local kind="$1"   # "cli" or "profile"
  local name="$2"
  if [ -z "$name" ]; then
    log_fail "$kind name is empty."
  fi
  case "$name" in
    .*|*/*|*\ *|*$'\t'*|*$'\n'*)
      log_fail "Invalid $kind name: '$name' (no leading dot, no slashes, no whitespace)."
      ;;
  esac
  # Keep it ASCII-friendly for cross-platform paths. Allow letters, digits, dot, dash, underscore.
  if ! printf '%s' "$name" | LC_ALL=C grep -Eq '^[A-Za-z0-9._-]+$'; then
    log_fail "Invalid $kind name: '$name'. Allowed: A-Z a-z 0-9 . _ -"
  fi
}

# List every profile as "<cli> <profile> <path>" lines, sorted.
list_all_profiles() {
  local root
  root="$(profiles_root)"
  [ -d "$root" ] || return 0
  local cli_dir cli profile_path profile
  for cli_dir in "$root"/*/; do
    [ -d "$cli_dir" ] || continue
    cli="$(basename "$cli_dir")"
    for profile_path in "$cli_dir"*/; do
      [ -d "$profile_path" ] || continue
      profile="$(basename "$profile_path")"
      printf '%s\t%s\t%s\n' "$cli" "$profile" "${profile_path%/}"
    done
  done | sort
}

# order_file -> the burn-order file. One "<engine>/<tank>" per line, top first.
# The board IS this order; there is no separate "pool". Optional — when absent or
# partial, order_list fills in the rest deterministically.
order_file() { printf '%s\n' "$CLIKAE_HOME/order"; }

# order_list -> every EXISTING tank as "<engine>/<tank>", in BURN ORDER: first the
# order-file entries that still exist (in file order), then any remaining tanks in
# default (list_all_profiles) order. Always complete + deterministic, so callers
# never need to special-case "not configured".
order_list() {
  local f all listed line
  all="$(list_all_profiles | awk -F'\t' 'NF>=2{print $1"/"$2}')"
  [ -n "$all" ] || return 0
  f="$(order_file)"
  listed=""
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [ -n "$line" ] || continue
      printf '%s\n' "$all" | grep -qxF "$line" || continue       # still exists?
      printf '%s\n' "$listed" | grep -qxF "$line" && continue    # de-dupe
      printf '%s\n' "$line"
      listed="$listed$line"$'\n'
    done < "$f"
  fi
  printf '%s\n' "$all" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$listed" | grep -qxF "$line" && continue
    printf '%s\n' "$line"
  done
}

# next_tank <engine> <current>  -> the next tank to fall through to when
# <engine>/<current> runs dry: the entry AFTER it in the BURN ORDER (order_list),
# crossing engines if that's what your order says — your tanks ARE the reserve, so
# the list is the order. Skips tanks that are themselves over quota (via
# limit_profile_dry when available). Echoes "<engine>\t<tank>" (TAB-separated), or
# nothing when there's nothing after <current>. NB: no wrap — a burn order falls
# DOWN the list once; it doesn't cycle back up.
next_tank() {
  local engine="$1" current="$2"
  local cur="$engine/$current"
  local seen=0 entry e t path first_after="" first_after_healthy=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "$seen" -eq 0 ]; then
      [ "$entry" = "$cur" ] && seen=1
      continue
    fi
    e="${entry%%/*}"; t="${entry#*/}"
    [ -n "$first_after" ] || first_after="$e"$'\t'"$t"
    path="$(profile_dir "$e" "$t")"
    if declare -F limit_profile_dry >/dev/null 2>&1 \
       && limit_profile_dry "$e" "$path" >/dev/null 2>&1; then
      continue
    fi
    first_after_healthy="$e"$'\t'"$t"; break
  done <<EOF
$(order_list)
EOF
  printf '%s' "${first_after_healthy:-$first_after}"
}

# resolve_tank_name <name>  -> "<engine>\t<tank>" line(s) for every tank whose
# NAME equals <name>, across all engines. Powers the bare `clikae <name>` shortcut
# (scheme B): a tank's name is its identity, so you can switch to it without typing
# the engine. 0 lines = no such name; 1 = unambiguous; >1 = same name in multiple
# engines (caller disambiguates).
resolve_tank_name() {
  local want="$1" cli profile path
  [ -n "$want" ] || return 0
  while IFS=$'\t' read -r cli profile path; do
    [ -n "$cli" ] || continue
    [ "$profile" = "$want" ] && printf '%s\t%s\n' "$cli" "$profile"
  done <<EOF
$(list_all_profiles)
EOF
}

# resolve_active_profile <cli> <strategy> <value>
# Given the live value of an adapter's env var, echo the clikae profile it
# corresponds to (or nothing). Used by `clikae status` and `clikae relay` to
# answer "which profile is this CLI on right now?".
#   env-var strategy  -> the value IS the profile name (e.g. AWS_PROFILE=work)
#   everything else   -> the value is a path; match it to a profile dir (a
#                        profile dir, or a file/subpath seeded inside one)
resolve_active_profile() {
  local cli="$1" strategy="$2" value="$3"
  [ -n "$value" ] || return 0
  case "$strategy" in
    env-var)
      profile_exists "$cli" "$value" && printf '%s\n' "$value"
      ;;
    *)
      local norm="${value%/}" pdir profile root
      root="$(profiles_root)/$cli"
      [ -d "$root" ] || return 0
      for pdir in "$root"/*/; do
        [ -d "$pdir" ] || continue
        profile="$(basename "$pdir")"
        pdir="${pdir%/}"
        if [ "$norm" = "$pdir" ] || case "$norm" in "$pdir"/*) true ;; *) false ;; esac; then
          printf '%s\n' "$profile"
          return 0
        fi
      done
      ;;
  esac
}

# Ensure profile_dir exists. Pass --create to mkdir, --require to fail if missing.
ensure_profile() {
  local mode="$1" cli="$2" profile="$3"
  local d
  d="$(profile_dir "$cli" "$profile")"
  case "$mode" in
    --create)
      mkdir -p "$d"
      ;;
    --require)
      [ -d "$d" ] || log_fail "Profile not found: $cli/$profile  (expected at $d)"
      ;;
    *)
      log_fail "ensure_profile: unknown mode '$mode'"
      ;;
  esac
  printf '%s\n' "$d"
}

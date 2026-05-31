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

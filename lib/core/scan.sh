# shellcheck shell=bash
# lib/core/scan.sh — a read-only scan of THIS machine: which supported CLIs are
# installed, how many clikae profiles each has, and (when a profile exists) the
# logged-in account label.
#
# One canonical US-delimited row per adapter feeds both `clikae doctor` and the
# new-user home screen, so the two can never drift. Touches nothing on disk.

# scan_clis  -> one row per supported CLI, fields separated by ASCII Unit
# Separator (\037), record terminated by newline:
#   cli ␟ installed(1|0) ␟ binary ␟ strategy ␟ profileCount ␟ label
# label is the account of the first profile that exposes one (best-effort), else
# empty. (A non-whitespace delimiter is deliberate: tab is IFS-whitespace, so
# `read` would collapse the empty label field and shift the columns.)
scan_clis() {
  local cli
  while IFS= read -r cli; do
    [ -n "$cli" ] || continue
    (
      load_adapter "$cli" >/dev/null 2>&1 || exit 0
      local binary strategy installed=0 count=0 label="" pdir root
      binary="$(adapter_meta_cli_binary)"
      strategy="$(adapter_meta_strategy)"
      command -v "$binary" >/dev/null 2>&1 && installed=1
      root="$(profiles_root)/$cli"
      if [ -d "$root" ]; then
        for pdir in "$root"/*/; do
          [ -d "$pdir" ] || continue
          count=$((count + 1))
          [ -n "$label" ] || label="$(adapter_label "${pdir%/}")"
        done
      fi
      printf '%s\037%d\037%s\037%s\037%d\037%s\n' \
        "$cli" "$installed" "$binary" "$strategy" "$count" "$label"
    )
  done <<EOF
$(list_adapters)
EOF
}

# agy_email <tank_dir> -> the Google account this agy tank is signed in as, scraped
# verbatim from the most recent "email=<x>" line in its antigravity-cli/log, or
# empty. agy keeps no account email on disk except in that log (the login itself
# lives in the Keychain), so this is the one honest read. Shared by `clikae list`
# and the home board so the two agree on agy's ACCOUNT column.
# It used to `grep -r` the WHOLE log directory and take the last match. agy writes
# one log per launch and never prunes, so on a tank in daily use that became 362
# files / 17 MB re-read on every single board frame — 198 ms of a 708 ms board,
# for one account label, growing with every launch. The board got slower the more
# you used it.
#
# Two things that read as bugs against the description above fall out of the fix:
#   · "most recent" was readdir order, not time. Whichever file the filesystem
#     happened to hand back last won. It agrees with recency only because the
#     names sort chronologically AND the directory happens to come back sorted —
#     neither is promised. Re-log a tank into a different Google account and the
#     column could keep showing the old one. Newest mtime first, first hit wins.
#   · agy sometimes writes a NUL byte into a log, and `grep` without -a treats
#     that whole file as binary and prints NOTHING for it. The account in such a
#     log was invisible: a tank whose only logs are binary showed a blank column.
#
# The read is bounded from the HEAD, not the tail: the login line is written at
# launch, and across all 372 logs on the dogfood machine the last email= sat at
# byte 23,200 at the very furthest. 256 KiB is an order of magnitude of headroom;
# a tail read would have missed it completely on the 841 KB logs.
CLIKAE_AGY_LOG_HEAD_BYTES="${CLIKAE_AGY_LOG_HEAD_BYTES:-262144}"   # 256 KiB

# _agy_email_scan <file> -> the last account named in this ONE log, or nothing.
# -a because agy writes NUL bytes into these; without it grep calls the file
# binary and prints nothing at all.
_agy_email_scan() {
  local hit
  hit="$(head -c "$CLIKAE_AGY_LOG_HEAD_BYTES" "$1" 2>/dev/null \
           | grep -aohE 'email=[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
           | tail -n 1)" || true
  [ -n "$hit" ] && printf '%s\n' "${hit#email=}"
  return 0
}

agy_email() {
  local d="$1/antigravity-cli/log" f hit
  # On a real install `log` is a DIRECTORY of one file per launch. Accept a plain
  # file too — the old `grep -r` took either without noticing the difference, and
  # a layout that stops working silently is exactly the kind of thing that shows
  # up as a blank account column rather than as an error.
  [ -f "$d" ] && { _agy_email_scan "$d"; return 0; }
  [ -d "$d" ] || return 0
  while IFS= read -r f <&3; do
    [ -f "$f" ] || continue
    hit="$(_agy_email_scan "$f")"
    [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
    # Process substitution, not a heredoc: a heredoc would fork a subshell just to
    # hold the list. Read on fd 3 so the loop body keeps its own stdin.
  done 3< <(sessions_by_mtime "$d"/* | cut -d' ' -f2-)
  return 0
}

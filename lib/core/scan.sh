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

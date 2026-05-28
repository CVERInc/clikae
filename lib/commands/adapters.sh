# shellcheck shell=bash
# lib/commands/adapters.sh — `clikae adapters`

cmd_adapters() {
  echo "Built-in adapters:"
  echo ""
  printf '  %b%-12s %-12s %-20s %s%b\n' "$__C_BOLD" "CLI" "STRATEGY" "ENV VAR" "DESCRIPTION" "$__C_RESET"

  local cli
  while IFS= read -r cli; do
    [ -n "$cli" ] || continue
    (
      load_adapter "$cli" >/dev/null 2>&1
      printf '  %-12s %-12s %-20s %s\n' \
        "$cli" \
        "$(adapter_meta_strategy)" \
        "$(adapter_meta_env_var)" \
        "$(adapter_meta_description)"
    )
  done < <(list_adapters)

  echo ""
  echo "To add your own adapter, see docs/adding-an-adapter.md"
}

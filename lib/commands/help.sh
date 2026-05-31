# shellcheck shell=bash
# lib/commands/help.sh — `clikae help [command]`

cmd_help() {
  if [ -n "${1:-}" ]; then
    local sub="$1"
    local f="$CLIKAE_LIB/commands/$sub.sh"
    if [ -f "$f" ]; then
      # shellcheck source=/dev/null
      source "$f"
      "cmd_$sub" --help
      return 0
    else
      log_err "No such command: $sub"
      echo ""
    fi
  fi

  cat <<'EOF'
clikae - CLI profile switcher  /  ｷﾘｶｴ (切り替え)

Usage:
  clikae                           Open the home dashboard (your tanks)
  clikae <command> [args...]

Commands:
  doctor                           Read-only health check: what clikae can do here
  init <cli> <profile>             Create a new profile for a CLI tool
  app <cli> <profile>              Generate a macOS launcher .app
  alias <cli> <profile>            Write a shell alias for the profile
  run <cli> <profile> [-- args]    Run a CLI with the given profile (no alias needed)
  relay <cli> [from] <to>          Hand the current session to another profile (e.g. on a usage limit)
  handoff <cli> [profile]          Write a portable handoff brief (--to switches model/vendor)
  watch <cli> [profile]            Watch for a dry tank and offer/auto switch to the next one
  pool [add|remove] [target]       Manage the fuel pool (ordered tanks for watch to fall through)
  list                             List all profiles (with the logged-in account)
  status [cli]                     Show which profile each CLI is on in this shell
  rename <cli> <old> <new>         Rename a profile (dir, alias, login carried over)
  remove <cli> <profile>           Remove a profile (dir, alias, .app)
  migrate [cli]                    Adopt a hand-rolled config-dir + alias setup
  info                             Show install paths and counts
  adapters                         List supported CLIs
  help [command]                   Show help (run `clikae help <cmd>` for details)
  version                          Print clikae version

Common flow:
  clikae init claude work --alias  # creates ~/.clikae/profiles/claude/work + adds claude-work alias
  clikae app claude work           # creates ~/Applications/claude (work).app
  source ~/.zshrc                  # pick up the new alias
  claude-work                      # go!

For details on any command:
  clikae help <command>      OR      clikae <command> --help

Docs:
  README              .../clikae/README.md
  Add your own CLI    .../clikae/docs/adding-an-adapter.md

clikae is an unofficial community tool. It is not affiliated with or endorsed
by any of the CLI vendors it integrates with.
EOF
}

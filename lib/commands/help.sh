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
clikae - switch your CLIs between accounts  /  ｷﾘｶｴ (切り替え)

clikae is a verb: it switches an ENGINE (a CLI like claude, codex, agy) between
TANKS (accounts/configs you can burn). The main action carries no verb of its
own — the program name IS the verb.

Switch (the main thing — no verb needed):
  clikae <engine> <tank>           switch <engine> to <tank> and run it
  clikae <engine>                  one tank → use it; several → list them
  clikae to <target> [tank]        carry your CURRENT session onto another tank
                                   (same engine → resume; another → a brief)
  eval "$(clikae env <engine> <tank>)"   put THIS shell on a tank (so to/status see it)

Make & manage tanks:
  init <engine> <tank>             create a new tank   (--alias adds a shell alias)
  remove <engine> <tank>           remove a tank (dir, alias, .app)
  rename <engine> <old> <new>      rename a tank (login carried over)
  git-id <engine> <tank>           set a tank's git commit identity (--name --email)
  migrate [engine]                 adopt a hand-rolled config-dir + alias setup

Keep burning when a tank runs dry:
  to [target]                      carry your session to the next tank (bare = next
                                   in your burn order); your tanks ARE the reserve
  auto [ask|safe|full]             how much clikae carries on its own (BETA, claude)
  watch <engine> [tank]            watch for a dry tank and switch onward
  burn <engine> <tank> -- <cmd>    run a headless task on a tank; on a dry tank,
                                   re-fire it on the next (verify by --artifact)
  conduct --leg <e>/<t>... --prompt-file <f>   (BETA) fan ONE prompt across N
                                   accounts in parallel, collect each full result

Use & inspect:
  app <engine> <tank>              generate a macOS launcher .app
  alias <engine> <tank>            write a shell alias for the tank
  lang [en-US|ja-JP|zh-TW]         interface language (dashboard + prompts)
  tanks                            list all tanks (with the logged-in account)
  status [engine]                  which tank each engine is on (+ recent carries)
  doctor                           read-only health check: what clikae can do here
  adapters                         list supported engines
  demo                             a 30-second guided tour in a throwaway sandbox

Meta:
  help [command]                   show help (run `clikae help <cmd>` for details)
  version                          print clikae version

Antigravity (agy) is global single-account, but folds into the same verbs:
  clikae init agy <tank> · clikae agy <tank> · clikae remove agy <tank>
  clikae agy --release             restore a normal ~/.gemini, keep your tanks
  clikae agy <tank> -- -p "…"      one-shot dispatch: agy can't `burn`, but -p sends a single prompt

Common flow:
  clikae init claude work --alias  # make a tank (+ a claude-work alias)
  clikae claude work               # switch to it and run
  clikae to personal               # hit a limit? carry the session to another tank

For details on any command:  clikae help <command>   OR   clikae <command> --help

clikae is an unofficial community tool. It is not affiliated with or endorsed
by any of the CLI vendors it integrates with.
EOF
}

#!/usr/bin/env bats
# tests/bats/memory.bats — `clikae memory <share|isolate|status>`: the memory dial
# (docs/memory.md, grammar.md §10.1). share fans N tanks into ONE markdown store
# (Soul); isolate restores a tank's own memory; account isolation stays sacred.
# (NB: `[[ … ]]` assertions carry `|| false` — see tests/README.md.)

load '../helpers'

# The memory dir clikae uses for claude/<tank> at the CURRENT $PWD (slug of $PWD).
_memdir() {
  local slug; slug="$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  printf '%s\n' "$CLIKAE_HOME/profiles/claude/$1/projects/$slug/memory"
}

# Stamp a tank's logged-in account (what adapter_account_label reads).
_set_account() {
  local tank="$1" email="$2"
  printf '{\n  "oauthAccount": { "emailAddress": "%s" }\n}\n' "$email" \
    > "$CLIKAE_HOME/profiles/claude/$tank/.claude.json"
}

# Seed a tank's own memory with one fact file at the current $PWD.
_seed_memory() {
  local tank="$1" name="$2" body="$3" mem
  mem="$(_memdir "$tank")"; mkdir -p "$mem"
  printf '%s\n' "$body" > "$mem/$name"
}

@test "memory share: fans a tank's memory into the group store (seeded by copy)" {
  clikae init claude a
  _seed_memory a MEMORY.md "shared brain v1"
  run clikae memory share me claude a
  [ "$status" -eq 0 ]
  local mem store
  mem="$(_memdir a)"
  [ -L "$mem" ]                                              # now a symlink
  store="$CLIKAE_HOME/souls/me/memory"                       # flat, vendor-neutral canonical
  [ "$(readlink "$mem")" = "$store" ]                        # → the group store
  [ -f "$store/MEMORY.md" ]                                  # seeded by COPY
  run cat "$store/MEMORY.md"
  [[ "$output" == *"shared brain v1"* ]] || false
}

@test "memory share: seeds the Soul PROTOCOL.md without clobbering the copied memory" {
  clikae init claude a
  _seed_memory a MEMORY.md "the brain"
  clikae memory share me claude a
  local store; store="$CLIKAE_HOME/souls/me/memory"
  [ -f "$store/PROTOCOL.md" ]                                # operating manual seeded
  [ -f "$store/MEMORY.md" ]                                  # 🔴 real memory STILL copied (ordering regression)
  run cat "$store/MEMORY.md"; [[ "$output" == *"the brain"* ]] || false
  run cat "$store/PROTOCOL.md"; [[ "$output" == *"read & write this memory"* ]] || false
}

@test "memory share (codex): the pointer note tells the engine to read PROTOCOL.md" {
  clikae init codex H
  clikae memory share me codex H
  run cat "$CLIKAE_HOME/profiles/codex/H/AGENTS.md"
  [[ "$output" == *"PROTOCOL.md"* ]] || false
}

@test "memory share: two tanks (same account) end up on ONE shared brain" {
  clikae init claude a; _set_account a you@example.com
  clikae init claude b; _set_account b you@example.com
  _seed_memory a MEMORY.md "from a"
  clikae memory share me claude a
  run clikae memory share me claude b                        # same account → no prompt
  [ "$status" -eq 0 ]
  local ma mb
  ma="$(_memdir a)"; mb="$(_memdir b)"
  [ -L "$ma" ]; [ -L "$mb" ]
  [ "$(readlink "$ma")" = "$(readlink "$mb")" ]              # SAME store: one brain
  # A fact b writes is visible through a's view (they are the same dir).
  echo "from b" > "$mb/NEW.md"
  [ -f "$ma/NEW.md" ]
  run cat "$ma/NEW.md"
  [[ "$output" == *"from b"* ]] || false
}

@test "memory isolate: round-trips — restores the tank's own stashed memory" {
  clikae init claude a
  _seed_memory a MEMORY.md "private to a"
  clikae memory share me claude a
  local mem; mem="$(_memdir a)"
  [ -L "$mem" ]                                              # shared
  run clikae memory isolate claude a
  [ "$status" -eq 0 ]
  [ ! -L "$mem" ]                                            # symlink gone
  [ -d "$mem" ]                                              # own memory back
  [ -f "$mem/MEMORY.md" ]
  run cat "$mem/MEMORY.md"
  [[ "$output" == *"private to a"* ]] || false               # the stashed fact restored
}

@test "🔴 account isolation: a tank that never opted in cannot see the store" {
  clikae init claude a
  _seed_memory a MEMORY.md "a's brain"
  clikae memory share me claude a
  clikae init claude c                                       # never shared
  local mc; mc="$(_memdir c)"
  [ ! -L "$mc" ]                                             # c is NOT linked into souls/
  # c has no window into the shared store at all.
  [ ! -e "$mc/MEMORY.md" ] || [ "$(cat "$mc/MEMORY.md" 2>/dev/null)" != "a's brain" ]
}

@test "🔴 account isolation: crossing accounts non-interactively is refused without --yes" {
  clikae init claude a; _set_account a one@example.com
  clikae init claude b; _set_account b two@example.com
  _seed_memory a MEMORY.md "one's brain"
  clikae memory share me claude a
  run clikae memory share me claude b                        # different account, no tty, no --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"cross accounts"* ]] || false
  local mb; mb="$(_memdir b)"
  [ ! -L "$mb" ]                                             # b did NOT join
}

@test "account isolation: crossing your OWN accounts is allowed WITH --yes" {
  clikae init claude a; _set_account a one@example.com
  clikae init claude b; _set_account b two@example.com
  _seed_memory a MEMORY.md "one's brain"
  clikae memory share me claude a
  run clikae memory share me claude b --yes
  [ "$status" -eq 0 ]
  local ma mb
  ma="$(_memdir a)"; mb="$(_memdir b)"
  [ "$(readlink "$ma")" = "$(readlink "$mb")" ]              # explicitly commingled
}

@test "memory status: reports shared vs isolated tanks for this directory" {
  clikae init claude a
  clikae init claude b
  _seed_memory a MEMORY.md "x"
  clikae memory share me claude a
  run clikae memory status
  [ "$status" -eq 0 ]
  [[ "$output" == *"a"* ]] || false
  [[ "$output" == *"shared 'me'"* ]] || false
  [[ "$output" == *"isolated"* ]] || false                   # b is isolated
}

@test "memory share: idempotent — re-sharing the same group is a clean no-op" {
  clikae init claude a
  _seed_memory a MEMORY.md "x"
  clikae memory share me claude a
  run clikae memory share me claude a
  [ "$status" -eq 0 ]
  [[ "$output" == *"already shares"* ]] || false
}

@test "memory share: rejected for an engine with no known memory layout" {
  clikae init gh work                                         # gh has an adapter, no memory hook
  run clikae memory share me gh work
  [ "$status" -ne 0 ]
  [[ "$output" == *"no known memory layout"* ]] || false
}

@test "memory (agy): the target resolves but a missing tank errors cleanly" {
  run clikae memory share me agy nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such tank"* ]] || false
}

# ── cross-engine: codex points at the SAME markdown Soul via a pointer note ──

@test "memory share (codex): writes a Soul pointer into the tank's AGENTS.md" {
  clikae init codex H
  run clikae memory share me codex H
  [ "$status" -eq 0 ]
  local agents store
  agents="$CLIKAE_HOME/profiles/codex/H/AGENTS.md"
  store="$CLIKAE_HOME/souls/me/memory"
  [ -f "$agents" ]                                            # pointer note written there
  run cat "$agents"
  [[ "$output" == *"clikae soul:me"* ]] || false             # fenced sentinel
  [[ "$output" == *"$store"* ]] || false                      # points at the canonical store
  [[ "$output" == *"MEMORY.md"* ]] || false
}

@test "memory share (codex): shares the SAME store claude seeded — one brain, two engines" {
  clikae init claude a
  _seed_memory a MEMORY.md "the one brain"
  clikae memory share me claude a                             # seeds souls/me/memory
  clikae init codex H
  clikae memory share me codex H                              # codex points at it
  local store
  store="$CLIKAE_HOME/souls/me/memory"
  [ -f "$store/MEMORY.md" ]                                   # claude's seed is the canonical
  grep -q "$store" "$CLIKAE_HOME/profiles/codex/H/AGENTS.md"  # codex points at THAT
}

@test "memory isolate (codex): removes only the pointer note, leaves other content" {
  clikae init codex H
  local agents; agents="$CLIKAE_HOME/profiles/codex/H/AGENTS.md"
  mkdir -p "$(dirname "$agents")"
  printf '# my own codex notes\nkeep me\n' > "$agents"        # pre-existing instructions
  clikae memory share me codex H
  run cat "$agents"; [[ "$output" == *"clikae soul:me"* ]] || false
  run clikae memory isolate codex H
  [ "$status" -eq 0 ]
  run cat "$agents"
  [[ "$output" != *"clikae soul:me"* ]] || false             # our block gone
  [[ "$output" == *"keep me"* ]] || false                     # the user's own note survives
}

@test "memory share (codex): idempotent — re-sharing doesn't stack duplicate notes" {
  clikae init codex H
  clikae memory share me codex H
  clikae memory share me codex H
  local agents n; agents="$CLIKAE_HOME/profiles/codex/H/AGENTS.md"
  n="$(grep -c 'clikae soul:me' "$agents")"
  [ "$n" -eq 2 ]                                              # exactly one block = open + close marker
}

@test "memory status (codex): reports the pointer share" {
  clikae init codex H
  clikae memory share me codex H
  run clikae memory status codex H
  [ "$status" -eq 0 ]
  [[ "$output" == *"shared 'me'"* ]] || false
}

# ── cross-engine: agy (a launch-only target) points via ~/.gemini/GEMINI.md ──
# agy tanks are made by hand here (mkdir) to avoid init's ~/.gemini takeover prompt.

@test "memory share (agy): writes a Soul pointer into the tank's GEMINI.md" {
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/work"
  run clikae memory share me agy work
  [ "$status" -eq 0 ]
  local gemini store
  gemini="$CLIKAE_HOME/profiles/antigravity/work/GEMINI.md"
  store="$CLIKAE_HOME/souls/me/memory"
  [ -f "$gemini" ]                                            # pointer in agy's global rules
  run cat "$gemini"
  [[ "$output" == *"clikae soul:me"* ]] || false
  [[ "$output" == *"$store"* ]] || false
}

@test "memory share (agy): joins the SAME store as claude & codex — one brain, three engines" {
  clikae init claude a
  _seed_memory a MEMORY.md "the one brain"
  clikae memory share me claude a                             # seeds souls/me/memory
  clikae init codex H;            clikae memory share me codex H
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/work"; clikae memory share me agy work
  local store
  store="$CLIKAE_HOME/souls/me/memory"
  grep -q "$store" "$CLIKAE_HOME/profiles/codex/H/AGENTS.md"
  grep -q "$store" "$CLIKAE_HOME/profiles/antigravity/work/GEMINI.md"
  [ -f "$store/MEMORY.md" ]
}

@test "memory isolate (agy): removes only the pointer, leaves the user's own rules" {
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/work"
  local gemini; gemini="$CLIKAE_HOME/profiles/antigravity/work/GEMINI.md"
  printf '# my own agy rules\nalways be terse\n' > "$gemini"
  clikae memory share me agy work
  run clikae memory isolate agy work
  [ "$status" -eq 0 ]
  run cat "$gemini"
  [[ "$output" != *"clikae soul:me"* ]] || false             # our block gone
  [[ "$output" == *"always be terse"* ]] || false             # the user's rules survive
}

@test "memory status (agy): reports the pointer share" {
  mkdir -p "$CLIKAE_HOME/profiles/antigravity/work"
  clikae memory share me agy work
  run clikae memory status agy work
  [ "$status" -eq 0 ]
  [[ "$output" == *"shared 'me'"* ]] || false
}

# ── solo: a tank walled off from the fleet can't be shared ─────────────────────
# The cross-account guard can't protect two tanks on the SAME account but with
# different purposes (e.g. a bot/persona tank). `clikae solo` walls it off.

@test "🔴 memory share: a SOLO tank is refused (same-account persona guard)" {
  clikae init claude main
  clikae init claude persona
  clikae solo claude persona "bot persona — keep separate"
  run clikae memory share me claude persona            # same account as main — guard wouldn't catch it
  [ "$status" -ne 0 ]
  [[ "$output" == *"SOLO"* ]] || false
  [[ "$output" == *"bot persona"* ]] || false          # the reason is shown
  local mem; mem="$(_memdir persona)"
  [ ! -L "$mem" ]                                       # it did NOT get shared
}

@test "solo --off: lets the tank be shared again" {
  clikae init claude persona
  clikae solo claude persona
  run clikae memory share me claude persona
  [ "$status" -ne 0 ]                                   # solo → refused
  clikae solo claude persona --off
  run clikae memory share me claude persona
  [ "$status" -eq 0 ]                                   # back in the fleet → allowed
}

@test "memory status: shows a solo tank" {
  clikae init claude persona
  clikae solo claude persona
  run clikae memory status claude persona
  [ "$status" -eq 0 ]
  [[ "$output" == *"solo"* ]] || false
}

# ── tank-level sharing: one consent covers every directory ──────────────────
# (docs/memory.md: membership is the SSOT; per-directory symlinks are just
# projections of it, kept in line eagerly by `share` and lazily at launch.)

# A stub `claude` that writes one fact into its memory dir for $PWD.
_stub_claude() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
slug="$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug/memory" 2>/dev/null || true
echo "FROM-STUB" > "$CLAUDE_CONFIG_DIR/projects/$slug/memory/stub-fact.md" 2>/dev/null || true
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
}

@test "memory share: fans in every existing project directory, not just \$PWD" {
  clikae init claude a
  _seed_memory a MEMORY.md "the brain"
  # A second project directory's slot, accumulated earlier.
  local other="$CLIKAE_HOME/profiles/claude/a/projects/-somewhere-else/memory"
  mkdir -p "$other"; echo "old own fact" > "$other/fact.md"
  run clikae memory share me claude a
  [ "$status" -eq 0 ]
  local store="$CLIKAE_HOME/souls/me/memory"
  [ -L "$other" ]                                      # other slot linked too
  [ "$(readlink "$other")" = "$store" ]
  [ -f "$other.clikae-soul-stash/fact.md" ]            # its own memory stashed, not lost
}

@test "launch links a member tank's slot in a NEW directory (soul_prelaunch)" {
  _stub_claude
  clikae init claude a
  clikae memory share me claude a
  local store="$CLIKAE_HOME/souls/me/memory"
  mkdir -p "$BATS_TEST_TMPDIR/projB"; cd "$BATS_TEST_TMPDIR/projB"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude a
  [ "$status" -eq 0 ]
  local mem; mem="$(_memdir a)"
  [ -L "$mem" ]                                        # new dir fanned in at launch
  [ "$(readlink "$mem")" = "$store" ]
  [ -f "$store/stub-fact.md" ]                         # the session wrote INTO the Soul
}

@test "launch does NOT link a non-member tank (isolated stays isolated)" {
  _stub_claude
  clikae init claude loner
  mkdir -p "$BATS_TEST_TMPDIR/projC"; cd "$BATS_TEST_TMPDIR/projC"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude loner
  [ "$status" -eq 0 ]
  local mem; mem="$(_memdir loner)"
  [ ! -L "$mem" ]                                      # own slot, no Soul link
}

@test "--ephemeral on a shared tank restores the Soul link afterwards" {
  _stub_claude
  clikae init claude a
  clikae memory share me claude a
  local store="$CLIKAE_HOME/souls/me/memory"
  local mem; mem="$(_memdir a)"
  [ -L "$mem" ]                                        # shared before
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run clikae claude a --ephemeral
  [ "$status" -eq 0 ]
  [ -L "$mem" ]                                        # STILL shared after (was silently dropped)
  [ "$(readlink "$mem")" = "$store" ]
  [ ! -f "$store/stub-fact.md" ]                       # the throwaway session did not leak in
}

@test "memory isolate: unlinks EVERY project directory and restores each stash" {
  clikae init claude a
  _seed_memory a MEMORY.md "the brain"
  local other="$CLIKAE_HOME/profiles/claude/a/projects/-somewhere-else/memory"
  mkdir -p "$other"; echo "old own fact" > "$other/fact.md"
  clikae memory share me claude a
  [ -L "$other" ]
  run clikae memory isolate claude a
  [ "$status" -eq 0 ]
  [ ! -L "$other" ]                                    # other slot unlinked too
  [ -f "$other/fact.md" ]                              # its stash restored
  local mem; mem="$(_memdir a)"
  [ ! -L "$mem" ]
  [ -f "$mem/MEMORY.md" ]                              # $PWD slot restored as well
}

@test "rename carries Soul membership (no ghost member left behind)" {
  clikae init claude a
  clikae memory share me claude a
  run clikae rename claude a fresh --force
  [ "$status" -eq 0 ]
  run cat "$CLIKAE_HOME/souls/me/members"
  [[ "$output" == *"claude/fresh"* ]] || false
  [[ "$output" != *"claude/a"$'\t'* ]] || false        # old key gone
  run clikae memory status claude fresh
  [[ "$output" == *"shared 'me'"* ]] || false
}

@test "memory status: reports tank-level sharing from an unlinked directory" {
  clikae init claude a
  clikae memory share me claude a
  mkdir -p "$BATS_TEST_TMPDIR/projD"; cd "$BATS_TEST_TMPDIR/projD"
  run clikae memory status
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude/a  → shared 'me'"* ]] || false
  [[ "$output" == *"links on next launch"* ]] || false # per-dir slot not yet projected
}

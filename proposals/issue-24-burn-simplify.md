# Proposal — Issue #24: simplify `clikae burn` (drop the per-engine flag wrangling)

> Status: ✅ **SHIPPED in v0.6.0** (the full design — `--prompt` / `--prompt-file` /
> `--add-dir` + the per-engine `adapter_burn_flags` hook). This file is now an
> **archived reference** for the rationale; the live behaviour is authoritative.
> What actually shipped:
>
> - Convenience surface: `clikae burn <engine> <tank> --artifact <path>
>   (--prompt-file <f> | --prompt <str>)` with `--add-dir` defaulting to the
>   artifact's parent (`lib/commands/burn.sh`, `cmd_burn` / `_burn_compose`).
> - Per-engine write hook `adapter_burn_flags` on claude + codex (NUL-separated
>   argv, so a multi-line prompt survives as one item), stubbed in `_template.sh`,
>   added to the adapter-loader leak-guard.
> - Cross-engine `--to` reroute regenerates the flags for the new engine (the
>   soundness fix in §2/§3c).
> - Docs: `docs/grammar.md` §3.3 documents both the easy and power-user forms;
>   tests in `tests/bats/burn.bats` (incl. the direct `adapter_burn_flags` unit
>   tests and the cross-engine-regenerate case).
>
> The raw `-- <cmd…>` power-user form is unchanged (fully additive, as designed).
>
> _Original draft preserved verbatim below._

---

Status: draft / design
Author: design note (for review)
Touches: `lib/commands/burn.sh`, `lib/adapters/*.sh`, `lib/core/adapter_loader.sh`, `tests/bats/burn.bats`, `docs/grammar.md`, `docs/usage.md`
Backward compatible: yes (additive — the current `-- <cmd…>` form keeps working unchanged)

---

## 1. Problem statement

`clikae burn` already nails its core bet (artifact verification + dry-reroute + cross-account offload). The remaining friction, surfaced directly in the dogfood writeup (`docs/dogfood-burn-tugtile.md` §摩擦 1), is that **the caller must hand-assemble each engine's headless invocation by hand**:

```bash
# claude — must remember -p + the skip-permissions flag + --add-dir
clikae burn claude L --to C --artifact out/core.test.cjs \
  -- -p "$(cat out/promptA.txt)" --dangerously-skip-permissions --add-dir /…/tugtile

# codex — a completely different flag shape
clikae burn codex M --artifact /tmp/out.md \
  -- exec -C /tmp -s workspace-write "read /tmp/in.txt, write /tmp/out.md"
```

To burn *anything* the first time you have to go read `claude --help` / `codex --help`, get the headless flags right, and quote a multi-line prompt inside `--`. Get it wrong and you fire a **空包彈** — the engine runs, exits 0, and writes nothing, which is exactly the failure mode burn was built to detect but which the user just hand-wrote into existence.

The task burn is built for is almost always the same shape: *"here is a prompt, here is the file it should produce, run it headless with write access to this directory."* That intent should not require the user to know each CLI's flag dialect.

## 2. Current pain points

| Pain | Where it bites |
|------|----------------|
| Per-engine headless flags are inconsistent | claude: `-p … --dangerously-skip-permissions --add-dir <dir>`; codex: `exec -C <dir> -s workspace-write "<prompt>"`. No shared mental model. |
| Prompt goes inside `--`, so it's quoting hell | The dogfood worked around it with `-p "$(cat out/promptA.txt)"`. The prompt is the *content* of the task, yet it's tangled with engine plumbing. |
| Knowledge lives in the user's head, not the tool | clikae already owns an adapter per engine — it *knows* what "claude" is — but burn makes the human re-supply that knowledge every call. |
| Cross-engine `--to` reroute is unsound by construction | Today the SAME literal argv runs under the next engine. claude's `-p …` flags are nonsense to codex, so a cross-engine dry-reroute of a hand-written command silently misfires. A per-engine flag hook also *fixes* this. |
| New engines can't participate | Any future adapter (agy excepted, see §6) would need the user to learn yet another flag dialect. |

## 3. Design

Add a high-level "write a file from a prompt" path to burn, and push the per-engine flag knowledge into the adapters where it belongs.

### 3a. New burn options (the convenience surface)

```
clikae burn <engine> <tank> --artifact <path> --prompt-file <f> [--add-dir <dir>] [existing flags…]
clikae burn <engine> <tank> --artifact <path> --prompt      <str> [--add-dir <dir>] [existing flags…]
```

- `--prompt-file <f>` — read the task prompt from a file (no quoting hell; pairs naturally with the dogfood's own `out/promptA.txt` habit).
- `--prompt <str>` — inline prompt, for one-liners.
- `--add-dir <dir>` — the directory the engine may write in. Defaults to the artifact's parent directory (so the engine can always at least write the artifact you asked for). Repeatable.
- When `--prompt`/`--prompt-file` is used, **`--` is optional**; if both are present, the post-`--` argv is appended verbatim *after* the engine's generated flags (escape hatch for extra per-engine args).

So the dogfood command collapses to:

```bash
clikae burn claude L --to C --artifact out/core.test.cjs \
  --prompt-file out/promptA.txt --add-dir /…/tugtile
```

…and the very same intent works on codex with **zero flag changes**:

```bash
clikae burn codex M --artifact /tmp/out.md --prompt-file task.txt --add-dir /tmp
```

### 3b. The per-engine write hook: `adapter_burn_flags`

Each adapter self-reports how to run itself headless-with-write. New **optional** adapter hook:

```sh
# adapter_burn_flags <prompt> <add-dirs…>
#   Print, one argv item per line, the full engine argv (AFTER the binary) that
#   runs <prompt> HEADLESS with permission to WRITE in each <add-dir>. The prompt
#   is passed as data, never re-quoted by the caller. Return non-zero (print
#   nothing) if this engine has no headless-write mode (→ burn errors clearly).
```

Newline-per-item is the same convention already used by `adapter_resume_args` / `adapter_flag_args`, so `mapfile`/`while read` assembly is consistent across the codebase and prompts containing spaces survive intact.

claude:

```sh
adapter_burn_flags() {
  local prompt="$1"; shift
  printf -- '-p\n%s\n--dangerously-skip-permissions\n' "$prompt"
  local d; for d in "$@"; do printf -- '--add-dir\n%s\n' "$d"; done
}
```

codex:

```sh
adapter_burn_flags() {
  local prompt="$1"; shift
  printf 'exec\n'
  local d; for d in "$@"; do printf -- '-C\n%s\n' "$d"; done   # codex -C = working dir
  printf -- '-s\nworkspace-write\n%s\n' "$prompt"
}
```

`_template.sh` gets a documented stub so adapter authors know the contract.

### 3c. How burn uses it

When `--prompt`/`--prompt-file` is supplied, burn builds `cmd` from the hook instead of (or before) the post-`--` argv:

```sh
if [ -n "$prompt_src" ]; then
  declare -F adapter_burn_flags >/dev/null \
    || log_fail "$cli has no headless-write recipe (adapter defines no adapter_burn_flags). Use the explicit '-- <cmd…>' form."
  local -a gen=()
  while IFS= read -r line; do gen+=("$line"); done < <(adapter_burn_flags "$prompt" "${add_dirs[@]}")
  cmd=("${gen[@]}" "${cmd[@]}")   # generated flags first, any post-`--` argv appended verbatim
fi
```

Crucially this lives **inside** the reroute `while` loop's engine-resolution step (or is recomputed when `cli` changes on a cross-engine `--to`), so a cross-engine reroute regenerates the flags for the *new* engine — fixing pain point §2 (cross-engine reroute no longer ships claude flags to codex).

## 4. API sketch

```
clikae burn <engine> <tank> --artifact <path>
            ( --prompt-file <f> | --prompt <str> | -- <engine cmd…> )
            [--add-dir <dir>]…        # default: dirname(<artifact>); repeatable
            [--to <target>] [--timeout <s>] [--no-reroute]
            [--allow-active] [--fresh]
```

Resolution rules:
- `--prompt-file` and `--prompt` are mutually exclusive (error if both).
- If neither prompt option nor `--` is given → error (today's "missing command" error, reworded to mention the prompt options).
- If a prompt option **and** `--` are both given → generated flags first, `--` argv appended (advanced escape hatch).
- `--add-dir` with no value defaults to `dirname(--artifact)`.

Adapter contract:

```
adapter_burn_flags <prompt> [add-dir…]   # optional hook; newline-per-argv; non-zero ⇒ no headless-write mode
```

## 5. Backward compatibility

- **Fully additive.** Every existing `clikae burn … -- <cmd…>` call is untouched: when no `--prompt`/`--prompt-file` is present, burn behaves exactly as today and `adapter_burn_flags` is never called.
- Adapters without the new hook keep working with the explicit `--` form; only the *convenience* path requires the hook, and its absence yields a clear, actionable error pointing back at `-- <cmd…>`.
- No grammar/verb change (`docs/grammar.md` §"we do not invent cute verbs" stays satisfied — this adds options, not a command).
- The hook name `adapter_burn_flags` is added to the unset-list in `lib/core/adapter_loader.sh` (lines ~164-170) so it can't leak across adapters loaded in one process (same discipline as the other optional hooks).

## 6. agy note

agy stays rejected by burn (global single-account — `lib/commands/burn.sh` already errors early, and `docs/dogfood-burn-tugtile.md` 追記 explains why). It simply won't define `adapter_burn_flags`. The separate "let burn drive agy via serialize-and-restore" idea from that 追記 is **out of scope** for #24 and tracked elsewhere.

## 7. Implementation sketch (files / functions)

1. **`lib/commands/burn.sh`**
   - `cmd_burn()` arg loop: add `--prompt`, `--prompt-file`, `--add-dir` cases; locals `prompt=""`, `prompt_src=""`, `add_dirs=()`.
   - After parsing: resolve `--prompt-file` → read into `prompt` (`log_fail` if unreadable); enforce mutual exclusion; default `add_dirs` to `dirname "$artifact"` when empty.
   - Relax the `${#cmd[@]} -ge 1` guard: require *either* a prompt source *or* a post-`--` cmd.
   - Inside the reroute loop, after the adapter is (re)loaded for the current `cli`, build `cmd` from `adapter_burn_flags` when `prompt_src` is set — so cross-engine `--to` regenerates correctly.
   - `_burn_help()`: document the three forms + `--add-dir`, with the dogfood one-liner as the headline example.

2. **`lib/adapters/claude.sh`** — add `adapter_burn_flags` (§3b).
3. **`lib/adapters/codex.sh`** — add `adapter_burn_flags` (§3b).
4. **`lib/adapters/_template.sh`** — add the documented optional stub.
5. **`lib/core/adapter_loader.sh`** — add `adapter_burn_flags` to the `unset -f` leak-guard list (~L167).
6. **`docs/grammar.md` + `docs/usage.md`** — show the `--prompt-file`/`--add-dir` form as the recommended way to burn a write-task; keep `-- <cmd…>` documented as the power-user escape hatch.

## 8. Tests (bats)

Extend `tests/bats/burn.bats` (stubbed `codex`, no real engine — same pattern as today). The existing stub keys behaviour off argv; extend it to honour the generated `exec … -C … -s workspace-write <prompt>` shape (write the artifact when it sees the generated form).

New cases:

1. **`--prompt-file` builds the engine command via the hook and completes.** burn a write-task with `--prompt-file`, assert artifact appears + "Done on codex/…", and that the user never typed any codex flags.
2. **`--prompt` inline equivalent** produces the same outcome.
3. **`--add-dir` defaults to the artifact's parent** when omitted (assert the generated argv carries `-C <dirname(artifact)>` — capture via a stub that echoes its argv to a side file).
4. **Mutually-exclusive prompt options error** (`--prompt` + `--prompt-file` together → non-zero, message names both).
5. **No prompt and no `--` errors** with a message mentioning the prompt options.
6. **Missing `adapter_burn_flags` → clear error.** Drive a synthetic adapter with no hook via `--prompt`; assert it fails pointing at the `-- <cmd…>` form (unit-level: source burn.sh, stub `declare -F` path, or use a throwaway adapter fixture).
7. **Cross-engine `--to` regenerates flags for the new engine** (the soundness fix): start on a stub engine A whose tank is dry, `--to` a stub engine B, assert B is invoked with B's generated flags, not A's. (Two stub binaries on PATH, each recording its argv.)
8. **Direct `adapter_burn_flags` unit tests** — source `lib/adapters/claude.sh` and `codex.sh`, call the hook, assert the exact newline-per-argv output (so the flag recipe is pinned and a CLI flag rename is caught here, not in the field). Mirrors the existing `_burn_timeout_bin` / `_burn_next_same_engine` direct-unit style.

Regression: keep all current `-- <cmd…>` tests green — they prove the additive path didn't disturb the legacy form.

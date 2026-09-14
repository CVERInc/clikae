#!/usr/bin/env python3
"""tests/fixtures/cockpit-guard/gen_specimen.py — generates the NON-UNIFORM
large-payload specimens for tests/bats/cockpit-guard.bats (#63 P1-1 fix2,
REVIEW-cockpit63-r2.md).

The round-1 fixtures this replaces were a single repeated ASCII byte
(`big="x"`) -- structurally blind to the bug the round-2 review found (a
multi-byte UTF-8 character, or a JS-escaped `\n`, straddling the byte offset
that used to be a hard `head -c 8192` cut). Everything here is genuine zh+en
prose (mixed Chinese/English, like this fleet's own lane briefs) or a
deliberately positioned two-character JSON escape -- never a uniform repeat.

Every payload emitted here is written to stdout as-is (already valid JSON
text); nothing needs shell-escaping on the way out other than a plain
`> file`.
"""
import sys

# A real-shaped zh+en sentence (short, mixed-width characters: CJK ideographs
# are 3 UTF-8 bytes, ASCII letters/punctuation are 1) -- repeating THIS,
# unlike repeating a single byte, walks the straddle point through every
# possible alignment as it tiles, which is exactly why a small shift search
# below reliably finds a mid-character cut.
UNIT = "這是一段用來測試切點的中文文字與 English mixed text，確保 8192 這個位置準確。"

PREFIX_TMPL = '{"tool_name":"Agent","tool_input":{"description":"d","prompt":"%s'
SUFFIX = '","model":"sonnet"}}'


def _tile(min_bytes):
    s = ""
    while len(s.encode("utf-8")) < min_bytes:
        s += UNIT
    return s


def straddle_cjk():
    """A prompt whose UTF-8 bytes straddle byte offset 8192 of the PAYLOAD
    mid multi-byte character -- #63 P1-1's primary repro (round-2 review:
    46/109 sliding-cut-point trials on real zh+en text)."""
    lead = "worktree please: "
    prefix = PREFIX_TMPL % lead
    prefix_bytes = len(prefix.encode("utf-8"))
    body = _tile(20000)
    target = 8192
    for shift in range(0, 200):
        padded = ("z" * shift) + body
        b = padded.encode("utf-8")
        idx = target - prefix_bytes
        if 0 <= idx < len(b) and 0x80 <= b[idx] <= 0xBF:
            payload = prefix + padded + SUFFIX
            pb = payload.encode("utf-8")
            assert 0x80 <= pb[target] <= 0xBF, "self-check: not a continuation byte"
            sys.stdout.write(payload)
            return
    print("FAILED: could not construct a straddling CJK specimen", file=sys.stderr)
    sys.exit(1)


def straddle_escape():
    """A prompt containing a literal newline, JSON-escaped (JS-faithful --
    JSON.stringify emits a real newline as the two ASCII bytes `\\`+`n`) so
    the backslash lands exactly on byte 8191 -- the OLD `head -c 8192` cut
    used to include the backslash but exclude the `n`, same silent failure
    as the multi-byte case, on pure ASCII (round-2 review: 4/109 trials)."""
    lead = "worktree please: "
    prefix = PREFIX_TMPL % lead
    prefix_bytes = len(prefix.encode("utf-8"))
    target = 8191
    fill_len = target - prefix_bytes
    if fill_len < 0:
        print("FAILED: prefix already past target", file=sys.stderr)
        sys.exit(1)
    fill = ("run the full test suite then git commit and git push. " * 400)[:fill_len]
    body = fill + "\\n" + "more prompt text after the newline, still on this side of the boundary."
    payload = prefix + body + SUFFIX
    b = payload.encode("utf-8")
    if b[target] != 0x5C:
        print("FAILED: byte at target is not a backslash", file=sys.stderr)
        sys.exit(1)
    sys.stdout.write(payload)


def brief(seed):
    """One of the 100-item corpus: a genuine zh+en brief over 8 KiB, shifted
    by `seed` characters of ASCII padding so each of the 100 lands its
    straddle point (if any) somewhere different -- the sliding-cut-point
    idea from the round-2 review's own 109-trial sweep, turned into a fixed
    regression corpus instead of a one-off manual sweep.

    #63 P3-3 (round-3 review): this used to skip the self-check straddle_cjk()
    has -- only 50/100 seeds actually landed byte[8192] on a continuation
    byte, so the OTHER 50 tested nothing but the (separate) length tripwire.
    Now it searches, like straddle_cjk(), until the straddle lands, then
    asserts it: 100/100 exercise the actual multi-byte-cut bug, not 50/100."""
    lead = "Please act as REVIEWER: set up a worktree, run the full test suite, then git commit and git push. "
    base_pad = seed % 97
    body_tile = _tile(9000 + (seed * 37) % 4000)
    target = 8192
    for extra in range(0, 200):
        body = ("z" * (base_pad + extra)) + body_tile
        payload = (PREFIX_TMPL % lead) + body + SUFFIX
        pb = payload.encode("utf-8")
        if target < len(pb) and 0x80 <= pb[target] <= 0xBF:
            assert 0x80 <= pb[target] <= 0xBF, "self-check: not a continuation byte"
            sys.stdout.write(payload)
            return
    print("FAILED: could not construct a straddling brief for seed %d" % seed, file=sys.stderr)
    sys.exit(1)


def long_plain(seed=0):
    """A prompt over 8,192 CHARACTERS with NO heuristic keyword anywhere --
    isolates the length tripwire from the keyword heuristic. English-only,
    so char count and byte count agree, keeping the corpus's intent legible
    (this one is about the LENGTH path specifically, not multi-byte cutting)."""
    unit = "the quick brown fox jumps over the lazy dog and keeps walking past the old mill without stopping to look back even once, %d. " % seed
    s = ""
    while len(s) < 9000:
        s += unit
    payload = (PREFIX_TMPL % "") + s + SUFFIX
    sys.stdout.write(payload)


def bulk(min_bytes):
    """A plain non-uniform zh+en payload of at least `min_bytes` -- for
    TIMING specimens (the 200 kB / 1 MB re-measurement, #63 P1-1 fix2's
    "bounded only by the payload size" extraction), not a specific straddle
    point. Refuse-shaped (both a heuristic phrase and well over the length
    tripwire) so the timed run always takes the more expensive refuse path."""
    lead = "worktree please: "
    body = _tile(min_bytes)
    payload = (PREFIX_TMPL % lead) + body + SUFFIX
    sys.stdout.write(payload)


def model_before_prompt(model):
    """tool_input key order model BEFORE prompt (the shape the round-2
    review's P2-1 finding turned up: real captures have prompt before model,
    but nothing guarantees that order) -- a refuse-shaped prompt over 8 KiB
    either way, so the SAME payload probes both P1-1 (length) and P2-1
    (model position) at once for whichever model the caller passes."""
    body = _tile(9000)
    payload = (
        '{"tool_name":"Agent","tool_input":{"description":"d","model":"%s","prompt":"worktree please: %s"}}'
        % (model, body)
    )
    sys.stdout.write(payload)


MODES = {
    "straddle-cjk": lambda args: straddle_cjk(),
    "straddle-escape": lambda args: straddle_escape(),
    "brief": lambda args: brief(int(args[0])),
    "long-plain": lambda args: long_plain(int(args[0]) if args else 0),
    "model-before-prompt": lambda args: model_before_prompt(args[0]),
    "bulk": lambda args: bulk(int(args[0])),
}

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    fn = MODES.get(mode)
    if not fn:
        print("usage: gen_specimen.py <%s> [args...]" % "|".join(MODES), file=sys.stderr)
        sys.exit(2)
    fn(sys.argv[2:])

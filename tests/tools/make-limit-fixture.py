#!/usr/bin/env python3
"""Build tests/fixtures/limit-reset-phrases.tsv from real transcripts.

De-identification rule (de-identify-the-label-not-the-measurement): identifiers
are droppable, MEASUREMENTS are not. We keep only two measured things per row —
the instant the limit fired, and the vendor's reset phrase verbatim. Session
ids, file paths, project names, message bodies never leave the scanner.

The expected epoch is computed HERE, with python's zoneinfo — deliberately a
different implementation from the bash function under test, so the fixture is
an independent answer key rather than the bash code grading its own homework.
"""
import json, os, re, glob, sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

ROOT = os.path.expanduser("~/.clikae/profiles/claude")
OUT = os.path.expanduser("~/Developer/clikae/tests/fixtures/limit-reset-phrases.tsv")
MONTHS = {m: i + 1 for i, m in enumerate(
    "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}

RE_DATED = re.compile(
    r"resets\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?(am|pm)\s+\(([^)]+)\)", re.I)
RE_PLAIN = re.compile(
    r"resets\s+(\d{1,2})(?::(\d{2}))?(am|pm)\s+\(([^)]+)\)", re.I)
RE_PHRASE = re.compile(r"[Rr]esets [^\"\\]*")


def to24(h, ampm):
    h = int(h) % 12
    return h + 12 if ampm.lower() == "pm" else h


def expected(phrase, now_utc):
    m = RE_DATED.search(phrase)
    if m:
        mon, day, h, mi, ampm, tzn = m.groups()
        tz = ZoneInfo(tzn); local = now_utc.astimezone(tz)
        hh, mm = to24(h, ampm), int(mi or 0)
        for yr in (local.year, local.year + 1, local.year - 1):
            try:
                c = datetime(yr, MONTHS[mon.title()], int(day), hh, mm, tzinfo=tz)
            except ValueError:
                continue
            if c >= local - timedelta(days=1):
                return c
        return None
    m = RE_PLAIN.search(phrase)
    if m:
        h, mi, ampm, tzn = m.groups()
        tz = ZoneInfo(tzn); local = now_utc.astimezone(tz)
        c = local.replace(hour=to24(h, ampm), minute=int(mi or 0),
                          second=0, microsecond=0)
        if c <= local:
            c += timedelta(days=1)
        return c
    return None


rows, seen, total, nophrase = [], set(), 0, 0
for prof in sorted(os.listdir(ROOT)):
    pdir = os.path.join(ROOT, prof, "projects")
    if not os.path.isdir(pdir):
        continue
    for f in glob.glob(os.path.join(pdir, "**", "*.jsonl"), recursive=True):
        try:
            fh = open(f, errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"isApiErrorMessage"' not in line or '"<synthetic>"' not in line:
                    continue
                if not re.search(r"hit your [a-z]+ limit", line, re.I):
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                t = o.get("timestamp")
                if not t:
                    continue
                body = json.dumps(o.get("message", ""))
                pm = RE_PHRASE.search(body)
                total += 1
                if not pm:
                    nophrase += 1
                    continue
                phrase = pm.group(0).rstrip()
                now = datetime.fromisoformat(t.replace("Z", "+00:00"))
                key = (int(now.timestamp()), phrase)
                if key in seen:
                    continue
                seen.add(key)
                exp = expected(phrase, now)
                if exp is None:
                    print(f"UNPARSED: {phrase!r}", file=sys.stderr)
                    continue
                rows.append((int(now.timestamp()), phrase, int(exp.timestamp())))

rows.sort()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    fh.write("# limit-reset-phrases.tsv — real Claude usage-limit reset phrases.\n")
    fh.write("#\n")
    fh.write("# Harvested from real transcripts on 2026-08-12: every genuine limit event\n")
    fh.write(f"# (synthetic + isApiErrorMessage) across five accounts — {total} of them, all\n")
    fh.write(f"# {total - nophrase} carrying a reset phrase, deduped to {len(rows)} distinct (now, phrase) pairs.\n")
    fh.write("#\n")
    fh.write("# Columns: now_epoch <TAB> phrase (verbatim) <TAB> expected_epoch\n")
    fh.write("#\n")
    fh.write("# The phrases and timestamps are MEASUREMENTS and are reproduced exactly;\n")
    fh.write("# nothing identifying (session ids, paths, message bodies) was carried over.\n")
    fh.write("# expected_epoch was computed with python's zoneinfo, NOT with the bash\n")
    fh.write("# function these rows exist to test — an answer key the implementation did\n")
    fh.write("# not write for itself.\n")
    fh.write("#\n")
    fh.write("# Two grammars appear, and which one you get is NOT predictable from the\n")
    fh.write("# limit type: a weekly limit uses both.\n")
    fh.write("#   resets 3:50am (Asia/Tokyo)             -> next occurrence, may cross midnight\n")
    fh.write("#   resets Jul 27 at 5am (Asia/Tokyo)      -> dated, no year\n")
    for n, p, e in rows:
        fh.write(f"{n}\t{p}\t{e}\n")

print(f"total limit events : {total}")
print(f"  with a phrase    : {total - nophrase}")
print(f"  distinct rows    : {len(rows)}")
print(f"wrote {OUT}")

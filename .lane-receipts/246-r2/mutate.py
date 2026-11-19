import sys
# usage: mutate.py <file> <id>
f, mid = sys.argv[1], sys.argv[2]
s = open(f).read()
M = {
 'M1': ('($entry.matcher | cockpit_runs_on_agent | not)', '($entry.matcher != "Agent")'),
 'M2': ('''any($words[]; cockpit_mention or (test("[ \\\\t'\\"]") and cockpit_text_mention))''', 'false'),
 'M3': ('''    elif $entry.matcher == "Agent" and $entry._clikae == "cockpit-guard"
       and (.command | test("^/[^\\\\n\\\\r;&|<>()`$]*/hooks/cockpit-guard\\\\.sh\\\\z"))
      then "owned"
''', ''),
 'M4': ('if ._clikae == "cockpit-guard" then del(._clikae) else . end', '.'),
 'M5': ('''gsub("/+"; "/") | gsub("/(\\\\./)+"; "/") | test("(^|/)hooks/cockpit-guard\\\\.sh\\\\z");''', 'test("cockpit-guard\\\\.sh");'),
 'M6': ('''      2) log_warn "cockpit: the guard clikae installed''', '''      2222) log_warn "cockpit: the guard clikae installed'''),
 'M7': ('''      2) rollback_msg=''', '''      2222) rollback_msg='''),
 'M8': ('''  if [ -L "$1" ] && [ ! -e "$1" ]; then return 1; fi\n''', ''),
 'M9': ('($words[0] | startswith("/") and cockpit_path)', '($words[0] | cockpit_path)'),
}
old, new = M[mid]
assert s.count(old) == 1, (mid, s.count(old))
open(f, 'w').write(s.replace(old, new))

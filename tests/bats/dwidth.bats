#!/usr/bin/env bats
# tests/bats/dwidth.bats — _dw_walk is what every drawn row is measured with, and
# it now answers pure-ASCII strings without walking them. That shortcut is only
# safe while it agrees with the walk for EVERY input and EVERY budget, so this
# file compares the two directly rather than asserting a handful of widths.

load '../helpers'

_boot() {
  source "$CLIKAE_TEST_ROOT/lib/core/log.sh"
  source "$CLIKAE_TEST_ROOT/lib/commands/home.sh"
}

# The pre-shortcut scanner, kept verbatim as the reference. Do not tidy it.
_dw_walk_reference() {
  local s="$1" max="$2"
  local i=0 n=${#s} v b2 b3 cp len cw w=0
  _DW_CUT=-1
  while [ "$i" -lt "$n" ]; do
    printf -v v '%d' "'${s:i:1}"
    [ "$v" -lt 0 ] && v=$(( v + 256 ))
    if [ "$v" -lt 128 ]; then len=1; cw=1
    elif [ "$v" -lt 224 ]; then len=2; cw=1
    elif [ "$v" -lt 240 ]; then
      len=3
      printf -v b2 '%d' "'${s:i+1:1}"; [ "$b2" -lt 0 ] && b2=$(( b2 + 256 ))
      printf -v b3 '%d' "'${s:i+2:1}"; [ "$b3" -lt 0 ] && b3=$(( b3 + 256 ))
      cp=$(( ((v - 224) << 12) | ((b2 - 128) << 6) | (b3 - 128) ))
      cw=1
      if   [ "$cp" -ge 4352 ]  && [ "$cp" -le 4447 ];  then cw=2
      elif [ "$cp" -ge 11904 ] && [ "$cp" -le 12350 ]; then cw=2
      elif [ "$cp" -ge 12353 ] && [ "$cp" -le 13311 ]; then cw=2
      elif [ "$cp" -ge 13312 ] && [ "$cp" -le 19903 ]; then cw=2
      elif [ "$cp" -ge 19968 ] && [ "$cp" -le 40959 ]; then cw=2
      elif [ "$cp" -ge 40960 ] && [ "$cp" -le 42191 ]; then cw=2
      elif [ "$cp" -ge 44032 ] && [ "$cp" -le 55203 ]; then cw=2
      elif [ "$cp" -ge 63744 ] && [ "$cp" -le 64255 ]; then cw=2
      elif [ "$cp" -ge 65040 ] && [ "$cp" -le 65049 ]; then cw=2
      elif [ "$cp" -ge 65072 ] && [ "$cp" -le 65135 ]; then cw=2
      elif [ "$cp" -ge 65280 ] && [ "$cp" -le 65376 ]; then cw=2
      elif [ "$cp" -ge 65504 ] && [ "$cp" -le 65510 ]; then cw=2
      fi
    else len=4; cw=2
    fi
    if [ "$max" -ge 0 ] && [ $(( w + cw )) -gt "$max" ]; then _DW_CUT=$i; break; fi
    w=$(( w + cw )); i=$(( i + len ))
  done
  _DW_W=$w
}

# Compare both scanners on one string across every budget from -1 to its width+2.
_agree_on() {
  local s="$1" label="$2"
  local LC_ALL=C
  local max fw fc rw rc bad=""
  for (( max = -1; max <= ${#s} + 2; max++ )); do
    _dw_walk "$s" "$max";           fw=$_DW_W; fc=$_DW_CUT
    _dw_walk_reference "$s" "$max"; rw=$_DW_W; rc=$_DW_CUT
    if [ "$fw" != "$rw" ] || [ "$fc" != "$rc" ]; then
      bad="$bad
  max=$max  fast=(w=$fw cut=$fc)  reference=(w=$rw cut=$rc)"
    fi
  done
  [ -z "$bad" ] || { echo "[$label] scanners disagree:$bad"; return 1; }
}

@test "_dw_walk: ASCII shortcut agrees with the full walk, at every budget" {
  _boot
  _agree_on "claude" ascii-word
  _agree_on "hi@tniop.tw" ascii-email
  _agree_on "7f66142c-b7b6-4931-ab95-4a9620dd83ff" ascii-uuid
  _agree_on "" empty
  _agree_on "x" single
  _agree_on "Fix the \"off-by-one\" bug in the parser" ascii-quotes
}

@test "_dw_walk: control bytes count the same on both paths" {
  _boot
  # The walk gives EVERY byte under 128 a width of 1 — tabs and escapes included.
  # The shortcut uses ${#s}, so it must agree on those too, or a row containing
  # one would be measured differently depending on which path it took.
  _agree_on "$(printf 'a\tb')" tab
  _agree_on "$(printf 'a\033[31mb')" ansi-escape
  _agree_on "$(printf 'a\rb')" carriage-return
}

@test "_dw_walk: non-ASCII still takes the full walk and is unchanged" {
  _boot
  _agree_on "看板" cjk
  _agree_on "クリカエ" katakana
  _agree_on "ｷﾘｶｴ" halfwidth-katakana
  _agree_on "한국어" hangul
  _agree_on "café" latin1-accent
  _agree_on "日本語ですよ" cjk-long
}

@test "_dw_walk: mixed ASCII and wide characters agree" {
  _boot
  # The dangerous shape for a byte-length shortcut: mostly ASCII with one wide
  # character, where ${#s} and the true column count differ by exactly one.
  _agree_on "tank 看板 row" mixed
  _agree_on "a看" ascii-then-cjk
  _agree_on "看a" cjk-then-ascii
  _agree_on "🔥 burn" emoji-lead
  _agree_on "burn 🔥" emoji-tail
  _agree_on "重構 refactor 完成" mixed-long
}

@test "_dwidth: a CJK string still measures two columns per character" {
  _boot
  # A guard on the shortcut's premise rather than on the two paths agreeing: if
  # the high-bit test ever went wrong in the "everything is ASCII" direction,
  # both scanners would still agree with each other — on the wrong answer.
  [ "$(_dwidth '看板')" = "4" ] || false
  [ "$(_dwidth 'abcd')" = "4" ] || false
  [ "$(_dwidth 'a看')" = "3" ] || false
}

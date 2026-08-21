#!/usr/bin/env bash
# Every verb a script dispatches must resolve to a function that exists.
#
# A verb is interface: it is what a SKILL.md, a sibling script, or a test is
# told it may call. Each script's own suite asserts only the verbs it happens to
# exercise, so a verb nothing exercises is indistinguishable from a working one.
# push.sh shipped `method)` dispatching to an undefined `cmd_method` under a
# 125-assertion suite for exactly that reason.
#
# ponytail: grep, not a bash parser. It reads the one dispatch shape every
# script in this repo actually uses; a script written some other way is reported
# as having no verbs rather than silently passing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# `  verb) shift; cmd_thing "$@" ;;` -> `verb cmd_thing`
verbs_of() {
  grep -oE '^[[:space:]]+[a-z][a-z0-9|_-]*\)[[:space:]]*(shift;)?[[:space:]]*cmd_[a-z0-9_]+' "$1" \
    | sed -E 's/^[[:space:]]*([a-z0-9|_-]+)\).*(cmd_[a-z0-9_]+)$/\1 \2/'
}

checked=0; skipped=""
while IFS= read -r f; do
  rel=${f#"$ROOT"/}
  # Scripts that dispatch straight into inline case bodies (tracking.sh) carry
  # no cmd_* to resolve. Named rather than dropped: a sweep that quietly covers
  # less than it claims is the failure this guard exists to prevent.
  if ! grep -q '^cmd_[a-z0-9_]*()' "$f"; then
    grep -qE '^[[:space:]]+[a-z][a-z0-9|_-]*\)' "$f" && skipped="$skipped $rel"
    continue
  fi
  n=0; bad_here=0
  while read -r verb fn; do
    [ -n "${fn:-}" ] || continue
    n=$((n+1))
    grep -q "^${fn}()" "$f" || {
      bad "$rel: verb '$verb' dispatches to $fn, which is not defined"
      bad_here=1
    }
  done < <(verbs_of "$f")
  if [ "$n" -eq 0 ]; then
    bad "$rel: defines cmd_* but no verb dispatches to any of them"
  elif [ "$bad_here" -eq 0 ]; then
    ok "$rel: $n verb(s) all resolve"
    checked=$((checked+1))
  fi
done < <(find "$ROOT/skills" "$ROOT/scripts" -name '*.sh' ! -name '*.test.sh' | sort)

[ -n "$skipped" ] && printf '  note   inline-dispatch, no cmd_* to resolve:%s\n' "$skipped"

# The guard is worthless if the sweep quietly matches nothing - the same vacuous
# assertion this repo has been bitten by before.
[ "$checked" -ge 5 ] && ok "swept $checked dispatching script(s)" \
  || bad "only $checked dispatching scripts found - the sweep is not looking where it thinks"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

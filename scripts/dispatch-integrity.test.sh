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
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"
        if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi; }

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
  # A dispatched verb missing from the usage string is invisible: the script
  # runs it happily, and the one place a human looks to find out it exists
  # never mentions it. push.sh shipped `rescue` that way. Each script's own
  # suite only ever calls verbs it already knows about, so none of them can
  # see this — only a sweep that reads the dispatch itself can.
  # Anchored on `die "usage:`, not on the first `usage:` in the file: the
  # per-argument `${1:?usage: ...}` messages name one verb each, and matching
  # one of those would report every other verb as undocumented.
  # Newlines folded first: init-repo.sh's usage string spans three lines, and a
  # line-based match would read only the first and call the rest undocumented.
  usage=$(tr '\n' ' ' < "$f" | grep -oE 'die "usage: [^"]*' | tail -1 || true)

  n=0; bad_here=0; undoc=""
  while read -r verb fn; do
    [ -n "${fn:-}" ] || continue
    n=$((n+1))
    grep -q "^${fn}()" "$f" || {
      bad "$rel: verb '$verb' dispatches to $fn, which is not defined"
      bad_here=1
    }
    # A case arm may list alternatives (`a|b)`); each one needs documenting.
    # Delimiters are explicit rather than grep -w so that `pr` does not match
    # inside `preflight`, and `development-branch` matches as one word.
      # Builtins, not `tr` and `grep`: both operands are already in shell
      # variables, and the forked form cost ~4 processes per verb across 45
      # verbs. Verb names are [a-z0-9|_-] only, so nothing needs escaping.
      for v in ${verb//|/ }; do
        re="(^|[^a-z0-9_-])$v([^a-z0-9_-]|$)"
        [[ $usage =~ $re ]] || undoc="$undoc $v"
    done
  done < <(verbs_of "$f")

  if [ -n "$usage" ] && [ -n "$undoc" ]; then
    bad "$rel: dispatches verb(s) its usage string never names:$undoc"
    bad_here=1
  fi
  if [ "$n" -eq 0 ]; then
    bad "$rel: defines cmd_* but no verb dispatches to any of them"
  elif [ "$bad_here" -eq 0 ]; then
    ok "$rel: $n verb(s) all resolve"
    checked=$((checked+1))
  fi
done < <(find "$ROOT/skills" "$ROOT/scripts" -name '*.sh' ! -name '*.test.sh' ! -name '._*' | sort)

[ -n "$skipped" ] && printf '  note   inline-dispatch, no cmd_* to resolve:%s\n' "$skipped"

# The guard is worthless if the sweep quietly matches nothing - the same vacuous
# assertion this repo has been bitten by before.
[ "$checked" -ge 5 ] && ok "swept $checked dispatching script(s)" \
  || bad "only $checked dispatching scripts found - the sweep is not looking where it thinks"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

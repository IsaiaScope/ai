#!/usr/bin/env bash
# Self-check for write.sh. Run: bash write.test.sh
# ponytail: asserts branch derivation and the base-branch gate — the two places
# a wrong answer creates a branch nobody wanted or strands work on the wrong one.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/write.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
export ISO_GLOBAL_CONFIG=/nonexistent
# write.sh reaches the real tracking.sh through iso_sibling, so EVERY fixture
# below -- not just the ones that assert on tracking -- would otherwise write to
# the user's live ledger. This once rebranched a real ticket onto a fixture
# branch name, so it belongs here, above the first test, not beside the first
# test that happens to care.
export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)

echo "branch derivation"
check "known type"    "$(bash "$SH" branch-for 2026-05-26-feat-health-check.md)" "feat/health-check"
check "refactor type" "$(bash "$SH" branch-for 2026-08-21-refactor-iso-config.md)" "refactor/iso-config"
check "unknown type defaults to feat" \
  "$(bash "$SH" branch-for 2026-05-26-make-it-faster.md)" "feat/make-it-faster"
check "path is stripped" \
  "$(bash "$SH" branch-for docs/superpowers/plans/2026-01-01-fix-a.md)" "fix/a"
bash "$SH" branch-for 2026-05-26-feat-.md >/dev/null 2>&1
check "empty slug rejected" "$?" "1"
bash "$SH" branch-for no-date-prefix.md >/dev/null 2>&1
check "missing date prefix rejected" "$?" "1"

newrepo() {
  local d; d=$(mktemp -d)
  git init -q -b "$1" "$d"
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  printf '%s' "$d"
}

echo "fresh branch from a base branch"
r=$(newrepo dev); printf 'dirty\n' > "$r/file.txt"
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md )
check "mode is fresh-branch" "$(printf '%s' "$out" | grep '^mode=')"   "mode=fresh-branch"
check "branch is derived"    "$(printf '%s' "$out" | grep '^branch=')" "branch=feat/thing"
check "landed on it"         "$( cd "$r" && git branch --show-current )" "feat/thing"
check "uncommitted work came along" "$(cat "$r/file.txt")" "dirty"

echo "already on a feature branch: nothing is cut"
r=$(newrepo dev); ( cd "$r" && git checkout -q -b feat/existing )
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-other.md )
check "mode is current-branch" "$(printf '%s' "$out" | grep '^mode=')"   "mode=current-branch"
check "stays put"              "$(printf '%s' "$out" | grep '^branch=')" "branch=feat/existing"
check "no new branch created"  "$( cd "$r" && git branch --list 'feat/other' | wc -l | tr -d ' ')" "0"

echo "protected branches all cut"
for b in dev develop test prod main master; do
  r=$(newrepo "$b")
  out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-x.md | grep '^mode=' )
  check "$b is a base branch" "$out" "mode=fresh-branch"
done

echo "no-branch mode"
r=$(newrepo dev)
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md --no-branch )
check "no checkout happens" "$(printf '%s' "$out" | grep '^branch=')" "branch=dev"
check "mode recorded"       "$(printf '%s' "$out" | grep '^mode=')"   "mode=no-branch"

echo "named branch"
r=$(newrepo dev)
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md --branch=custom/name )
check "named branch used" "$(printf '%s' "$out" | grep '^branch=')" "branch=custom/name"
check "checked out"       "$( cd "$r" && git branch --show-current )" "custom/name"

echo "refusals"
# An existing derived branch is no longer a refusal - it is a resume. See
# "resuming a plan's existing branch" below.
r=$(newrepo dev)
( cd "$r" && bash "$SH" resolve p.md --no-branch --worktree ) >/dev/null 2>&1
check "two modes rejected" "$?" "1"
t=$(mktemp -d); ( cd "$t" && bash "$SH" resolve 2026-01-01-feat-x.md ) >/dev/null 2>&1
check "outside a repo rejected" "$?" "1"

echo "overlay can rename the protected set"
r=$(newrepo trunk); mkdir -p "$r/docs/iso"
printf '%s\n' '{"branches":{"protected":["trunk"]}}' > "$r/docs/iso/config.json"
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md | grep '^mode=' )
check "config decides what counts as a base" "$out" "mode=fresh-branch"

echo "tracking never fails the run"
r=$(newrepo dev)
( cd "$r" && bash "$SH" track progress somewhere/plan.md ) >/dev/null 2>&1
check "track exits 0 regardless" "$?" "0"


echo "resuming a plan's existing branch"
r=$(newrepo dev)
( cd "$r" && git branch feat/thing )
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md )
check "mode is resumed-branch" "$(printf '%s' "$out" | grep '^mode=')"   "mode=resumed-branch"
check "branch is the existing one" "$(printf '%s' "$out" | grep '^branch=')" "branch=feat/thing"
check "landed on it" "$( cd "$r" && git branch --show-current )" "feat/thing"

echo "resuming carries uncommitted work"
r=$(newrepo dev)
( cd "$r" && git branch feat/thing )
printf 'dirty\n' > "$r/file.txt"
( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md ) >/dev/null
check "work came along on resume" "$(cat "$r/file.txt")" "dirty"

echo "an existing branch is no longer an error"
r=$(newrepo dev)
( cd "$r" && git branch feat/thing )
( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md ) >/dev/null 2>&1
check "exits 0 where it used to die" "$?" "0"

echo "the ticket follows the branch"
# Seeds a ledger row by hand, then asserts resolve moved it. Without this the
# gate is tested and the wiring to tracking.sh is not: every other case in this
# file resolves no ticket, so a rebranch that never fires looks identical.
TSH=$(cd "$(dirname "$SH")/../../iso-issue-tracking/scripts" && pwd)/tracking.sh
if [ -x "$TSH" ]; then
  ISO_TRACKER_STATE_DIR=$(mktemp -d)
  r=$(newrepo dev)
  PL=docs/superpowers/plans/2026-05-26-feat-thing.md
  printf '{"WRT-1":{"repo":"r","branch":"dev","project":"p","opened_by":"iso","plan":"%s"}}\n' \
    "$PL" > "$ISO_TRACKER_STATE_DIR/tracked.json"
  # No multica on PATH: the ledger write must still happen, because the board
  # write is best-effort and must not gate it.
  ( cd "$r" && ISO_TRACKER_STATE_DIR="$ISO_TRACKER_STATE_DIR" PATH=/usr/bin:/bin \
      bash "$SH" resolve "$PL" ) >/dev/null 2>&1
  check "resolve moved the ledger row" \
    "$(jq -r '.["WRT-1"].branch' "$ISO_TRACKER_STATE_DIR/tracked.json")" "feat/thing"
  check "resolve read the ticket back" \
    "$( cd "$r" && ISO_TRACKER_STATE_DIR="$ISO_TRACKER_STATE_DIR" PATH=/usr/bin:/bin \
        bash "$TSH" branch-of "$PL" )" "feat/thing"
else
  ok "iso-issue-tracking absent, integration skipped"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Self-check for branch.sh. Run: bash branch.test.sh
# ponytail: asserts the gate matrix and the two name derivations — the places a
# wrong answer creates a branch nobody wanted or strands work on the wrong one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

export ISO_GLOBAL_CONFIG=/nonexistent
# shellcheck source=/dev/null
. "$HERE/branch.sh"
type iso_branch_gate >/dev/null 2>&1 \
  || { echo "FATAL: sourcing did not define iso_branch_gate"; exit 1; }
type iso_config_get >/dev/null 2>&1 \
  || { echo "FATAL: branch.sh did not pull in config.sh"; exit 1; }

echo "iso_is_protected"
iso_is_protected dev        && ok "dev is protected"        || bad "dev not protected"
iso_is_protected main       && ok "main is protected"       || bad "main not protected"
iso_is_protected feat/thing && bad "feature branch treated as protected" \
                            || ok "feature branch is not protected"
iso_is_protected ""         && ok "detached HEAD counts as protected" \
                            || bad "detached HEAD not protected"

echo "iso_integration_candidates"
check "configured development branch first, develop second" \
  "$(iso_integration_candidates | tr '\n' ' ')" "dev develop "

echo "iso_branch_from_plan"
check "known type"    "$(iso_branch_from_plan 2026-05-26-feat-health-check.md)" "feat/health-check"
check "refactor type" "$(iso_branch_from_plan 2026-08-21-refactor-iso-config.md)" "refactor/iso-config"
check "unknown type defaults to feat" \
  "$(iso_branch_from_plan 2026-05-26-make-it-faster.md)" "feat/make-it-faster"
check "path is stripped" \
  "$(iso_branch_from_plan docs/superpowers/plans/2026-01-01-fix-a.md)" "fix/a"
iso_branch_from_plan 2026-05-26-feat-.md >/dev/null 2>&1
check "empty slug rejected" "$?" "1"
iso_branch_from_plan no-date-prefix.md >/dev/null 2>&1
check "missing date prefix rejected" "$?" "1"

echo "iso_branch_from_subject"
check "type and scope" \
  "$(iso_branch_from_subject 'feat(auth): add token refresh')" "feat/auth-add-token-refresh"
check "no scope" \
  "$(iso_branch_from_subject 'fix: broken pipe')" "fix/broken-pipe"
check "breaking marker" \
  "$(iso_branch_from_subject 'feat(api)!: drop v1')" "feat/api-drop-v1"
check "non-conventional falls back to chore" \
  "$(iso_branch_from_subject 'random words here')" "chore/random-words-here"
check "empty subject yields nothing" "$(iso_branch_from_subject '')" ""
long=$(iso_branch_from_subject 'feat(scope): aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk')
[ ${#long} -le 53 ] && ok "long slug truncated" || bad "long slug not truncated (${#long})"
case "$long" in *-) bad "truncated mid-separator" ;; *) ok "truncation lands on a word boundary" ;; esac

echo "iso_branch_gate"
# A real repo: the gate asks git whether the candidate branch exists.
r=$(mktemp -d)
git init -q -b dev "$r"
git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
git -C "$r" commit -q --allow-empty -m init
git -C "$r" branch feat/wiki-ingest
cd "$r" || exit 1

act() { iso_branch_gate "$@" | sed -n 's/^action=//p'; }
brn() { iso_branch_gate "$@" | sed -n 's/^branch=//p'; }

check "row 1  action" "$(act feat/wiki-ingest feat/wiki-ingest '')" "stay"
check "row 1  branch" "$(brn feat/wiki-ingest feat/wiki-ingest '')" "feat/wiki-ingest"
check "row 2  action" "$(act feat/hotfix-typo feat/wiki-ingest '')" "stay"
check "row 2  branch" "$(brn feat/hotfix-typo feat/wiki-ingest '')" "feat/hotfix-typo"
check "row 3  action" "$(act dev feat/wiki-ingest feat/other)" "checkout"
check "row 3  branch" "$(brn dev feat/wiki-ingest feat/other)" "feat/wiki-ingest"
check "row 3b action" "$(act dev feat/absent feat/other)" "create"
check "row 3b branch" "$(brn dev feat/absent feat/other)" "feat/absent"
check "row 4  action" "$(act dev '' feat/brand-new)" "create"
check "row 4  branch" "$(brn dev '' feat/brand-new)" "feat/brand-new"
check "row 4b action" "$(act dev '' feat/wiki-ingest)" "checkout"
check "row 5  action" "$(act dev '' '')" "ask"
check "row 5  branch" "$(brn dev '' '')" ""
# The staleness this whole design exists to fix: a ticket still naming dev must
# never send anyone back to dev.
check "stale ticket ignored" "$(act dev dev feat/brand-new)" "create"
check "stale ticket target"  "$(brn dev dev feat/brand-new)" "feat/brand-new"
check "detached uses proposed" "$(act '' '' feat/brand-new)" "create"
check "gate prints two lines" "$(iso_branch_gate dev '' feat/x | wc -l | tr -d ' ')" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

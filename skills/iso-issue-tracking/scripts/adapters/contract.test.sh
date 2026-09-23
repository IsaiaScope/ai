#!/usr/bin/env bash
# The contract every adapter must satisfy. Run: bash contract.test.sh
# ponytail: shape and inertness only. Whether multica's API answers correctly is
# multica's problem; whether an adapter is complete and safe is ours.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

# Derived from the caller, never listed here. A written-out list is a second
# copy of the interface: `tk_issue_title` was added to the multica adapter and
# called twice from tracking.sh while the list, and none.sh, never heard of it -
# so `tracker: none` hit a command-not-found on two live paths and this test
# reported a full pass. The callers ARE the interface, so ask them.
VERBS=$(grep -oE '\btk_[a-z_]+' "$DIR/../tracking.sh" 2>/dev/null | sort -u)
[ -n "$VERBS" ] || { printf 'contract: found no tk_* calls in tracking.sh -- broken sweep, not a pass\n' >&2; exit 1; }

for a in "$DIR"/*.sh; do
  case "$a" in *contract.test.sh) continue;; esac
  name=$(basename "$a" .sh)
  echo "adapter: $name"
  for v in $VERBS; do
    if bash -c ". '$a' >/dev/null 2>&1; type $v" >/dev/null 2>&1; then
      ok "$name defines $v"
    else
      bad "$name defines $v"
    fi
  done
done

echo "none adapter is inert"
N="$DIR/none.sh"
check "issue_create succeeds" "$(bash -c ". $N; printf body | tk_issue_create p todo t none >/dev/null; echo \$?")" "0"
check "issue_create is silent" "$(bash -c ". $N; printf body | tk_issue_create p todo t none")" ""
check "status write succeeds" "$(bash -c ". $N; tk_issue_status K done; echo \$?")" "0"
check "project_list is empty" "$(bash -c ". $N; tk_project_list")"           ""

echo "multica adapter never starts work"
# The outbound-only invariant: nothing written to the board may cause execution
# locally. --no-start is how multica expresses that, and it must be on every
# status write.
M="$DIR/multica.sh"
writes=$(grep -c 'issue status' "$M")
guarded=$(grep -c 'issue status.*--no-start' "$M")
# Non-vacuity first: if the grep stops matching, "0 == 0" would pass while
# asserting nothing. That is the failure this whole check exists to prevent.
[ "$writes" -gt 0 ] && ok "the status-write grep still matches something" \
                    || bad "the status-write grep matches nothing — assertion is vacuous"
check "every status write carries --no-start" "$guarded" "$writes"

echo "the vendor name is confined to its adapter"
T="$DIR/../tracking.sh"
check "tracking.sh names no vendor" "$(grep -c '\bmultica\b' "$T")" "0"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

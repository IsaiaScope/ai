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

VERBS='tk_current_user tk_project_list tk_project_create
tk_issue_create tk_issue_get_status tk_issue_status tk_issue_describe
tk_issue_comment tk_issue_label tk_issue_property
tk_label_list tk_label_create tk_property_list tk_property_create'

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

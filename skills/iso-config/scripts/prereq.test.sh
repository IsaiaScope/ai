#!/usr/bin/env bash
# Self-check for prereq.sh. Run: bash prereq.test.sh
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/prereq.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

# shellcheck source=/dev/null
. "$SH"

echo "classification"
check "jq is auto"        "$(iso_prereq_class jq)"     "auto"
check "gh is auto"        "$(iso_prereq_class gh)"     "auto"
check "codex is manual"   "$(iso_prereq_class codex)"  "manual"
check "claude is manual"  "$(iso_prereq_class claude)" "manual"
check "herdr is hardcut"  "$(iso_prereq_class herdr)"  "hardcut"
check "unlisted"          "$(iso_prereq_class nope)"   "unknown"

echo "hints"
contains "brew install jq" "$(iso_prereq_hint jq)" && ok "jq hint is runnable" || bad "jq hint is runnable"
contains "login"           "$(iso_prereq_hint codex)" && ok "codex hint mentions auth" || bad "codex hint mentions auth"

echo "sweep"
bin=$(mktemp -d)
for b in jq gh multica codex claude herdr git; do printf '#!/bin/sh\n' > "$bin/$b"; chmod +x "$bin/$b"; done
out=$(PATH="$bin" iso_prereq_sweep); rc=$?
check "all present -> rc 0" "$rc" "0"
contains "ok jq" "$out" && ok "reports jq ok" || bad "reports jq ok"

rm -f "$bin/herdr"
out=$(PATH="$bin" iso_prereq_sweep); rc=$?
check "missing hardcut -> rc 1" "$rc" "1"
contains "hardcut herdr" "$out" && ok "reports herdr hardcut" || bad "reports herdr hardcut"

rm -f "$bin/codex"
out=$(PATH="$bin" iso_prereq_sweep 2>/dev/null)
contains "manual codex" "$out" && ok "reports codex manual" || bad "reports codex manual"

rm -f "$bin/jq"
out=$(PATH="$bin" iso_prereq_sweep 2>/dev/null)
contains "auto jq" "$out" && ok "reports jq auto" || bad "reports jq auto"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

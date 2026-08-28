#!/usr/bin/env bash
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/plan.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
export ISO_GLOBAL_CONFIG=/nonexistent

echo "grill gate"
t=$(mktemp -d)
check "no repo"       "$( cd "$t" && bash "$SH" gate )" "no-repo"
( cd "$t" && git init -q -b main . )
check "setup missing" "$( cd "$t" && bash "$SH" gate )" "setup-missing"
mkdir -p "$t/docs/agents" && touch "$t/docs/agents/domain.md"
check "setup done"    "$( cd "$t" && bash "$SH" gate )" "setup-done"

echo "newest plan"
mkdir -p "$t/docs/superpowers/plans"
check "no plans -> empty" "$( cd "$t" && bash "$SH" newest )" ""
touch "$t/docs/superpowers/plans/2026-01-01-feat-a.md"
sleep 1
touch "$t/docs/superpowers/plans/2026-01-02-feat-b.md"
check "newest wins" "$( cd "$t" && bash "$SH" newest )" "docs/superpowers/plans/2026-01-02-feat-b.md"

echo "newest honours a configured plans dir"
mkdir -p "$t/docs/iso" "$t/planning"
printf '%s\n' '{"paths":{"plans":"planning"}}' > "$t/docs/iso/config.json"
touch "$t/planning/2026-03-03-feat-c.md"
check "overlay moves the plans dir" "$( cd "$t" && bash "$SH" newest )" "planning/2026-03-03-feat-c.md"
rm -f "$t/docs/iso/config.json"

echo "sub-gate is retired: one plan, one ticket"
bash "$SH" sub-gate 8 3 >/dev/null 2>&1; check "sub-gate no longer dispatches" "$?" "1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

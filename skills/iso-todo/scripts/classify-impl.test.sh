#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="$HERE/classify-impl.sh"
fail=0
assert() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
P="docs/superpowers/plans/2026-01-01-feat-x.md"   # key = 2026-01-01-feat-x

# this plan's marker present is authoritative — even alongside a complete-looking banner
tmp=$(mktemp -d); ( cd "$tmp" && mkdir -p .iso/logs/write \
  && touch ".iso/logs/write/2026-01-01-feat-x.blocked.md" \
  && out=$(printf '✓ Implementation complete' | "$CLASSIFY" "$P"); [ "$out" = blocked ] )
assert "this-plan marker → blocked" "[ $? -eq 0 ]"

# success banner, no marker → complete
tmp=$(mktemp -d); ( cd "$tmp" && mkdir -p .iso/logs/write \
  && out=$(printf '✓ Implementation complete — nothing committed.\n' | "$CLASSIFY" "$P"); [ "$out" = complete ] )
assert "banner → complete" "[ $? -eq 0 ]"

# no banner, no marker (timeout / dead tab / partial) → unknown
tmp=$(mktemp -d); ( cd "$tmp" && mkdir -p .iso/logs/write \
  && out=$(printf 'building task 3 of 9...\n' | "$CLASSIFY" "$P"); [ "$out" = unknown ] )
assert "no signal → unknown" "[ $? -eq 0 ]"

# a DIFFERENT plan's marker present must NOT count as this plan blocked (per-plan keying)
tmp=$(mktemp -d); ( cd "$tmp" && mkdir -p .iso/logs/write \
  && touch ".iso/logs/write/2025-12-31-feat-other.blocked.md" \
  && out=$(printf '✓ Implementation complete — nothing committed.\n' | "$CLASSIFY" "$P"); [ "$out" = complete ] )
assert "other-plan marker ignored → complete" "[ $? -eq 0 ]"

exit $fail

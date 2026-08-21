#!/usr/bin/env bash
# iso-plan mechanics. The pipeline order and the summary card stay in SKILL.md;
# only the checks with one right answer live here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

die() { printf 'iso-plan: %s\n' "$1" >&2; exit 1; }

# docs/agents/domain.md is written by setup-matt-pocock-skills. Its absence
# means grill-with-docs has no configured domain-doc layout and would invent
# one, so the chain halts rather than falling back to grill-me inside a repo.
cmd_gate() {
  git rev-parse --git-dir >/dev/null 2>&1 || { printf 'no-repo\n'; return 0; }
  [ -f docs/agents/domain.md ] && printf 'setup-done\n' || printf 'setup-missing\n'
}

cmd_newest() {
  local dir; dir=$(iso_config_get paths.plans)
  ls -t "$dir"/*.md 2>/dev/null | head -1 || true
}

# The tracking script's path, or nothing. Printing an empty string on failure
# is deliberate: every call site guards with [ -x "$S" ], so "not found" and
# "not applicable" collapse into the same silent no-op.
cmd_tracker() { iso_sibling iso-tracking scripts/tracking.sh 2>/dev/null || true; }

case "${1:-}" in
  gate)     cmd_gate ;;
  tracker)  cmd_tracker ;;
  newest)   cmd_newest ;;
  *)        die "usage: plan.sh gate | newest | tracker" ;;
esac

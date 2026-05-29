#!/usr/bin/env bash
# Classify an iso-write implementation tab's outcome after it has gone idle.
# Usage: classify-impl.sh <plan_path>   (recovered tab output on stdin)
# Resolves iso-write's per-plan blocked marker from <plan_path>, checks the recovered
# banner, and prints exactly one of: complete | blocked | unknown
#   blocked  — this plan's marker .iso/logs/write/<plan-basename>.blocked.md exists; authoritative.
#   complete — iso-write's success banner present and no marker for this plan.
#   unknown  — neither signal (timeout, dead tab, partial); caller treats as halt.
set -euo pipefail

plan="${1:?usage: classify-impl.sh <plan_path>}"
key="$(basename "$plan" .md)"
marker=".iso/logs/write/${key}.blocked.md"

out="$(cat)"

if [ -f "$marker" ]; then
  echo blocked
  exit 0
fi
if printf '%s' "$out" | grep -q "Implementation complete"; then
  echo complete
  exit 0
fi
echo unknown

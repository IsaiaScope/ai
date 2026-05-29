#!/usr/bin/env bash
# Executable mechanics for the iso-todo Development cycle after a plan exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SPAWN="${SPAWN:-$ROOT/skills/iso-spawn/scripts/spawn.sh}"
REVIEW="${REVIEW:-$ROOT/skills/iso-review/scripts/review.sh}"
CLASSIFY="${CLASSIFY:-$HERE/classify-impl.sh}"
RV_OUTDIR="${RV_OUTDIR:-.iso/logs/review}"
ISO_SPAWN_LIB="${ISO_SPAWN_LIB:-$ROOT/skills/iso-spawn/scripts/lib}"

# shellcheck source=../../iso-spawn/scripts/lib/herdr.sh
# shellcheck disable=SC1091
. "$ISO_SPAWN_LIB/herdr.sh"
# shellcheck source=../../iso-spawn/scripts/lib/wait.sh
# shellcheck disable=SC1091
. "$ISO_SPAWN_LIB/wait.sh"

usage() {
  echo "usage: todo.sh run-plan <plan_path> [--codex-only]" >&2
}

json_get() { # $1=json $2=key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null || true
}

run_plan() {
  local plan="${1:-}"
  shift || true
  local review_args=("--kill-review-tabs")
  while [ $# -gt 0 ]; do
    case "$1" in
      --codex-only) review_args+=("--codex-only"); shift;;
      *) echo "iso-todo: unknown option: $1" >&2; return 2;;
    esac
  done
  [ -n "$plan" ] && [ -f "$plan" ] || { echo "iso-todo: plan not found: $plan" >&2; return 1; }

  local launch term recovered outcome
  launch=$("$SPAWN" spawn codex --label iso-todo-impl --name itodoimpl --json)
  term=$(json_get "$launch" term)
  [ -n "$term" ] || { echo "iso-todo: spawn produced no term" >&2; return 1; }

  "$SPAWN" send "$term" "/iso-write $plan" >/dev/null
  local wait_ms wait_seconds wait_rc
  wait_ms="${ISO_TODO_WAIT_MS:-3600000}"
  wait_seconds=$(( (wait_ms + 999) / 1000 ))
  wait_done "$term" --timeout "$wait_seconds" || wait_rc=$?
  if [ "${wait_rc:-0}" -ne 0 ]; then
    echo "iso-todo: implementation wait failed in tab $term (wait exit $wait_rc)" >&2
    return 4
  fi

  recovered=$("$SPAWN" recover "$term" || true)
  outcome=$(printf '%s' "$recovered" | "$CLASSIFY" "$plan")
  case "$outcome" in
    complete) ;;
    blocked)
      echo "iso-todo: implementation blocked in tab $term" >&2
      return 3
      ;;
    *)
      echo "iso-todo: implementation outcome unknown in tab $term" >&2
      return 4
      ;;
  esac

  "$REVIEW" run "${review_args[@]}" --fix-term "$term"

  echo "iso-todo: complete"
  echo "plan: $plan"
  echo "implementation_tab: $term"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  run-plan) run_plan "$@" ;;
  *) usage; exit 2 ;;
esac

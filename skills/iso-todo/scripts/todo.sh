#!/usr/bin/env bash
# Executable mechanics for the iso-todo Development cycle after a plan exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SPAWN="${SPAWN:-$ROOT/skills/iso-spawn/scripts/spawn.sh}"
REVIEW="${REVIEW:-$ROOT/skills/iso-review/scripts/review.sh}"
CLASSIFY="${CLASSIFY:-$HERE/classify-impl.sh}"
_ISO_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_ISO_HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
ISO_ARTIFACTS=$(iso_config_get paths.artifacts)

RV_OUTDIR="${RV_OUTDIR:-$ISO_ARTIFACTS/review}"
ISO_SPAWN_LIB="${ISO_SPAWN_LIB:-$ROOT/skills/iso-spawn/scripts/lib}"

# shellcheck source=../../iso-spawn/scripts/lib/herdr.sh
# shellcheck disable=SC1091
. "$ISO_SPAWN_LIB/herdr.sh"
# shellcheck source=../../iso-spawn/scripts/lib/wait.sh
# shellcheck disable=SC1091
. "$ISO_SPAWN_LIB/wait.sh"

usage() {
  echo "usage: todo.sh run-plan <plan_path> [--impl-agent codex|claude] [--review-agent codex|claude]" >&2
}

json_get() { # $1=json $2=key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2" 2>/dev/null || true
}

run_plan() {
  local plan="${1:-}"
  shift || true
  # impl-agent runs /iso-write (default claude); review-agent is forwarded to iso-review's --agent
  # (omit → both reviewers). Each tab is a single agent; iso-review's "omit → both" lives downstream.
  local impl_agent="claude" review_agent=""
  local review_args=("--kill-review-tabs")
  while [ $# -gt 0 ]; do
    case "$1" in
      --impl-agent=*) impl_agent="${1#*=}"; shift;;
      --impl-agent) shift; impl_agent="${1:-claude}"; [ $# -gt 0 ] && shift;;
      --review-agent=*) review_agent="${1#*=}"; shift;;
      --review-agent) shift; review_agent="${1:-}"; [ $# -gt 0 ] && shift;;
      *) echo "iso-todo: unknown option: $1" >&2; return 2;;
    esac
  done
  case "$impl_agent" in codex|claude) ;; *) echo "iso-todo: --impl-agent must be codex|claude (got '$impl_agent')" >&2; return 2;; esac
  case "$review_agent" in ""|codex|claude) ;; *) echo "iso-todo: --review-agent must be codex|claude (got '$review_agent')" >&2; return 2;; esac
  [ -n "$review_agent" ] && review_args+=("--agent" "$review_agent")
  [ -n "$plan" ] && [ -f "$plan" ] || { echo "iso-todo: plan not found: $plan" >&2; return 1; }

  local launch term recovered outcome
  launch=$("$SPAWN" spawn "$impl_agent" --label iso-todo-impl --name itodoimpl --json)
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

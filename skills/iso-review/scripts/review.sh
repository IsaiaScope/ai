#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/drive.sh
# shellcheck disable=SC1091
[ -f "$HERE/lib/drive.sh" ] && . "$HERE/lib/drive.sh"

usage() { echo "usage: review.sh <preflight|detect-test-cmd|reviews|apply|run> [args] (reviews/run support --codex-only; run/apply support --fix-agent codex|claude or --fix-term TERM)"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  preflight)        rv_preflight "$@" ;;
  detect-test-cmd)  rv_detect_test_cmd "$@" ;;
  reviews)          rv_reviews "$@" ;;
  apply)            rv_apply "$@" ;;
  run)              rv_run "$@" ;;
  *) usage; exit 2 ;;
esac

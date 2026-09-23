#!/usr/bin/env bash
# The one way to reach the work tracker. Sourced, never executed.
#
# Tracking is optional: a repo with no tracker still has to plan, write, commit
# and push. So this can never fail a run — no tracker installed, no git repo, a
# verb that errors, all come back as an exit status of 0 and empty stdout. A
# caller that needs to know it got nothing reads the stdout, never the status.
#
# Before this file, seven call sites resolved tracking.sh by hand, and they had
# drifted: two honoured ISO_TRACKING_SH (so only those two were stubbable in a
# test), three guarded on being inside a repo, one deliberately let stderr
# through. The stderr difference is the only real one, and it belongs at the
# call site as a redirection, not here as a flag.
#
# Lives in iso-config rather than iso-issue-tracking on purpose: a caller must
# be able to source this WITHOUT knowing whether the tracker is installed, and
# iso-config is the one skill that is always present. iso-config/scripts/config.sh
# already reaches across for the tracker's hooks.json, so the direction is not new.

# Sourced standalone in a test, this needs iso_sibling and nothing else.
type iso_sibling >/dev/null 2>&1 || {
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sibling.sh"
}

# The runnable tracker, or nothing. ISO_TRACKING_SH overrides resolution; that
# is the seam every self-check uses.
#
# Exposed because "no tracker installed" and "the tracker knows nothing about
# this branch" are different answers to a caller that reports to a human: the
# first deserves silence, the second a warning.
iso_track_path() {
  local sh
  sh="${ISO_TRACKING_SH:-$(iso_sibling iso-issue-tracking scripts/tracking.sh 2>/dev/null)}" || true
  [ -x "$sh" ] && printf '%s\n' "$sh"
  return 0
}

# <verb> [args...] -> the verb's stdout. Always exits 0.
iso_track() {
  local sh
  sh=$(iso_track_path)
  [ -n "$sh" ] || return 0
  # No repo means no branch, no plan and no work to file against.
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  "$sh" "$@" || true
  return 0
}

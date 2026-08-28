#!/usr/bin/env bash
# iso-write mechanics: derive the branch, resolve the workspace, carry the
# stash, call tracking. Plan execution stays in SKILL.md — this file makes no
# decision a model should be making.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/track.sh)"

die() { printf 'iso-write: %s\n' "$1" >&2; exit 1; }

# Branch naming and the base-branch test both live in iso-config's branch.sh now:
# iso-push carried its own copy of each, under different names.
cmd_branch_for() {
  iso_branch_from_plan "$1" \
    || die "plan filename lacks a YYYY-MM-DD- prefix, or has an empty slug: $1"
}

# Carry uncommitted work across a checkout. Echoes the stash label, and only
# the label, so the caller can pop exactly that stash.
stash_carry() {
  local name="iso-write/$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git stash push -u -m "$name" >&2 || die "stash failed"
  printf '%s' "$name"
}

stash_pop() {
  local ref
  [ -n "$1" ] || return 0
  ref=$(git stash list --format='%gd %s' | grep -F "$1" | head -1 | cut -d' ' -f1)
  git stash pop "${ref:-stash@{0}}" >/dev/null \
    || die "stash pop conflict — resolve, then re-run"
}

cmd_resolve() {
  local plan="${1:?usage: write.sh resolve <plan> [flag]}"; shift
  local flag="" arg branch current mode label proposed tb gate action
  for arg in "$@"; do
    case "$arg" in
      --no-branch|--worktree|--branch=*)
        [ -n "$flag" ] && die "pick one workspace mode"
        flag="$arg" ;;
      *) die "unknown flag: $arg" ;;
    esac
  done
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
  current=$(git branch --show-current)

  case "$flag" in
    --no-branch) mode=no-branch; branch="$current" ;;
    --branch=*)
      branch="${flag#--branch=}"
      label=$(stash_carry "$branch") || true
      if git rev-parse --verify "$branch" >/dev/null 2>&1; then
        git checkout -q "$branch"      # named on purpose: reuse, do not refuse
      else
        git checkout -q -b "$branch"
      fi
      stash_pop "${label:-}"
      mode=named-branch ;;
    --worktree)
      # SKILL.md hands off to superpowers:using-git-worktrees from here.
      branch=$(cmd_branch_for "$plan"); mode=worktree ;;
    "")
      proposed=$(cmd_branch_for "$plan")
      # The ticket's branch, so a resume beats cutting a near-duplicate. Empty
      # when there is no tracker, no ticket, or nothing recorded - all normal.
      tb=$(iso_track branch-of "$plan" 2>/dev/null)
      gate=$(iso_branch_gate "$current" "$tb" "$proposed")
      action=$(printf '%s' "$gate" | sed -n 's/^action=//p')
      branch=$(printf '%s' "$gate" | sed -n 's/^branch=//p')
      case "$action" in
        stay)
          # A branch with no commits isolates nothing: same worktree, same index.
          # Cutting another one buys the bookkeeping and none of the separation.
          branch="$current"; mode=current-branch ;;
        checkout)
          label=$(stash_carry "$branch") || true
          git checkout -q "$branch"
          stash_pop "${label:-}"
          mode=resumed-branch ;;
        create)
          label=$(stash_carry "$branch") || true
          git checkout -q -b "$branch"
          stash_pop "${label:-}"
          mode=fresh-branch ;;
        *)
          # `ask` is unreachable here: cmd_branch_for always yields a name or dies.
          die "cannot decide a branch for $plan" ;;
      esac ;;
  esac
  # Point the ticket at the branch this run actually landed on. Called in every
  # mode, including current-branch: that is the case where the ticket is most
  # likely already wrong, because the user moved themselves.
  iso_track rebranch "$plan" "$branch" >/dev/null 2>&1
  printf 'mode=%s\nbranch=%s\n' "$mode" "$branch"
}

# Tracking must never be able to fail a write run — iso_track guarantees that
# for every caller, so nothing here needs its own guard.
cmd_track() {
  # stderr is deliberately not silenced: tracking never fails the run, but a
  # transition that matched no ticket must be visible, not silent.
  iso_track "$1" "$2" >/dev/null
}

case "${1:-}" in
  branch-for) shift; cmd_branch_for "$@" ;;
  resolve)    shift; cmd_resolve "$@" ;;
  track)      shift; cmd_track "$@" ;;
  *) die "usage: write.sh branch-for <plan> | resolve <plan> [flag] | track <state> <plan>" ;;
esac

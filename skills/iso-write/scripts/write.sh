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

die() { printf 'iso-write: %s\n' "$1" >&2; exit 1; }

KNOWN_TYPES='feat fix chore refactor docs test perf'

# YYYY-MM-DD-<type>-<slug>.md -> <type>/<slug>. An unrecognised second token is
# part of the slug and the type defaults to feat.
cmd_branch_for() {
  local base rest type slug t
  base=${1##*/}; base=${base%.md}
  rest=${base#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}
  [ "$rest" = "$base" ] && die "plan filename lacks a YYYY-MM-DD- prefix: $1"
  type=feat; slug="$rest"
  for t in $KNOWN_TYPES; do
    if [ "${rest%%-*}" = "$t" ]; then type="$t"; slug="${rest#*-}"; break; fi
  done
  [ -n "$slug" ] || die "empty slug after type prefix"
  printf '%s/%s\n' "$type" "$slug"
}

# A place work is promoted TO, never worked ON. Detached HEAD counts, so the
# work gets a ref to live on.
is_base_branch() {
  local b
  [ -z "$1" ] && return 0
  for b in $(iso_config_get branches.protected); do
    [ "$b" = "$1" ] && return 0
  done
  return 1
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
  local flag="" arg branch current mode label
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
      if is_base_branch "$current"; then
        branch=$(cmd_branch_for "$plan")
        git rev-parse --verify "$branch" >/dev/null 2>&1 \
          && die "branch $branch already exists — delete it, rename the plan, or pass --branch=$branch"
        label=$(stash_carry "$branch") || true
        git checkout -q -b "$branch"
        stash_pop "${label:-}"
        mode=fresh-branch
      else
        # A branch with no commits isolates nothing: same worktree, same index.
        # Cutting another one buys the bookkeeping and none of the separation.
        branch="$current"; mode=current-branch
      fi ;;
  esac
  printf 'mode=%s\nbranch=%s\n' "$mode" "$branch"
}

# Tracking must never be able to fail a write run.
cmd_track() {
  local s
  s=$(iso_sibling iso-tracking scripts/tracking.sh) || return 0
  # stderr is deliberately not swallowed: tracking never fails the run, but a
  # transition that matched no card must be visible, not silent.
  [ -x "$s" ] && git rev-parse --show-toplevel >/dev/null 2>&1 \
    && "$s" "$1" "$2" >/dev/null
  return 0
}

case "${1:-}" in
  branch-for) shift; cmd_branch_for "$@" ;;
  resolve)    shift; cmd_resolve "$@" ;;
  track)      shift; cmd_track "$@" ;;
  *) die "usage: write.sh branch-for <plan> | resolve <plan> [flag] | track <state> <plan>" ;;
esac

#!/usr/bin/env bash
# Shared branch vocabulary for iso-* skills. Sourced, never executed.
#
# The only reader of branches.protected, and the only place a branch name is
# derived from a plan filename or a commit subject. Before this file, iso-write
# and iso-push each carried their own copy of both, under different names.
#
# Pure on purpose: git state and config in, a verdict out. It never calls the
# tracker. iso-issue-tracking sources iso-config, so a call back the other way
# would be a dependency cycle — callers resolve the ticket with whatever
# identifier they already hold and pass the answer in.

# Callers normally source config.sh first. Pull it in if not, so this file works
# standalone in a test without every caller growing a second source line.
type iso_config_get >/dev/null 2>&1 || {
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
}

ISO_KNOWN_TYPES='feat fix chore refactor docs test perf'

# The branch HEAD points at, or empty when it points at a commit.
#
# `symbolic-ref`, not `rev-parse --abbrev-ref`: the latter answers with the
# literal string "HEAD" on a detached head, and every caller that took that for
# a branch name went on to bind, resolve and gate by a branch called HEAD.
# Empty is the answer iso_branch_gate below already documents for that case.
iso_current_branch() { git symbolic-ref --quiet --short HEAD 2>/dev/null || printf ''; }

# A place work is promoted TO, never worked ON. An empty branch is a detached
# HEAD and counts: work must not live on a ref nothing will find again.
iso_is_protected() {
  local b
  [ -z "$1" ] && return 0
  for b in $(iso_config_get branches.protected); do
    [ "$b" = "$1" ] && return 0
  done
  return 1
}

# The names that may be the integration branch, in preference order.
#
# Callers RESOLVE them differently and must keep doing so: iso-push asks origin
# and dies when neither exists, the tracker reads local refs and falls back to
# origin/HEAD. But WHICH names to try is one fact, and it was written out twice
# — so renaming branches.development moved one of them and not the other.
#
# `develop` stays a literal here: it is the alternative spelling of the same
# role, not a second configured value, and both call sites already hardcoded it
# beside their own read of the configured one.
iso_integration_candidates() {
  local dev
  dev=$(iso_config_get branches.development)
  [ -n "$dev" ] && printf '%s\n' "$dev"
  [ "$dev" = develop ] || printf 'develop\n'
}

# YYYY-MM-DD-<type>-<slug>.md -> <type>/<slug>. An unrecognised second token is
# part of the slug and the type defaults to feat.
iso_branch_from_plan() {
  local base rest type slug t
  base=${1##*/}; base=${base%.md}
  rest=${base#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}
  [ "$rest" = "$base" ] && return 1
  type=feat; slug="$rest"
  for t in $ISO_KNOWN_TYPES; do
    if [ "${rest%%-*}" = "$t" ]; then type="$t"; slug="${rest#*-}"; break; fi
  done
  [ -n "$slug" ] || return 1
  printf '%s/%s\n' "$type" "$slug"
}

# "feat(scope): message" -> feat/scope-message. Nothing on empty input.
iso_branch_from_subject() {
  local subject="${1:-}" type scope msg slug
  [ -n "$subject" ] || return 0

  type=$(printf '%s' "$subject" | sed -n 's/^\([a-z][a-z]*\)[(!:].*/\1/p')
  case "$type" in
    feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert) ;;
    # Not a conventional subject. chore is the honest answer: it is what the
    # version bump would treat it as anyway, so the branch name agrees with what
    # the release will do rather than guessing something prettier.
    *) type=chore ;;
  esac

  scope=$(printf '%s' "$subject" | sed -n 's/^[a-z][a-z]*(\([^)]*\)).*/\1/p')
  msg=$(printf '%s' "$subject" | sed 's/^[^:]*: *//')

  slug=$(printf '%s-%s' "$scope" "$msg" | tr '[:upper:]' '[:lower:]' \
         | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-*//; s/-*$//')

  # Cut at a word boundary, never mid-word: a branch ending in `destro` invites
  # someone to wonder whether it was truncated or misspelled.
  if [ ${#slug} -gt 48 ]; then
    slug=$(printf '%s' "$slug" | cut -c1-48 | sed 's/-[^-]*$//')
  fi
  [ -n "$slug" ] || slug=work

  printf '%s/%s\n' "$type" "$slug"
}

# Where should this work live? Prints a verdict; it never checks anything out
# and never asks a question, because a script cannot ask one. The calling
# SKILL.md renders the prompt for `ask`, and performs the checkout otherwise.
#
#   $1 current branch      ("" for detached HEAD)
#   $2 the ticket's branch ("" when there is no ticket, or none recorded)
#   $3 a proposed name     ("" when the caller had nothing to derive one from)
#
# Prints:
#   action=stay|checkout|create|ask
#   branch=<name>          (the current branch for stay, empty for ask)
iso_branch_gate() {
  local cur="$1" tb="${2:-}" proposed="${3:-}" candidate=""

  # Standing on a feature branch is a deliberate act. Where you are is where you
  # are working, even when the ticket still names somewhere else.
  iso_is_protected "$cur" || { printf 'action=stay\nbranch=%s\n' "$cur"; return 0; }

  # The ticket's own branch beats a freshly derived name: resuming beats cutting
  # a near-duplicate and splitting one ticket across two branches. A ticket still
  # naming a protected branch is exactly the staleness this design fixes, so it
  # is ignored rather than followed back onto dev.
  if [ -n "$tb" ] && [ "$tb" != "$cur" ] && ! iso_is_protected "$tb"; then
    candidate="$tb"
  else
    candidate="$proposed"
  fi

  [ -n "$candidate" ] || { printf 'action=ask\nbranch=\n'; return 0; }

  # An existing candidate is a resume, not a collision. This is what replaces
  # write.sh's refusal to run twice against the same plan.
  if git rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null 2>&1; then
    printf 'action=checkout\nbranch=%s\n' "$candidate"
  else
    printf 'action=create\nbranch=%s\n' "$candidate"
  fi
}

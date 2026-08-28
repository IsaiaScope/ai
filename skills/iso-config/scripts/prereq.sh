#!/usr/bin/env bash
# Prerequisite classification. Absence is not one condition: what a skill can
# do about a missing binary is what the code branches on, never the binary.
# Sourced by config.sh's CLI; sets no shell options of its own.

# Bump when the list below changes. A bump invalidates every readiness stamp in
# the field, so adding a prerequisite re-triggers the sweep without anyone
# remembering to.
# iso_prereq_hint composes iso_pkg_install, which lives next door in
# lib/config.sh. Sourced here rather than assumed: the CLI happens to load
# config.sh on the line above this one today, and a `command -v || stub`
# fallback for the day it does not would quietly degrade every hint to a bare
# `install jq` — a wrong answer that reads exactly like a right one. Sourcing
# twice costs a jq check and some function redefinitions.
PREREQ_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$PREREQ_HERE/lib/config.sh"

ISO_PREREQ_VERSION=1

# bin:class — auto (installable unattended), manual (auth-gated, print steps),
# hardcut (no install path exists, the skill stops).
ISO_PREREQS='git:auto jq:auto gh:auto multica:auto codex:manual claude:manual herdr:hardcut'

iso_prereq_class() {
  local e
  for e in $ISO_PREREQS; do
    [ "${e%%:*}" = "$1" ] && { printf '%s' "${e##*:}"; return 0; }
  done
  printf 'unknown'
}

iso_prereq_hint() {
  case "$1" in
    gh)
      # The one prerequisite that cannot be installed by name off Homebrew:
      # every Linux manager wants GitHub's repo added first, so a bare
      # `apt-get install gh` fails or installs something else entirely.
      if command -v brew >/dev/null 2>&1; then printf 'brew install gh'  # portability-ok: guarded above
      else printf 'see https://github.com/cli/cli#installation'
      fi ;;
    git|jq|multica) printf '%s %s' "$(iso_pkg_install)" "$1" ;;
    codex)  printf 'npm install -g @openai/codex, then: codex login' ;;
    claude) printf 'npm install -g @anthropic-ai/claude-code, then run: claude' ;;
    herdr)  printf 'no package exists — build it and put it on PATH' ;;
    *)      printf 'unknown prerequisite' ;;
  esac
}

# One line per prerequisite: "<state> <bin> <hint>", where state is `ok` for a
# binary that resolves and its class otherwise. Returns 1 if any hardcut is
# missing — that is the only absence a skill cannot work around.
iso_prereq_sweep() {
  local e b cls rc=0
  for e in $ISO_PREREQS; do
    # Through iso_prereq_class, not a second inline "${e##*:}": that left the
    # function with test callers and no production ones, so the encoding of
    # ISO_PREREQS had two decoders and only one of them was exercised by the
    # code that ships.
    b="${e%%:*}"; cls=$(iso_prereq_class "$b")
    if command -v "$b" >/dev/null 2>&1; then
      printf 'ok %s\n' "$b"
    else
      printf '%s %s %s\n' "$cls" "$b" "$(iso_prereq_hint "$b")"
      [ "$cls" = "hardcut" ] && rc=1
    fi
  done
  return "$rc"
}

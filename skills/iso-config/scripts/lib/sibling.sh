#!/usr/bin/env bash
# Resolve a file inside a sibling skill, from wherever this skill is installed.
# Sourced, never executed.
#
# Every topology puts a skill's siblings directly beside it:
#   <repo>/skills/<skill>/                    the repository
#   ~/.claude/skills/<skill>                  development symlink
#   ~/.claude/plugins/marketplaces/*/skills/  marketplace clone
#   ~/.agents/skills/<skill>                  upstream-pack indirection
# So "one directory up, then across" is correct in all four. `$HOME/.claude` is
# correct in exactly one, which is the bug this replaces.

iso_sibling() {
  local skill="$1" rel="$2" here candidate
  # BASH_SOURCE[1] is the file that called us, not this library.
  here=$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)
  # Walk up from the caller until a directory holding sibling skills appears.
  while [ "$here" != "/" ]; do
    candidate="$here/../$skill/$rel"
    if [ -e "$candidate" ]; then
      ( cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")" )
      return 0
    fi
    here=$(dirname "$here")
  done
  return 1
}

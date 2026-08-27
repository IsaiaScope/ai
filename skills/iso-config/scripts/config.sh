#!/usr/bin/env bash
# iso-config CLI. All logic lives in lib/; this file only dispatches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib/sibling.sh"
# shellcheck source=/dev/null
. "$HERE/lib/config.sh"
# shellcheck source=/dev/null
. "$HERE/prereq.sh"

die() { printf 'iso-config: %s\n' "$1" >&2; exit 1; }

cmd_init() {
  local dir; dir=$(dirname "$ISO_GLOBAL_CONFIG")
  mkdir -p "$dir"
  if [ -f "$ISO_GLOBAL_CONFIG" ]; then die "$ISO_GLOBAL_CONFIG already exists"; fi
  iso_defaults | jq 'del(.checked)' > "$ISO_GLOBAL_CONFIG"
  printf 'wrote %s\n' "$ISO_GLOBAL_CONFIG"
  printf 'edit it, then run: iso-config doctor\n'
}

# Where each value came from is the question worth answering, so show prints
# the scope alongside the merged value rather than just dumping JSON.
cmd_show() {
  local overlay; overlay=$(iso_repo_overlay_path 2>/dev/null) || overlay="/nonexistent"
  printf 'global   %s%s\n' "$ISO_GLOBAL_CONFIG" \
    "$([ -f "$ISO_GLOBAL_CONFIG" ] || printf '   (absent)')"
  printf 'overlay  %s%s\n\n' "$overlay" \
    "$([ -f "$overlay" ] || printf '   (absent)')"
  iso_config
}

# ADR-0004 records ~/.codex/skills/ sitting empty while CLAUDE.md documented
# both agents as linked. Catching a claim and a filesystem disagreeing is what
# doctor is for.
# ponytail: reports, never repairs — install.js owns the linking.
cmd_doctor_topology() {
  local d n
  for d in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    if [ ! -d "$d" ]; then printf '  absent   %s\n' "$d"; continue; fi
    n=$(find "$d" -maxdepth 1 -name 'iso-*' | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then
      printf '  EMPTY    %s   -> run: node scripts/install.js\n' "$d"
    else
      printf '  ok       %s   (%s iso-* skills)\n' "$d" "$n"
    fi
  done
}

# The tracker hooks install.js writes into the agent's settings. Identity is the
# marker token, never the path: matching on the path would make a renamed hook
# invisible rather than stale, which is exactly how a dead reconcile hook once
# survived a rename unnoticed.
# Read from the same file install.js writes from, never a second copy: a
# hardcoded list here would let doctor check fewer hooks than install installs,
# and report ready while doing it. Unreadable list -> no hook lines at all,
# which is honest; a check that cannot read its own subject asserts nothing.
iso_hooks() {
  local f
  f=$(iso_sibling iso-issue-tracking scripts/hooks.json 2>/dev/null) || return 1
  jq -r '.[] | "\(.event):\(.name)"' "$f" 2>/dev/null
}

# Warn, never fail. A dead hook loses board bookkeeping, not the ability to
# work, and tracking's whole contract is that it cannot fail a run - so its
# install defect must not fail readiness either. Same posture as the topology
# check above, down to the remedy line.
cmd_doctor_hooks() {
  local settings="${ISO_AGENT_SETTINGS:-$HOME/.claude/settings.json}" pair ev name cmd target
  if ! iso_hooks >/dev/null 2>&1; then
    printf '  absent   hook list (iso-issue-tracking/scripts/hooks.json)\n'
    return 0
  fi
  if [ ! -f "$settings" ]; then
    printf '  absent   %s   -> run: node scripts/install.js\n' "$settings"
    return 0
  fi
  for pair in $(iso_hooks); do
    ev=${pair%%:*}; name=${pair##*:}
    cmd=$(jq -r --arg e "$ev" --arg m "# iso-hook:$name" \
      '(.hooks[$e] // [])[]? | (.hooks // [])[]? | select((.command // "") | contains($m)) | .command' \
      "$settings" 2>/dev/null | head -1)
    if [ -z "$cmd" ]; then
      printf '  MISSING  hook %s/%s   -> run: node scripts/install.js\n' "$ev" "$name"
      continue
    fi
    # The path the hook itself guards on, so this checks the same thing the
    # hook checks - not a second copy of the path that could disagree with it.
    target=$(printf '%s' "$cmd" | sed -n 's/.*S="\([^"]*\)".*/\1/p')
    target=${target/#\$HOME/$HOME}
    if [ -x "$target" ]; then
      printf '  ok       hook %s/%s\n' "$ev" "$name"
    elif [ -z "$target" ]; then
      # Marked, but not shaped like a hook we wrote - hand-edited, most likely.
      # Naming that is more use than printing an empty path where one should be.
      printf '  STALE    hook %s/%s guards no path   -> run: node scripts/install.js\n' "$ev" "$name"
    else
      printf '  STALE    hook %s/%s -> %s   -> run: node scripts/install.js\n' "$ev" "$name" "$target"
    fi
  done
}

cmd_doctor() {
  local overlay out rc=0
  overlay=$(iso_repo_overlay_path 2>/dev/null) || overlay="/nonexistent"
  if ! iso_config_validate_overlay "$overlay"; then rc=1; fi
  out=$(iso_prereq_sweep) || rc=1
  printf '%s\n' "$out" | while read -r state bin hint; do
    case "$state" in
      ok)      printf '  ok       %s\n' "$bin" ;;
      auto)    printf '  install  %s   -> %s\n' "$bin" "$hint" ;;
      manual)  printf '  manual   %s   -> %s\n' "$bin" "$hint" ;;
      hardcut) printf '  BLOCKED  %s   -> %s\n' "$bin" "$hint" ;;
    esac
  done
  cmd_doctor_topology
  cmd_doctor_hooks
  [ "$rc" -eq 0 ] || die "not ready — resolve the lines above"
  iso_stamp_write
  printf '\nready (prerequisite list v%s)\n' "$ISO_PREREQ_VERSION"
}

# Sourced by the self-check to exercise the helpers in isolation. Without this
# the dispatch below runs, hits the usage `die`, and kills the sourcing shell.
(return 0 2>/dev/null) && return 0

case "${1:-}" in
  init)   cmd_init ;;
  show)   cmd_show ;;
  doctor) cmd_doctor ;;
  *)      die "usage: config.sh init | show | doctor" ;;
esac

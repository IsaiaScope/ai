#!/usr/bin/env bash
# cleanup.sh — free resources: kill an agent's tab, remove sidecars. Assumes pipefail and
# that herdr.sh + transcript.sh are sourced.

# Delete the .spawn sidecar for a TERM. $2 optional logdir override (defaults to search dirs).
cleanup_rm_sidecar() { # $1=term [$2=logdir]
  local sf
  if [ -n "${2:-}" ]; then sf=$(find "$2" -maxdepth 1 -name "*__$1.spawn" 2>/dev/null | head -1)
  else sf=$(transcript_sidecar_for "$1"); fi
  [ -n "$sf" ] && rm -f "$sf" 2>/dev/null || true
}

# Kill an agent's tab (frees the process/memory) and drop its sidecar.
cleanup_kill_agent() { # $1=term
  local tab; tab=$(herdr_tab_for "$1")
  [ -n "$tab" ] && herdr_tab_close "$tab"
  cleanup_rm_sidecar "$1"
}

# Remove sidecars whose TERM is absent from the live agent list AND older than the grace
# window (ISO_ORPHAN_GRACE seconds, default 60). Searches known local and indexed logdirs.
cleanup_orphaned() {
  local dir grace live now mtime term f
  grace="${ISO_ORPHAN_GRACE:-60}"
  live=$(herdr_agent_terms)
  now=$(date +%s)
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*__*.spawn; do
      [ -f "$f" ] || continue
      term=$(grep '^term=' "$f" | head -1 | cut -d= -f2- || true)
      [ -n "$term" ] || term="${f##*__}"; term="${term%.spawn}"
      printf '%s\n' "$live" | grep -qx "$term" && continue          # still alive -> keep
      mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
      [ $((now - mtime)) -ge "$grace" ] && rm -f "$f" 2>/dev/null || true
    done
  done < <(transcript_known_logdirs)
}

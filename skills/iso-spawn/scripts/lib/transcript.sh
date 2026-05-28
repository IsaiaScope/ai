#!/usr/bin/env bash
# transcript.sh — map a spawned agent to its native JSONL transcript, and the .spawn sidecar.
# Pure filesystem logic; dirs are env-overridable for tests (ISO_CODEX_SESS, ISO_CLAUDE_PROJ).
# Assumes the caller set `set -euo pipefail`.

# Slug a cwd the way claude names its project dir: '/' and '.' -> '-'.
transcript_slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

# Global registry for log directories. This lets `cleanup --orphaned` find sidecars written
# from other cwd roots, and also covers the TMPDIR fallback path.
transcript_logdir_index() {
  printf '%s' "${ISO_SPAWN_INDEX:-${TMPDIR:-/tmp}/iso-spawn-logdirs-${USER:-unknown}.txt}"
}

transcript_record_logdir() { # $1=logdir
  local dir="$1" idx
  [ -n "$dir" ] || return 0
  idx=$(transcript_logdir_index)
  mkdir -p "$(dirname "$idx")" 2>/dev/null || return 0
  grep -Fx -- "$dir" "$idx" >/dev/null 2>&1 || printf '%s\n' "$dir" >> "$idx" 2>/dev/null || true
}

transcript_known_logdirs() {
  local idx
  idx=$(transcript_logdir_index)
  {
    [ -n "${ISO_SPAWN_LOGDIR:-}" ] && printf '%s\n' "$ISO_SPAWN_LOGDIR"
    printf '%s\n' "./.iso/logs/spawn"
    printf '%s\n' "${TMPDIR:-/tmp}"
    [ -f "$idx" ] && cat "$idx"
  } | awk 'NF && !seen[$0]++'
}

# Print the current candidate transcript files for an agent+cwd, one per line, sorted.
transcript_candidate_set() { # $1=codex|claude  $2=cwd
  case "$1" in
    codex)
      find "${ISO_CODEX_SESS:-$HOME/.codex/sessions}" -name 'rollout-*.jsonl' 2>/dev/null | sort ;;
    claude*)
      local d="${ISO_CLAUDE_PROJ:-$HOME/.claude/projects}/$(transcript_slug "$2")"
      find "$d" -maxdepth 1 -name '*.jsonl' 2>/dev/null | sort ;;
  esac
}

# Newest file present now but not in the pre-snapshot. Empty if none.
transcript_diff_new() { # $1=agent $2=cwd $3=pre(newline-joined)
  local post; post=$(transcript_candidate_set "$1" "$2")
  comm -13 <(printf '%s\n' "$3" | sort) <(printf '%s\n' "$post" | sort) \
    | grep -v '^$' \
    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"; done \
    | sort -rn | head -1 | cut -f2-
}

# Write the .spawn meta block. deliver_worker later appends `session_file=`.
transcript_write_meta() { # $1=spawnfile $2=term $3=agent $4=cwd $5=pre(newline-joined)
  {
    echo "[meta]"
    echo "term=$2"
    echo "agent=$3"
    echo "cwd=$4"
    [ "$3" = claude ] && echo "slug=$(transcript_slug "$4")"
    if [ -n "$5" ]; then
      while IFS= read -r p; do [ -n "$p" ] && echo "pre=$p"; done <<< "$5"
    fi
  } > "$1"
}

# Resolve THIS spawn's transcript among files that appeared after the pre-snapshot.
#   1) candidates = post - pre   2) if a prompt is given, prefer the candidate whose content
#   contains it (race-proof fingerprint)   3) else newest-by-mtime.
transcript_resolve_new() { # $1=agent $2=cwd $3=pre(newline-joined) $4=prompt(optional)
  local agent="$1" cwd="$2" pre="$3" prompt="$4" post cands f
  post=$(transcript_candidate_set "$agent" "$cwd")
  cands=$(comm -13 <(printf '%s\n' "$pre" | sort) <(printf '%s\n' "$post" | sort) | grep -v '^$')
  [ -n "$cands" ] || return 0
  if [ -n "$prompt" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      if grep -qF -- "$prompt" "$f" 2>/dev/null; then printf '%s' "$f"; return; fi
    done <<< "$cands"
  fi
  # newest-by-mtime fallback
  printf '%s\n' "$cands" | while IFS= read -r f; do
    [ -f "$f" ] && printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"
  done | sort -rn | head -1 | cut -f2-
}

# Find the .spawn sidecar path for a TERM. Empty if none.
transcript_sidecar_for() { # $1=term
  local base cand
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    cand=$(find "$base" -maxdepth 1 -name "*__$1.spawn" 2>/dev/null | head -1)
    [ -n "$cand" ] && { printf '%s' "$cand"; return; }
  done < <(transcript_known_logdirs)
}

#!/usr/bin/env bash
# deliver.sh — drive a freshly-spawned agent: clear trust modals, inject the prompt once,
# confirm acceptance, then record the resolved transcript in the sidecar. Assumes pipefail
# and that herdr.sh + transcript.sh are already sourced.

# Classify the prompt against a screen capture: submitted | pending | none.
deliver_classify() { # $1=prompt  (screen on stdin)
  python3 -c 'import sys
scr=sys.stdin.read(); p=sys.argv[1].strip()
if not p: print("none"); sys.exit()
lines=[l for l in scr.splitlines() if l.strip()]
inp=next((l for l in reversed(lines) if l.lstrip().startswith(("›","❯"))), "")
body=inp.lstrip().lstrip("›❯").strip()
print("pending" if p in body else ("submitted" if p in scr else "none"))' "$1"
}

# The detached/foreground delivery worker.
deliver_worker() { # $1=term $2=pane $3=wait $4=wait_ms $5=prompt $6=spawnfile
  local TERM2="$1" PANE="$2" WAIT="$3" WAIT_MS="$4" PROMPT="$5" SPAWNFILE="$6"
  local READY='/model to change|permissions: YOLO|esc to interrupt|bypass permissions|for shortcuts|for agents|Claude Code v|OpenAI Codex|Improve documentation'
  local injected=0 S C
  for _ in $(seq 1 40); do
    S=$(herdr_pane_read "$PANE" 40)
    if   printf '%s' "$S" | grep -qiE 'Trust all and continue';          then herdr_send_keys "$PANE" Down Enter; sleep 1; continue
    elif printf '%s' "$S" | grep -qiE 'Press t to trust|trust all hooks'; then herdr_send_keys "$PANE" t;          sleep 1; continue
    elif printf '%s' "$S" | grep -qiE 'Do you trust the files|trust this folder|project you created or one you trust'; then herdr_send_keys "$PANE" Enter; sleep 1; continue; fi
    [ -n "$PROMPT" ] || break
    C=$(printf '%s' "$S" | deliver_classify "$PROMPT" || echo none)
    if [ "$injected" = 1 ]; then
      case "$(herdr_agent_status "$TERM2")" in working|done|blocked) break;; esac
      [ "$C" = submitted ] && break
      if [ "$C" = pending ]; then herdr_send_keys "$PANE" Enter; sleep 1; continue; fi
    fi
    if [ "$C" = pending ]; then herdr_send_keys "$PANE" Enter; sleep 1
    elif printf '%s' "$S" | grep -qiE "$READY"; then herdr_pane_run "$PANE" "$PROMPT"; injected=1; sleep 2
    else sleep 1; fi
  done
  # Record the transcript now that the agent is live.
  if [ -n "$SPAWNFILE" ] && [ -f "$SPAWNFILE" ]; then
    local m_agent m_cwd m_pre a newf
    m_agent=$(grep '^agent=' "$SPAWNFILE" | head -1 | cut -d= -f2- || true)
    m_cwd=$(grep '^cwd=' "$SPAWNFILE" | head -1 | cut -d= -f2- || true)
    m_pre=$(grep '^pre=' "$SPAWNFILE" | cut -d= -f2- || true)
    case "$m_agent" in claude*) a=claude;; *) a=codex;; esac
    newf=$(transcript_resolve_new "$a" "$m_cwd" "$m_pre" "$PROMPT")
    [ -n "$newf" ] && echo "session_file=$newf" >> "$SPAWNFILE"
  fi
  [ "$WAIT" = 1 ] && herdr agent wait "$TERM2" --status idle --timeout "$WAIT_MS" >/dev/null 2>&1 || true
}

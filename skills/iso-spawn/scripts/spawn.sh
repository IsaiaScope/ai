#!/usr/bin/env bash
# iso-spawn: launch a codex or claude agent in its OWN herdr tab, in the workspace the caller lives in.
# Defaults: full permissions ON, cwd = caller's pane cwd, stays in background (no focus steal),
# prompt injected + auto-run, delivery happens async so the caller never freezes on slow boot.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SELFDIR="$(cd "$(dirname "$0")" && pwd)"

LIBDIR="$SELFDIR/lib"
. "$LIBDIR/agentkind.sh"
. "$LIBDIR/transcript.sh"
. "$LIBDIR/herdr.sh"
. "$LIBDIR/wait.sh"
. "$LIBDIR/deliver.sh"
. "$LIBDIR/cleanup.sh"

# ---- hidden entrypoints (worker + test seams) ----------------------------------------

if [ "${1:-}" = "__deliver" ]; then
  [ "${ISO_TRACE:-}" = 1 ] && set -x
  deliver_worker "$2" "$3" "$4" "$5" "$6" "${7:-}"
  exit 0
fi

if [ "${1:-}" = "__candidate-set" ]; then transcript_candidate_set "$2" "$3"; exit 0; fi
if [ "${1:-}" = "__diff-new" ]; then transcript_diff_new "$2" "$3" "$4"; exit 0; fi
if [ "${1:-}" = "__write-meta" ]; then transcript_write_meta "$2" "$3" "$4" "$5" "$6"; exit 0; fi

# ---- usage -------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: spawn.sh <verb> [options]

Verbs:
  spawn   <codex|claude> [opts]   launch an agent (default when bare codex|claude is given)
  deliver <codex|claude> [opts]   spawn + wait + recover output; requires --prompt
  send    <TERM> <text> [--kill]  send text to a live agent's pane
  recover <TERM> [opts]           read output|chat from the agent's transcript
  status  <TERM> [--kill]         print agent status (idle|working|blocked|unknown)
  cleanup (<TERM> [--kill] | --orphaned)  remove sidecars / kill tabs

spawn / deliver options:
  --prompt TEXT   inject + auto-run on boot (delivered async for spawn, sync for deliver)
  --cwd PATH      working dir (default: caller's pane cwd)
  --label TEXT    tab label (default: agent type)
  --name TEXT     name base; auto-suffixed (codex, codex-2, ...) if taken
  --safe          disable full permissions
  --split DIR     right|down: split current tab instead of a new tab
  --focus         switch focus to the new tab
  --wait          (spawn) block until idle, then report status
  --recover [output|chat]  (spawn --wait) print recovered output after idle
  --what output|chat       (deliver) what to recover (default output)
  --kill          (deliver) close the tab after capture
  --json          machine-readable stdout; suppress normal human banners

recover options:
  --session-file F    bypass mapping (tests / power users)
  --agent codex|claude
  --what output|chat
  --format text|json
  --settle           re-read until recovered output stops growing
  --kill              close the tab after recovery
EOF
}

spawn_json_result() { # env: fields below; optional ISO_JSON_RESULT
  python3 - <<'PY'
import json, os

data = {
    "term": os.environ.get("ISO_JSON_TERM", ""),
    "pane": os.environ.get("ISO_JSON_PANE", ""),
    "tab": os.environ.get("ISO_JSON_TAB", ""),
    "agent": os.environ.get("ISO_JSON_AGENT", ""),
    "name": os.environ.get("ISO_JSON_NAME", ""),
    "cwd": os.environ.get("ISO_JSON_CWD", ""),
    "spawn_file": os.environ.get("ISO_JSON_SPAWN_FILE", ""),
}
status = os.environ.get("ISO_JSON_STATUS", "")
if status:
    data["status"] = status
if "ISO_JSON_RESULT" in os.environ:
    data["result"] = os.environ["ISO_JSON_RESULT"]
print(json.dumps(data, separators=(",", ":")))
PY
}

# ---- dispatcher --------------------------------------------------------------

[ $# -ge 1 ] || { usage; exit 1; }
VERB="$1"
case "$VERB" in
  codex|claude) VERB="spawn" ;;            # bare alias: spawn.sh codex … == spawn.sh spawn codex …
  spawn|deliver|send|recover|status|cleanup) shift ;;
  *) echo "error: unknown command $VERB" >&2; usage; exit 1 ;;
esac

# ---- send --------------------------------------------------------------------

case "$VERB" in
  send)
    RTERM="${1:-}"; shift || true; TEXT="${1:-}"; shift || true; KILL=0
    [ "${1:-}" = "--kill" ] && KILL=1
    [ -n "$RTERM" ] && [ -n "$TEXT" ] || { echo "error: send <TERM> <text>" >&2; exit 1; }
    PANE=$(herdr_pane_for "$RTERM"); [ -n "$PANE" ] || { echo "error: agent $RTERM has no live pane" >&2; exit 1; }
    herdr_pane_run "$PANE" "$TEXT"; echo "sent to $RTERM"
    [ "$KILL" = 1 ] && cleanup_kill_agent "$RTERM"
    exit 0 ;;

  # ---- status ----------------------------------------------------------------
  status)
    RTERM="${1:-}"; shift || true; KILL=0; [ "${1:-}" = "--kill" ] && KILL=1
    [ -n "$RTERM" ] || { echo "error: status <TERM>" >&2; exit 1; }
    herdr_agent_status "$RTERM"
    [ "$KILL" = 1 ] && cleanup_kill_agent "$RTERM"
    exit 0 ;;

  # ---- cleanup ---------------------------------------------------------------
  cleanup)
    if [ "${1:-}" = "--orphaned" ]; then cleanup_orphaned; echo "orphaned sidecars pruned"; exit 0; fi
    RTERM="${1:-}"; shift || true; [ -n "$RTERM" ] || { echo "error: cleanup <TERM>|--orphaned" >&2; exit 1; }
    if [ "${1:-}" = "--kill" ]; then cleanup_kill_agent "$RTERM"; echo "killed $RTERM"
    else cleanup_rm_sidecar "$RTERM"; echo "sidecar removed for $RTERM"; fi
    exit 0 ;;
esac

# ---- recover -----------------------------------------------------------------

if [ "$VERB" = recover ]; then
  RTERM="${1:-}"; [ $# -ge 1 ] && shift || true
  RSESS=""; RAGENT=""; RWHAT="output"; RFMT="text"; RKILL=0; RSETTLE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-file) RSESS="$2"; shift 2;;
      --agent) RAGENT="$2"; shift 2;;
      --what) RWHAT="$2"; shift 2;;
      --format) RFMT="$2"; shift 2;;
      --settle) RSETTLE=1; shift;;
      --kill) RKILL=1; shift;;
      *) echo "error: unknown recover option $1" >&2; exit 1;;
    esac
  done
  case "$RWHAT" in output|chat) ;; *) echo "error: --what must be output|chat" >&2; exit 1;; esac
  case "$RFMT" in text|json) ;; *) echo "error: --format must be text|json" >&2; exit 1;; esac
  if [ -z "$RSESS" ]; then
    [ -n "$RTERM" ] || { echo "error: recover needs <TERM> or --session-file" >&2; exit 1; }
    RST=$(herdr_agent_status "$RTERM")
    [ "$RST" = working ] && echo "warning: agent $RTERM is still working; output may be partial" >&2
    SF=$(transcript_sidecar_for "$RTERM")
    if [ -n "$SF" ]; then
      RAGENT=$(transcript_meta_get "$SF" agent)
      RAGENT=$(agentkind_normalize "$RAGENT")
      RSESS=$(transcript_meta_get "$SF" session_file)
      M_CWD=$(transcript_meta_get "$SF" cwd)
      M_PRE=$(transcript_meta_get_all "$SF" pre)
      if [ -z "$RSESS" ] || [ ! -f "$RSESS" ]; then RSESS=$(transcript_diff_new "$RAGENT" "$M_CWD" "$M_PRE"); fi
      if [ -z "$RSESS" ] || [ ! -f "$RSESS" ]; then
        RSESS=$(transcript_candidate_set "$RAGENT" "$M_CWD" | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"; done | sort -rn | head -1 | cut -f2-)
      fi
    fi
    if [ -z "$RSESS" ] || [ ! -f "$RSESS" ]; then
      echo "# source: scrollback (jsonl unmapped; may be truncated)"
      herdr_scrollback "$RTERM"
      [ "$RKILL" = 1 ] && cleanup_kill_agent "$RTERM"
      exit 0
    fi
  fi
  [ -n "$RAGENT" ] || { echo "error: --agent required (could not infer)" >&2; exit 1; }
  if [ "$RSETTLE" = 1 ]; then
    WAIT_RECOVER_SESSION_FILE="$RSESS" WAIT_RECOVER_AGENT="$RAGENT" WAIT_RECOVER_FORMAT="$RFMT" \
      wait_recover_settled "${RTERM:-term_SETTLE}" --what "$RWHAT"
    [ "$RKILL" = 1 ] && [ -n "$RTERM" ] && cleanup_kill_agent "$RTERM"
    exit 0
  fi
  rc=0
  python3 "$SELFDIR/recover.py" "$RAGENT" "$RWHAT" "$RSESS" "$RFMT" || rc=$?
  [ "$RKILL" = 1 ] && cleanup_kill_agent "$RTERM"
  exit $rc
fi

# ---- spawn / deliver (shared spawn flow) -------------------------------------

[ $# -ge 1 ] || { usage; exit 1; }
TYPE="$1"; shift
case "$TYPE" in codex|claude) ;; *) echo "error: type must be codex or claude" >&2; exit 1;; esac

CWD=""; LABEL=""; NAMEBASE=""; PROMPT=""; FULL=1; SPLIT=""; FOCUS="--no-focus"; JSON=0
WAIT=0; WAIT_MS=600000; RECOVER_WHAT=""; KILL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) PROMPT="$2"; shift 2;;
    --cwd) CWD="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --name) NAMEBASE="$2"; shift 2;;
    --safe) FULL=0; shift;;
    --split) SPLIT="$2"; shift 2;;
    --focus) FOCUS="--focus"; shift;;
    --wait) WAIT=1; shift;;
    --recover) case "${2:-}" in output|chat) RECOVER_WHAT="$2"; shift 2;; *) RECOVER_WHAT=output; shift;; esac;;
    --what) RECOVER_WHAT="${2:-output}"; shift 2;;
    --kill) KILL=1; shift;;
    --json) JSON=1; shift;;
    *) echo "error: unknown option $1" >&2; usage; exit 1;;
  esac
done
# deliver always waits
[ "$VERB" = deliver ] && WAIT=1
[ "$VERB" = deliver ] && [ -z "$RECOVER_WHAT" ] && RECOVER_WHAT=output
LABEL="${LABEL:-$TYPE}"; NAMEBASE="${NAMEBASE:-$TYPE}"

# 1. Resolve the caller's pane -> workspace (focus-proof anchor) AND its cwd (default working dir).
CTX=$(herdr_caller_context) || { echo "error: \$HERDR_PANE_ID unset or unresolvable — run inside a herdr pane" >&2; exit 1; }
WS=${CTX%%$'\t'*}; CALLER_CWD=${CTX#*$'\t'}
[ -n "$CWD" ] || CWD="$CALLER_CWD"
export WS

# 2. Full-permissions preflight (non-fatal).
if [ "$FULL" = 1 ] && [ "$JSON" = 0 ]; then
  echo "note: full permissions on — if blocked by the auto-mode classifier, turn auto-mode OFF (allowlisting alone won't pass it), or use --safe" >&2
fi

# 3. Pick a free, deterministic agent name (server-global): base, base-2, base-3, ...
TAKEN=$(herdr_agent_names)
NAME="$NAMEBASE"; n=2
while printf '%s\n' "$TAKEN" | grep -qx "$NAME"; do NAME="${NAMEBASE}-$n"; n=$((n+1)); done

# 4. Agent argv (full permissions ON unless --safe).
ARGV=("$TYPE")
[ "$FULL" = 1 ] && ARGV+=("$(agentkind_perm_argv "$TYPE")")

# 5. Place the agent.
ROOT=""; TAB=""
if [ -n "$SPLIT" ]; then
  START_ARGS=(agent start "$NAME" --workspace "$WS" --split "$SPLIT" "$FOCUS")
else
  TC=$(herdr tab create --workspace "$WS" --label "$LABEL" "$FOCUS" ${CWD:+--cwd "$CWD"} 2>&1)
  TAB=$(printf '%s' "$TC" | herdr_jget '["result"]["tab"]["tab_id"]') || { echo "error: tab create failed" >&2; exit 1; }
  ROOT=$(printf '%s' "$TC" | herdr_jget '["result"]["root_pane"]["pane_id"]')
  START_ARGS=(agent start "$NAME" --tab "$TAB" "$FOCUS")
fi
[ -n "$CWD" ] && START_ARGS+=(--cwd "$CWD")
START_ARGS+=(-- "${ARGV[@]}")
# Snapshot the candidate transcript set BEFORE the agent starts (race-free mapping).
PRE_SNAPSHOT=$(transcript_candidate_set "$TYPE" "$CWD")
SR=$(herdr "${START_ARGS[@]}" 2>&1) \
  || { echo "error: agent start failed: $SR" >&2; [ -n "$TAB" ] && herdr tab close "$TAB" >/dev/null 2>&1; exit 1; }
ATERM=$(printf '%s' "$SR" | herdr_jget '["result"]["agent"]["terminal_id"]') \
  || { echo "error: agent start returned no terminal" >&2; [ -n "$TAB" ] && herdr tab close "$TAB" >/dev/null 2>&1; exit 1; }
PANE0=$(printf '%s' "$SR" | herdr_jget '["result"]["agent"]["pane_id"]' 2>/dev/null || true)

# 6. Collapse root shell; resolve agent pane once.
if [ -z "$SPLIT" ] && [ -n "$ROOT" ]; then herdr pane close "$ROOT" >/dev/null 2>&1; sleep 1; fi
PANE=$(herdr agent get "$ATERM" 2>/dev/null | herdr_jget '["result"]["agent"]["pane_id"]' 2>/dev/null || true)
if [ -z "$PANE" ] && [ -n "$TAB" ]; then
  PANE=$(herdr pane list --workspace "$WS" 2>/dev/null | python3 -c 'import json,sys
tab=sys.argv[1]; ps=[p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"] if p["tab_id"]==tab]
print(ps[0] if ps else "")' "$TAB" 2>/dev/null || true)
fi
[ -n "$PANE" ] || PANE="$PANE0"

[ "$JSON" = 1 ] || echo "spawned: $NAME  type=$TYPE  ws=$WS  cwd=$CWD  tab=${TAB:-split:$SPLIT}  term=$ATERM  pane=$PANE  full=$FULL" >&2

# 7. Sidecar: write meta.
LOGDIR="${TMPDIR:-/tmp}"
if [ -n "$CWD" ] && mkdir -p "$CWD/.iso/logs/spawn" 2>/dev/null; then LOGDIR="$CWD/.iso/logs/spawn"; fi
AGENTLABEL=$(agentkind_label "$TYPE")
SPAWNFILE="$LOGDIR/$(date +%Y%m%d-%H%M%S)__${AGENTLABEL}__${NAME}__${ATERM}.spawn"
transcript_record_logdir "$LOGDIR"
transcript_write_meta "$SPAWNFILE" "$ATERM" "$TYPE" "$CWD" "$PRE_SNAPSHOT"
[ "$JSON" = 1 ] || echo "spawn-file: $SPAWNFILE" >&2

# 8. Delivery.
if [ "$WAIT" = 1 ]; then
  "$SELF" __deliver "$ATERM" "$PANE" 1 "$WAIT_MS" "$PROMPT" "$SPAWNFILE"
  st=$(herdr_agent_status "$ATERM")
  [ "$JSON" = 1 ] || echo "status: $st" >&2
  if [ "$VERB" = deliver ] || [ -n "$RECOVER_WHAT" ]; then
    [ "$JSON" = 1 ] || echo "--- recovered (${RECOVER_WHAT:-output}) ---" >&2
    RECOVER_STATUS=0
    RESULT=$("$SELF" recover "$ATERM" --what "${RECOVER_WHAT:-output}") || RECOVER_STATUS=$?
    if [ "$JSON" = 1 ]; then
      ISO_JSON_TERM="$ATERM" ISO_JSON_PANE="$PANE" ISO_JSON_TAB="${TAB:-}" ISO_JSON_AGENT="$TYPE" \
        ISO_JSON_NAME="$NAME" ISO_JSON_CWD="$CWD" ISO_JSON_SPAWN_FILE="$SPAWNFILE" \
        ISO_JSON_STATUS="$st" ISO_JSON_RESULT="$RESULT" spawn_json_result
    else
      printf '%s\n' "$RESULT"
    fi
    if [ "$JSON" = 0 ] && [ "$VERB" = deliver ] && [ -z "$(printf '%s' "$RESULT" | tr -d '[:space:]')" ]; then
      echo "warning: deliver got an empty result from $ATERM" >&2
    fi
    [ "$KILL" = 1 ] && cleanup_kill_agent "$ATERM"
    [ "$RECOVER_STATUS" = 0 ] || exit "$RECOVER_STATUS"
  else
    if [ "$JSON" = 1 ]; then
      ISO_JSON_TERM="$ATERM" ISO_JSON_PANE="$PANE" ISO_JSON_TAB="${TAB:-}" ISO_JSON_AGENT="$TYPE" \
        ISO_JSON_NAME="$NAME" ISO_JSON_CWD="$CWD" ISO_JSON_SPAWN_FILE="$SPAWNFILE" \
        ISO_JSON_STATUS="$st" spawn_json_result
    else
      printf '%s\n' "$ATERM"
    fi
  fi
else
  ISO_TRACE=1 nohup "$SELF" __deliver "$ATERM" "$PANE" 0 "$WAIT_MS" "$PROMPT" "$SPAWNFILE" >>"$SPAWNFILE" 2>&1 &
  disown 2>/dev/null || true
  if [ "$JSON" = 1 ]; then
    ISO_JSON_TERM="$ATERM" ISO_JSON_PANE="$PANE" ISO_JSON_TAB="${TAB:-}" ISO_JSON_AGENT="$TYPE" \
      ISO_JSON_NAME="$NAME" ISO_JSON_CWD="$CWD" ISO_JSON_SPAWN_FILE="$SPAWNFILE" \
      ISO_JSON_STATUS="launched" spawn_json_result
  else
    [ -n "$PROMPT" ] && echo "delivering prompt in background — monitor: herdr agent get $ATERM  |  sidecar: $SPAWNFILE" >&2
    printf '%s\n' "$ATERM"
  fi
fi
[ "$JSON" = 1 ] || echo "done" >&2

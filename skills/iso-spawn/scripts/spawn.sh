#!/usr/bin/env bash
# iso-spawn: launch a codex or claude agent in its OWN herdr tab, in the workspace the caller lives in.
# Defaults: full permissions ON, cwd = caller's pane cwd, stays in background (no focus steal),
# prompt injected + auto-run, delivery happens async so the caller never freezes on slow boot.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

jget() { python3 -c 'import json,sys,re
d=json.load(sys.stdin); cur=d
for k in re.findall(r"\[(?:\"([^\"]+)\"|(\d+))\]", sys.argv[1]): cur=cur[k[0] if k[0] else int(k[1])]
print(cur)' "$1"; }

# ---- internal delivery mode: __deliver <term> <pane> <wait> <wait_ms> <prompt> ----
# One unified poll loop: clear a trust modal, inject the prompt once the agent is ready, and
# confirm acceptance via status OR the screen — re-injecting only if the prompt was truly lost.
# The pane is resolved by the parent and passed in (stable after root-collapse), so the worker
# makes one `pane read` per tick and never re-lists. ISO_TRACE=1 enables an xtrace log.
if [ "${1:-}" = "__deliver" ]; then
  [ "${ISO_TRACE:-}" = 1 ] && set -x
  TERM="$2"; PANE="$3"; WAIT="$4"; WAIT_MS="$5"; PROMPT="$6"
  status() { herdr agent get "$TERM" 2>/dev/null | jget '["result"]["agent"]["agent_status"]' 2>/dev/null || echo unknown; }
  # classify the prompt against the live screen: submitted | pending | none
  #   pending   = prompt sits in the trailing ›/❯ input line (Enter was eaten) -> resend Enter
  #   submitted = prompt appears on a committed line above the input -> accepted
  classify() { python3 -c 'import sys
scr=sys.stdin.read(); p=sys.argv[1].strip()
if not p: print("none"); sys.exit()
lines=[l for l in scr.splitlines() if l.strip()]
inp=next((l for l in reversed(lines) if l.lstrip().startswith(("›","❯"))), "")
body=inp.lstrip().lstrip("›❯").strip()
print("pending" if p in body else ("submitted" if p in scr else "none"))' "$PROMPT"; }

  READY='/model to change|permissions: YOLO|esc to interrupt|bypass permissions|for shortcuts|for agents|Claude Code v|OpenAI Codex|Improve documentation'
  injected=0
  for _ in $(seq 1 40); do
    S=$(herdr pane read "$PANE" --source visible --lines 40 2>/dev/null || true)
    # 1. trust modals take priority — one keypress, re-loop
    if   printf '%s' "$S" | grep -qiE 'Trust all and continue';          then herdr pane send-keys "$PANE" Down Enter >/dev/null 2>&1 || true; sleep 1; continue
    elif printf '%s' "$S" | grep -qiE 'Press t to trust|trust all hooks'; then herdr pane send-keys "$PANE" t          >/dev/null 2>&1 || true; sleep 1; continue
    elif printf '%s' "$S" | grep -qiE 'Do you trust the files|trust this folder|project you created or one you trust'; then herdr pane send-keys "$PANE" Enter >/dev/null 2>&1 || true; sleep 1; continue; fi
    [ -n "$PROMPT" ] || break                                            # no prompt: modal cleared, done
    C=$(classify <<<"$S")
    # 2. after injecting, confirm acceptance. status is boot-noise BEFORE the inject (claude emits
    #    working/done from MCP-load + SessionStart hooks), so it only counts once injected=1.
    if [ "$injected" = 1 ]; then
      case "$(status)" in working|done|blocked) break;; esac
      [ "$C" = submitted ] && break                                      # prompt committed on screen
      if [ "$C" = pending ]; then herdr pane send-keys "$PANE" Enter >/dev/null 2>&1 || true; sleep 1; continue; fi
      # C=none after inject -> prompt was lost; fall through and re-inject
    fi
    # 3. inject once the input box is painted and empty
    if [ "$C" = pending ]; then herdr pane send-keys "$PANE" Enter >/dev/null 2>&1 || true; sleep 1
    elif printf '%s' "$S" | grep -qiE "$READY"; then herdr pane run "$PANE" "$PROMPT" >/dev/null 2>&1 || true; injected=1; sleep 2
    else sleep 1; fi                                                     # still booting -> wait
  done
  [ "$WAIT" = 1 ] && herdr agent wait "$TERM" --status idle --timeout "$WAIT_MS" >/dev/null 2>&1 || true
  exit 0
fi

usage() {
  cat <<'EOF'
Usage: spawn.sh <codex|claude> [options]
  --prompt TEXT   inject + auto-run; agent starts working as soon as it boots (delivered async)
  --cwd PATH      working dir (default: the CALLER's pane cwd)
  --label TEXT    tab label (default: agent type)
  --name TEXT     name base; auto-suffixed (codex, codex-2, ...) if taken
  --safe          DISABLE full permissions (default ON: codex YOLO / claude skip-permissions)
  --split DIR     right|down: split current tab instead of a new tab
  --focus         switch focus to the new tab (default: stay in current pane)
  --wait          run synchronously: block until the agent finishes the prompt (status idle), report status
EOF
}

[ $# -ge 1 ] || { usage; exit 1; }
TYPE="$1"; shift
case "$TYPE" in codex|claude) ;; *) echo "error: type must be codex or claude" >&2; exit 1;; esac

CWD=""; LABEL=""; NAMEBASE=""; PROMPT=""; FULL=1; SPLIT=""; FOCUS="--no-focus"; WAIT=0; WAIT_MS=600000
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
    *) echo "error: unknown option $1" >&2; usage; exit 1;;
  esac
done
LABEL="${LABEL:-$TYPE}"; NAMEBASE="${NAMEBASE:-$TYPE}"

# 1. Resolve the caller's pane -> workspace (focus-proof anchor) AND its cwd (default working dir).
[ -n "${HERDR_PANE_ID:-}" ] || { echo "error: \$HERDR_PANE_ID unset — run inside a herdr pane" >&2; exit 1; }
PINFO=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null) || { echo "error: cannot resolve calling pane" >&2; exit 1; }
WS=$(printf '%s' "$PINFO" | jget '["result"]["pane"]["workspace_id"]')
[ -n "$CWD" ] || CWD=$(printf '%s' "$PINFO" | jget '["result"]["pane"]["cwd"]' 2>/dev/null || true)
export WS

# 2. Full-permissions preflight (non-fatal): the auto-mode safety classifier blocks --dangerously-*
# spawns regardless of any allowlist, so the real unblock is turning auto-mode OFF.
if [ "$FULL" = 1 ]; then
  echo "note: full permissions on — if blocked by the auto-mode classifier, turn auto-mode OFF (allowlisting alone won't pass it), or use --safe"
fi

# 3. Pick a free, deterministic agent name (server-global): base, base-2, base-3, ...
TAKEN=$(herdr agent list 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join((a.get("name") or a.get("agent") or "") for a in json.load(sys.stdin)["result"]["agents"]))
except Exception: pass' || true)
NAME="$NAMEBASE"; n=2
while printf '%s\n' "$TAKEN" | grep -qx "$NAME"; do NAME="${NAMEBASE}-$n"; n=$((n+1)); done

# 4. Agent argv (full permissions ON unless --safe).
ARGV=("$TYPE")
if [ "$FULL" = 1 ]; then
  [ "$TYPE" = codex ]  && ARGV+=(--dangerously-bypass-approvals-and-sandbox)
  [ "$TYPE" = claude ] && ARGV+=(--dangerously-skip-permissions)
fi

# 5. Place the agent. --split splits the current tab; otherwise a new tab (root shell collapsed after).
ROOT=""; TAB=""
if [ -n "$SPLIT" ]; then
  START_ARGS=(agent start "$NAME" --workspace "$WS" --split "$SPLIT" "$FOCUS")
else
  TC=$(herdr tab create --workspace "$WS" --label "$LABEL" "$FOCUS" ${CWD:+--cwd "$CWD"} 2>&1)
  TAB=$(printf '%s' "$TC" | jget '["result"]["tab"]["tab_id"]') || { echo "error: tab create failed" >&2; exit 1; }
  ROOT=$(printf '%s' "$TC" | jget '["result"]["root_pane"]["pane_id"]')
  START_ARGS=(agent start "$NAME" --tab "$TAB" "$FOCUS")
fi
[ -n "$CWD" ] && START_ARGS+=(--cwd "$CWD")
START_ARGS+=(-- "${ARGV[@]}")
SR=$(herdr "${START_ARGS[@]}" 2>&1) \
  || { echo "error: agent start failed: $SR" >&2; [ -n "$TAB" ] && herdr tab close "$TAB" >/dev/null 2>&1; exit 1; }
TERM=$(printf '%s' "$SR" | jget '["result"]["agent"]["terminal_id"]') \
  || { echo "error: agent start returned no terminal" >&2; [ -n "$TAB" ] && herdr tab close "$TAB" >/dev/null 2>&1; exit 1; }
PANE0=$(printf '%s' "$SR" | jget '["result"]["agent"]["pane_id"]' 2>/dev/null || true)

# 6. New-tab mode: collapse the leftover root shell so the tab holds ONLY the agent (pane ids renumber),
# then resolve the agent's pane ONCE so the worker never has to re-list.
if [ -z "$SPLIT" ] && [ -n "$ROOT" ]; then herdr pane close "$ROOT" >/dev/null 2>&1; sleep 1; fi
PANE=$(herdr agent get "$TERM" 2>/dev/null | jget '["result"]["agent"]["pane_id"]' 2>/dev/null || true)
if [ -z "$PANE" ] && [ -n "$TAB" ]; then
  PANE=$(herdr pane list --workspace "$WS" 2>/dev/null | python3 -c 'import json,sys
tab=sys.argv[1]; ps=[p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"] if p["tab_id"]==tab]
print(ps[0] if ps else "")' "$TAB" 2>/dev/null || true)
fi
[ -n "$PANE" ] || PANE="$PANE0"

echo "spawned: $NAME  type=$TYPE  ws=$WS  cwd=$CWD  tab=${TAB:-split:$SPLIT}  term=$TERM  pane=$PANE  full=$FULL"

# 7. Delivery. --wait => synchronous (block, report final status). default => detached, logged worker.
if [ "$WAIT" = 1 ]; then
  "$SELF" __deliver "$TERM" "$PANE" 1 "$WAIT_MS" "$PROMPT"
  st=$(herdr agent get "$TERM" 2>/dev/null | jget '["result"]["agent"]["agent_status"]' 2>/dev/null || echo unknown)
  echo "status: $st"
else
  # log the detached worker so a silently-lost prompt is one `cat` to diagnose; root under the
  # target cwd (.iso/logs/spawn) to match the .iso/ convention, fall back to a temp dir.
  # filename: <date>__<agent>__<name>__<term>.log  (agent = codex | claude-code)
  LOGDIR="${TMPDIR:-/tmp}"
  if [ -n "$CWD" ] && mkdir -p "$CWD/.iso/logs/spawn" 2>/dev/null; then LOGDIR="$CWD/.iso/logs/spawn"; fi
  [ "$TYPE" = claude ] && AGENTLABEL=claude-code || AGENTLABEL=codex
  LOGFILE="$LOGDIR/$(date +%Y%m%d-%H%M%S)__${AGENTLABEL}__${NAME}__${TERM}.log"
  ISO_TRACE=1 nohup "$SELF" __deliver "$TERM" "$PANE" 0 "$WAIT_MS" "$PROMPT" >"$LOGFILE" 2>&1 &
  disown 2>/dev/null || true
  [ -n "$PROMPT" ] && echo "delivering prompt in background — monitor: herdr agent get $TERM  |  log: $LOGFILE"
fi
echo "done"

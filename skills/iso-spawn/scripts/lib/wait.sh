#!/usr/bin/env bash
# wait.sh — shared lifecycle waits for spawned herdr agents. Assumes herdr.sh is sourced.

wait_recover_once() { # $1=term [--what output|chat]
  local term="$1" what="output"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --what) what="$2"; shift 2;;
      *) shift;;
    esac
  done
  local spawn="${SPAWN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/spawn.sh}"
  local args=(recover "$term" --what "$what")
  [ -n "${WAIT_RECOVER_SESSION_FILE:-}" ] && args+=(--session-file "$WAIT_RECOVER_SESSION_FILE")
  [ -n "${WAIT_RECOVER_AGENT:-}" ] && args+=(--agent "$WAIT_RECOVER_AGENT")
  [ -n "${WAIT_RECOVER_FORMAT:-}" ] && args+=(--format "$WAIT_RECOVER_FORMAT")
  "$spawn" "${args[@]}"
}

wait_recover_settled() { # $1=term [--what output|chat]
  local term="$1" what="output"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --what) what="$2"; shift 2;;
      *) shift;;
    esac
  done

  local polls="${WAIT_SETTLE_POLLS:-2}" sleep_s="${WAIT_SETTLE_SLEEP:-2}" max="${WAIT_SETTLE_MAX:-15}"
  local cur="" last="" len last_len=-1 stable=0 i need
  need=$(( polls > 1 ? polls - 1 : 1 ))
  for i in $(seq 1 "$max"); do
    cur=$(wait_recover_once "$term" --what "$what" 2>/dev/null || true)
    len=${#cur}
    if [ "$len" = "$last_len" ]; then
      stable=$(( stable + 1 ))
      last="$cur"
      [ "$stable" -ge "$need" ] && { printf '%s' "$last"; return 0; }
    else
      stable=0
      last="$cur"
      last_len="$len"
    fi
    [ "$i" -lt "$max" ] && sleep "$sleep_s"
  done
  printf '%s' "$last"
  return 0
}

# Sanitize a --timeout/--escalate argument to a non-negative integer number of SECONDS.
# wait_done's --timeout/--escalate are contractually seconds; any caller holding milliseconds
# (e.g. deliver.sh) converts at its own boundary. No unit guessing here — a large seconds value
# (e.g. 14400 for a 4h review) is passed through unchanged instead of being mistaken for ms.
wait_seconds() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) printf '0'; return 0;; esac
  printf '%s' "$n"
}

wait_done() { # $1=term [--timeout S|MS] [--done-grep REGEX] [--escalate S] [--dead N]
  local term="$1" timeout="${WAIT_DONE_TIMEOUT:-600}" done_grep="" escalate="" dead_limit="${WAIT_DONE_DEAD:-18}"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2;;
      --done-grep) done_grep="$2"; shift 2;;
      --escalate) escalate="$2"; shift 2;;
      --dead) dead_limit="$2"; shift 2;;
      *) shift;;
    esac
  done

  timeout=$(wait_seconds "$timeout")
  if [ -z "$escalate" ]; then
    escalate=$(( timeout / 2 ))
    [ "$escalate" -gt 300 ] && escalate=300
  else
    escalate=$(wait_seconds "$escalate")
  fi

  local poll="${WAIT_DONE_POLL:-2}" step="${WAIT_DONE_STEP:-${WAIT_DONE_POLL:-2}}"
  local fast_idle_need="${WAIT_DONE_FAST_IDLE_POLLS:-2}" grep_idle_need="${WAIT_DONE_GREP_IDLE_POLLS:-15}"
  local elapsed=0 idle=0 dead=0 st cur
  [ "$step" -gt 0 ] 2>/dev/null || step=1
  [ "$poll" -ge 0 ] 2>/dev/null || poll=2

  while [ "$elapsed" -le "$timeout" ]; do
    st=$(herdr_agent_status "$term")
    case "$st" in
      blocked) echo "wait_done: blocked" >&2; return 2;;
    esac

    if [ -n "$done_grep" ]; then
      cur=$(wait_recover_once "$term" --what output 2>/dev/null || true)
      # A scrollback-sourced recover (recover.py couldn't map the jsonl and fell back to raw TUI
      # text, prefixed "# source: scrollback") is not a real transcript: a partial render can show
      # the done-grep tokens before the agent's final turn flushes. Don't let it satisfy the gate —
      # wait for a real mapped transcript so we never return on a truncated review.
      case "$cur" in
        '# source: scrollback'*) ;;
        *)
          if printf '%s' "$cur" | grep -qE -- "$done_grep"; then
            WAIT_SETTLE_SLEEP="${WAIT_SETTLE_SLEEP:-$poll}" wait_recover_settled "$term" --what output >/dev/null
            echo "wait_done: done-grep matched" >&2
            return 0
          fi
          ;;
      esac
    fi

    case "$st" in
      idle|done)
        idle=$(( idle + 1 ))
        if [ -n "$done_grep" ]; then
          [ "$idle" -ge "$grep_idle_need" ] && { echo "wait_done: idle grace elapsed" >&2; return 0; }
        else
          [ "$idle" -ge "$fast_idle_need" ] && { echo "wait_done: idle" >&2; return 0; }
        fi
        ;;
      *)
        idle=0
        if [ "$elapsed" -ge "$escalate" ]; then
          if herdr_pane_active "$term"; then
            dead=0
          else
            dead=$(( dead + 1 ))
            [ "$dead" -ge "$dead_limit" ] && { echo "wait_done: dead" >&2; return 3; }
          fi
        fi
        ;;
    esac

    [ "$poll" -gt 0 ] && sleep "$poll"
    elapsed=$(( elapsed + step ))
  done

  echo "wait_done: timeout" >&2
  return 4
}

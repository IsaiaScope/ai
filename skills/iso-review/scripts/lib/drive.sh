#!/usr/bin/env bash
# iso-review mechanics: preflight, test detection, TUI driving. Sourced by review.sh.

rv_exclude_runtime_logs() {
  local exclude
  exclude=$(git rev-parse --git-path info/exclude 2>/dev/null) || return 0
  mkdir -p "$(dirname "$exclude")"
  grep -qxF '.iso/logs/' "$exclude" 2>/dev/null || printf '\n.iso/logs/\n' >> "$exclude"
}

rv_preflight() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "✗ not a git repo" >&2; return 1; }
  [ -n "${HERDR_PANE_ID:-}" ] || { echo "✗ herdr not reachable (HERDR_PANE_ID unset)" >&2; return 1; }
  rv_exclude_runtime_logs
  [ -n "$(git status --porcelain)" ] || { echo "✗ working tree clean — nothing to review" >&2; return 1; }
  return 0
}

rv_detect_test_cmd() {  # prints a runnable test command, or nothing
  if [ -f package.json ] && grep -Eq '"test"[[:space:]]*:' package.json \
     && ! grep -q 'no test specified' package.json; then echo "npm test"; return 0; fi
  if [ -f Makefile ] && grep -Eq '^test:' Makefile; then echo "make test"; return 0; fi
  if [ -f pytest.ini ]; then echo "pytest"; return 0; fi
  # only when pytest is actually configured, not merely a listed dependency
  if [ -f pyproject.toml ] && grep -q '\[tool\.pytest' pyproject.toml 2>/dev/null; then echo "pytest"; return 0; fi
  return 0  # nothing found: empty output, success
}

SPAWN="${SPAWN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../iso-spawn/scripts" && pwd)/spawn.sh}"

# Scratch + handoff dir (transcripts, accepted-fixes.md, .spawned-terms, stderr). Co-located with iso-spawn's
# logs at .iso/logs/spawn so all iso-* run artifacts live under .iso/logs. Single source of truth.
RV_OUTDIR="${RV_OUTDIR:-.iso/logs/review}"

# Reuse iso-spawn's status reader so iso-review and iso-spawn agree on agent states (incl. `done`).
ISO_SPAWN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../iso-spawn/scripts/lib" 2>/dev/null && pwd)"
# shellcheck source=../../../iso-spawn/scripts/lib/herdr.sh
# shellcheck disable=SC1091
[ -n "$ISO_SPAWN_LIB" ] && [ -f "$ISO_SPAWN_LIB/herdr.sh" ] && . "$ISO_SPAWN_LIB/herdr.sh"
# shellcheck source=../../../iso-spawn/scripts/lib/wait.sh
# shellcheck disable=SC1091
[ -n "$ISO_SPAWN_LIB" ] && [ -f "$ISO_SPAWN_LIB/wait.sh" ] && . "$ISO_SPAWN_LIB/wait.sh"

# shellcheck source=reviewer-codex.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/reviewer-codex.sh"
# shellcheck source=reviewer-claude.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/reviewer-claude.sh"

RV_FINDINGS_GREP='```json|"findings"|"summary"|"failure_scenario"'

# Best-effort tab teardown via iso-spawn's `cleanup --kill` (closes the tab AND drops the sidecar).
# Called only after the agent's output has already been persisted to disk, so a kill reclaims the
# process — it never loses anything the caller still needs to read. Empty term / dead tab → no-op.
rv_kill_term() {  # $1=term
  [ -n "${1:-}" ] || return 0
  "$SPAWN" cleanup "$1" --kill >/dev/null 2>&1 || true
}

rv_wait_ready() {  # $1=pane  — wait until an agent input box is present
  local p="$1"
  for _ in $(seq 1 40); do
    herdr_pane_read "$p" 30 | grep -qE '›|❯|esc to interrupt|for shortcuts' && return 0
    sleep 1
  done
  return 1
}

# Consume iso-spawn's machine launch result; no human-banner parsing.
rv_spawn() {  # $1=agent  $2=label  $3=name  → echoes "TERM PANE"
  local out term pane
  out=$("$SPAWN" spawn "$1" --label "$2" --name "$3" --json)
  term=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("term",""))' 2>/dev/null || true)
  pane=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pane",""))' 2>/dev/null || true)
  [ -n "$pane" ] || { echo "✗ spawn json parse failed for $1:" >&2; printf '%s\n' "$out" >&2; return 1; }
  echo "$term $pane"
}

# A recover that couldn't map the jsonl prints a "# source: scrollback" notice + raw scrollback
# and still exits 0. That's not a real transcript — demote it to the recover-failed sentinel so
# the extract step doesn't treat truncated TUI text as a genuine (empty) review.
rv_demote_scrollback() {  # $1 = recovered file
  head -1 "$1" 2>/dev/null | grep -q '# source: scrollback' && echo "__RECOVER_FAILED__" > "$1"
  return 0
}

rv_reviews() {  # [--codex-only] [--claude-review-effort high|max | high|max] [--kill-review-tabs|--kill-tabs]. Wipes $RV_OUTDIR, writes fresh review-{codex,claude}.txt; prints paths.
  local level="high" kill_tabs=0 codex_only=0 outdir="$RV_OUTDIR"
  while [ $# -gt 0 ]; do
    case "$1" in
      --codex-only) codex_only=1; shift;;
      --kill-review-tabs|--kill-tabs) kill_tabs=1; shift;;
      --claude-review-effort=*) level="${1#*=}"; shift;;
      --claude-review-effort) shift; level="${1:-high}"; [ $# -gt 0 ] && shift;;
      high|max) level="$1"; shift;;       # positional shorthand (--max maps here)
      *) shift;;
    esac
  done
  case "$level" in
    high|max) ;;
    *) echo "✗ unknown claude review effort: $level (use high|max)" >&2; return 1;;
  esac
  # Fresh start each run: a prior review's accepted-fixes.md/.spawned-terms/transcripts must never leak into
  # this one (e.g. a stale accepted-fixes.md getting re-applied). The `:?` guard refuses an empty/unset path.
  rm -rf -- "${outdir:?refusing to wipe empty RV_OUTDIR}"
  mkdir -p -- "$outdir"
  local cTERM cPANE lTERM lPANE sp
  sp=$(rv_spawn codex  iso-review-codex  irvcodex)  || return 1; read -r cTERM cPANE <<<"$sp"
  printf '%s\n' "$cTERM" > "$outdir/.spawned-terms"   # record now so a failed claude spawn still leaves codex reapable
  if [ "$codex_only" = 0 ]; then
    sp=$(rv_spawn claude iso-review-claude irvclaude) || return 1; read -r lTERM lPANE <<<"$sp"
  fi
  # drive both (quick keystrokes; the long review work then overlaps)
  local cFAIL=0 lFAIL=0
  if ! { rv_wait_ready "$cPANE" && reviewer_codex_dispatch  "$cPANE" "$level"; }; then
    echo "codex review dispatch failed" >&2; cFAIL=1
  fi
  if [ "$codex_only" = 0 ] && ! { rv_wait_ready "$lPANE" && reviewer_claude_dispatch "$lPANE" "$level"; }; then
    echo "claude review dispatch failed" >&2; lFAIL=1
  fi
  # Confirm BOTH launched now, while it's unambiguous — both were just dispatched and should turn `working`
  # within seconds. Doing this here, not after a serial finish-wait, distinguishes a dropped keystroke
  # from an already-finished fast review.
  local reviewer reviewers="codex" term window="${RV_START_WINDOW:-120}" st started
  [ "$codex_only" = 0 ] && reviewers="codex claude"
  for reviewer in $reviewers; do
    case "$reviewer" in
      codex) term="$cTERM"; [ "$cFAIL" = 0 ] || continue;;
      claude) term="$lTERM"; [ "$lFAIL" = 0 ] || continue;;
    esac
    started=0
    for _ in $(seq 1 "$window"); do
      st=$(herdr_agent_status "$term")
      case "$st" in
        working) started=1; break;;
        blocked) echo "✗ agent $term blocked (awaiting approval/permission)" >&2; break;;
      esac
      sleep 1
    done
    if [ "$started" = 0 ]; then
      echo "$reviewer review never started" >&2
      [ "$reviewer" = codex ] && cFAIL=1 || lFAIL=1
    fi
  done
  # Then wait both to truly finish (idle/done, or a quiescent transcript behind a stuck `working` status).
  local review_timeout="${RV_REVIEW_TIMEOUT:-3600}"
  [ "$cFAIL" = 0 ] && { wait_done "$cTERM" --timeout "$review_timeout" --done-grep "$RV_FINDINGS_GREP" || { echo "codex review did not finish in time"  >&2; cFAIL=1; }; }
  [ "$codex_only" = 0 ] && [ "$lFAIL" = 0 ] && { wait_done "$lTERM" --timeout "$review_timeout" --done-grep "$RV_FINDINGS_GREP" || { echo "claude review did not finish in time" >&2; lFAIL=1; }; }
  # recover — on dispatch failure write a sentinel so 'failed' != 'no findings'; otherwise settle-recover
  # to ride out the jsonl flush-lag (status/pane lead the disk write) so we don't grab a pre-final turn.
  if [ "$cFAIL" = 1 ]; then echo "__DISPATCH_FAILED__" > "$outdir/review-codex.txt"
  else wait_recover_settled "$cTERM" > "$outdir/review-codex.txt"; rv_demote_scrollback "$outdir/review-codex.txt"; fi
  if [ "$codex_only" = 1 ]; then : > "$outdir/review-claude.txt"
  elif [ "$lFAIL" = 1 ]; then echo "__DISPATCH_FAILED__" > "$outdir/review-claude.txt"
  else wait_recover_settled "$lTERM" > "$outdir/review-claude.txt"; rv_demote_scrollback "$outdir/review-claude.txt"; fi
  reviewer_codex_normalize "$outdir/review-codex.txt" "$outdir/findings-codex.json"
  reviewer_claude_normalize "$outdir/review-claude.txt" "$outdir/findings-claude.json"
  if [ "$codex_only" = 1 ]; then printf '%s\n' "$cTERM" > "$outdir/.spawned-terms"
  else printf '%s\n%s\n' "$cTERM" "$lTERM" > "$outdir/.spawned-terms"; fi   # for later cleanup
  echo "$outdir/review-codex.txt"; echo "$outdir/review-claude.txt"
  # Systematic teardown (opt-in): both review files are on disk now, so killing the tabs reclaims the
  # processes without losing findings. Default leaves them alive for live inspection.
  if [ "$kill_tabs" = 1 ]; then rv_kill_term "$cTERM"; [ "$codex_only" = 0 ] && rv_kill_term "$lTERM"; fi
  if [ "$cFAIL" = 1 ] && { [ "$codex_only" = 1 ] || [ "$lFAIL" = 1 ]; }; then
    echo "✗ both reviewers failed to dispatch — no review produced" >&2
    return 1
  fi
}

rv_apply() {  # <accepted-fixes.md> [--fix-agent codex|claude] [--fix-term TERM] [--kill-fix-tab|--kill-tabs]
  local f="" kill_fix=0 fix_agent="codex" fix_term=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kill-fix-tab|--kill-tabs) kill_fix=1; shift;;
      --fix-agent=*) fix_agent="${1#*=}"; shift;;
      --fix-agent) shift; fix_agent="${1:-codex}"; [ $# -gt 0 ] && shift;;
      --fix-term=*) fix_term="${1#*=}"; [ -n "$fix_term" ] || { echo "✗ --fix-term requires TERM" >&2; return 1; }; shift;;
      --fix-term) shift; fix_term="${1:-}"; [ -n "$fix_term" ] || { echo "✗ --fix-term requires TERM" >&2; return 1; }; shift;;
      *) [ -z "$f" ] && f="$1"; shift;;
    esac
  done
  : "${f:?usage: review.sh apply <accepted-fixes.md> [--fix-agent codex|claude] [--fix-term TERM] [--kill-fix-tab]}"
  # The fix tab is agent-agnostic (plain instruction list, not a slash-command), so codex or claude
  # can drive it. Normalize friendly aliases; reject anything iso-spawn can't launch.
  case "$fix_agent" in
    codex) ;;
    claude|claude-code|claudecode|cloudcode|cc) fix_agent="claude";;
    "") fix_agent="codex";;
    *) echo "✗ unknown fix agent: $fix_agent (use codex|claude)" >&2; return 1;;
  esac
  [ -f "$f" ] || { echo "✗ accepted-fixes file not found: $f" >&2; return 1; }
  # Nothing accepted (whitespace-only) → spawn no fix tab. rc 3 is distinct from the
  # file-not-found rc 1 so callers can tell "no work" apart from "broken input".
  if [ -z "$(tr -d '[:space:]' < "$f")" ]; then
    echo "✗ no accepted fixes — nothing to implement" >&2
    return 3
  fi
  local prompt tcmd test_line
  tcmd=$(rv_detect_test_cmd)
  test_line="run the project's tests and type-checks (whatever this repo uses) and report PASS/FAIL"
  [ -n "$tcmd" ] && test_line="run \`$tcmd\` and the project's type-check, and report PASS/FAIL"
  prompt="Implement the following fixes in the working tree. They were selected from a code review.

$(cat "$f")

Rules:
- Apply exactly these fixes — nothing more. Behavior-preserving except where the fix IS the bug fix.
- No extra refactoring, no opportunistic edits, no reformatting beyond each fix.
- After applying, $test_line.
- Do NOT commit. Leave every change in the working tree for the user to review."
  mkdir -p "$RV_OUTDIR"
  if [ -n "$fix_term" ]; then
    "$SPAWN" send "$fix_term" "$prompt" >/dev/null
    wait_done "$fix_term" --timeout "${RV_FIX_TIMEOUT:-3600}" || {
      local rc=$?
      echo "✗ fix term failed or timed out (wait exit $rc): $fix_term" >&2
      return "$rc"
    }
    "$SPAWN" recover "$fix_term" --what chat | tail -40
    [ "$kill_fix" = 1 ] && rv_kill_term "$fix_term"
    return 0
  fi
  local out rc=0
  # spawn + wait + recover in ONE call. JSON mode is the machine interface: stdout
  # carries both the fix term and recovered report, with no human-banner parsing.
  out=$("$SPAWN" spawn "$fix_agent" --label iso-review-fix --name irvfix --prompt "$prompt" --wait --recover chat --json) || rc=$?
  local fixterm report
  fixterm=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("term",""))' 2>/dev/null || true)
  report=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))' 2>/dev/null || true)
  [ -n "$fixterm" ] && echo "$fixterm" >> "$RV_OUTDIR/.spawned-terms" || true
  printf '%s\n' "$report" | tail -40
  if [ "$rc" -ne 0 ]; then
    echo "✗ fix tab failed (spawn/wait/recover exit $rc)" >&2
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  # Systematic teardown (opt-in): the fix tab's report is captured in $out above, so killing it now
  # only reclaims the process. Default leaves it alive for inspection.
  [ "$kill_fix" = 1 ] && rv_kill_term "$fixterm"
  return 0
}

rv_write_accepted_fixes() {  # $1=outdir — writes accepted-fixes.md; returns 0 if non-empty, 3 if no accepted fixes
  local outdir="$1" accepted
  accepted="$outdir/accepted-fixes.md"
  python3 - "$outdir/findings-codex.json" "$outdir/findings-claude.json" "$accepted" <<'PY'
import json, os, re, sys

codex_path, claude_path, accepted_path = sys.argv[1:4]

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except Exception:
        return []

def norm(value):
    return re.sub(r"\s+", " ", str(value or "").strip().lower())

seen = set()
accepted = []
for item in load(codex_path) + load(claude_path):
    file = str(item.get("file") or "").strip()
    line = int(item.get("line") or 0)
    problem = str(item.get("problem") or "").strip()
    fix = str(item.get("fix") or "").strip()
    if not (file or problem or fix):
        continue
    key = (file, line, norm(problem), norm(fix))
    if key in seen:
        continue
    seen.add(key)
    accepted.append((file, line, problem, fix, str(item.get("source") or "").strip()))

os.makedirs(os.path.dirname(accepted_path) or ".", exist_ok=True)
with open(accepted_path, "w", encoding="utf-8") as f:
    for i, (file, line, problem, fix, source) in enumerate(accepted, 1):
        loc = file
        if line:
            loc = f"{loc}:{line}" if loc else f"line {line}"
        if source:
            loc = f"{loc} ({source})" if loc else f"({source})"
        f.write(f"{i}. {loc or 'Review finding'}\n")
        if problem:
            f.write(f"   Problem: {problem}\n")
        if fix:
            f.write(f"   Fix: {fix}\n")
        f.write("\n")

sys.exit(0 if accepted else 3)
PY
  local rc=$?
  case "$rc" in
    0) return 0;;
    3) : > "$accepted"; return 3;;
    *) return "$rc";;
  esac
}

rv_run() {  # full iso-review path: preflight → reviews → accepted fixes → apply
  local level="high" kill_review=0 kill_fix=0 codex_only=0 fix_agent="codex" fix_term=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --codex-only) codex_only=1; shift;;
      --kill-tabs) kill_review=1; kill_fix=1; shift;;
      --kill-review-tabs) kill_review=1; shift;;
      --kill-fix-tab) kill_fix=1; shift;;
      --max) level="max"; shift;;
      --claude-review-effort=*) level="${1#*=}"; shift;;
      --claude-review-effort) shift; level="${1:-high}"; [ $# -gt 0 ] && shift;;
      --fix-agent=*) fix_agent="${1#*=}"; shift;;
      --fix-agent) shift; fix_agent="${1:-codex}"; [ $# -gt 0 ] && shift;;
      --fix-term=*) fix_term="${1#*=}"; [ -n "$fix_term" ] || { echo "✗ --fix-term requires TERM" >&2; return 1; }; shift;;
      --fix-term) shift; fix_term="${1:-}"; [ -n "$fix_term" ] || { echo "✗ --fix-term requires TERM" >&2; return 1; }; shift;;
      high|max) level="$1"; shift;;
      *) shift;;
    esac
  done

  rv_preflight || return $?
  local review_args=("--claude-review-effort" "$level")
  [ "$codex_only" = 1 ] && review_args+=("--codex-only")
  [ "$kill_review" = 1 ] && review_args+=("--kill-review-tabs")
  rv_reviews "${review_args[@]}" || return $?

  local accepted="$RV_OUTDIR/accepted-fixes.md"
  if rv_write_accepted_fixes "$RV_OUTDIR"; then
    echo "accepted fixes:"
    cat "$accepted"
  else
    local rc=$?
    if [ "$rc" = 3 ]; then
      echo "iso-review: no accepted fixes to apply"
      return 0
    fi
    return "$rc"
  fi

  local apply_args=("$accepted")
  [ -n "$fix_term" ] && apply_args+=("--fix-term" "$fix_term") || apply_args+=("--fix-agent" "$fix_agent")
  [ "$kill_fix" = 1 ] && apply_args+=("--kill-fix-tab")
  rv_apply "${apply_args[@]}"
}

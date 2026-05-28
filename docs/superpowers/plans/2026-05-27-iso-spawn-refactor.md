# iso-spawn Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **NO-COMMIT MODE:** The user wants the entire change left uncommitted for one combined review. **Skip every `git commit` step.** After each task, run the test suite as the green gate instead of committing. Do not stage or commit anything.

**Goal:** Refactor `iso-spawn` from a monolithic `spawn.sh` into a thin subcommand dispatcher over four sourced bash libs (+ the unchanged `recover.py`), add interaction/lifecycle/cleanup verbs (`deliver`, `send`, `status`, `cleanup`), make agent→transcript mapping concurrency-safe, and add an opt-in `--kill`.

**Architecture:** `spawn.sh` parses a subcommand and dispatches to library functions. `lib/herdr.sh` wraps herdr primitives; `lib/transcript.sh` owns sidecar + transcript mapping; `lib/deliver.sh` owns the delivery poll loop and the `deliver` wrapper; `lib/cleanup.sh` owns orphan detection, sidecar removal, and tab kill. Everything keys off the globally-unique `TERM` so concurrent agents never conflict.

**Tech Stack:** bash (sourced libs, `set -euo pipefail`) + python3 stdlib (`recover.py`, unchanged). Tests = the existing self-contained bash runner, extended; herdr-touching paths covered by a stub + a manual live smoke test.

**Spec:** `docs/superpowers/specs/2026-05-27-iso-spawn-refactor-design.md`

**Starting point:** builds on the uncommitted recovery feature. Current `skills/iso-spawn/scripts/spawn.sh` contains: helpers `_claude_slug`/`_candidate_set`/`_diff_new`/`_write_meta`; the `__deliver` branch; the `--recover` branch; debug branches `--candidate-set`/`--diff-new`/`--write-meta`; the main spawn flow; `--wait --recover`; and a 7-day prune (to be removed). `recover.py` and `tests/run.sh` (23 assertions) exist.

---

## File Structure

- **Create** `skills/iso-spawn/scripts/lib/herdr.sh` — herdr primitives: `herdr_jget`, `herdr_caller_context`, `herdr_agent_status`, `herdr_pane_read`, `herdr_pane_for`, `herdr_tab_for`, `herdr_pane_run`, `herdr_send_keys`, `herdr_tab_close`, `herdr_agent_terms`, `herdr_agent_names`, `herdr_scrollback`.
- **Create** `skills/iso-spawn/scripts/lib/transcript.sh` — mapping: `transcript_slug`, `transcript_candidate_set`, `transcript_diff_new`, `transcript_resolve_new` (diff → prompt-fingerprint → newest), `transcript_write_meta`, `transcript_sidecar_for`, `transcript_session_file`.
- **Create** `skills/iso-spawn/scripts/lib/deliver.sh` — `deliver_worker` (the `__deliver` poll loop body), `deliver_place` (spawn placement), `deliver_dispatch` (bg vs wait), `deliver_wrapper` (the `deliver` verb).
- **Create** `skills/iso-spawn/scripts/lib/cleanup.sh` — `cleanup_kill_agent`, `cleanup_rm_sidecar`, `cleanup_orphaned`.
- **Modify** `skills/iso-spawn/scripts/spawn.sh` — becomes a dispatcher: source libs, parse subcommand (`spawn|deliver|send|recover|status|cleanup` + bare `<codex|claude>` alias + hidden `__*`), route to lib functions, usage.
- **Keep** `skills/iso-spawn/scripts/recover.py` — unchanged.
- **Modify** `skills/iso-spawn/tests/run.sh` — source libs for unit tests; rename debug-entry calls to `__*`; add fingerprint + cleanup + dispatch tests.
- **Modify** `skills/iso-spawn/SKILL.md`, `REFERENCE.md`, `README.md` — verb surface + lib layout.

Convention: every lib function is prefixed by its module (`herdr_`, `transcript_`, `deliver_`, `cleanup_`). `spawn.sh` sets `LIBDIR="$(cd "$(dirname "$0")" && pwd)/lib"` and sources all four near the top. Each lib begins with a guard comment and assumes `set -euo pipefail` from the caller. Every herdr call inside loops/workers stays guarded with `|| true`.

---

## Task 1: Extract `lib/transcript.sh` (move mapping helpers, keep behavior)

**Files:**
- Create: `skills/iso-spawn/scripts/lib/transcript.sh`
- Modify: `skills/iso-spawn/scripts/spawn.sh`
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Create `lib/transcript.sh`** with the mapping helpers, renamed with the `transcript_` prefix. Content:

```bash
#!/usr/bin/env bash
# transcript.sh — map a spawned agent to its native JSONL transcript, and the .spawn sidecar.
# Pure filesystem logic; dirs are env-overridable for tests (ISO_CODEX_SESS, ISO_CLAUDE_PROJ).
# Assumes the caller set `set -euo pipefail`.

# Slug a cwd the way claude names its project dir: '/' and '.' -> '-'.
transcript_slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

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
    printf '%s\n' "$5" | grep -v '^$' | while IFS= read -r p; do echo "pre=$p"; done
  } > "$1"
}

# Find the .spawn sidecar path for a TERM (searches ISO_SPAWN_LOGDIR, ./.iso, $TMPDIR). Empty if none.
transcript_sidecar_for() { # $1=term
  local base cand
  for base in "${ISO_SPAWN_LOGDIR:-}" "./.iso/logs/spawn" "${TMPDIR:-/tmp}"; do
    [ -n "$base" ] || continue
    cand=$(find "$base" -maxdepth 1 -name "*__$1.spawn" 2>/dev/null | head -1)
    [ -n "$cand" ] && { printf '%s' "$cand"; return; }
  done
}
```

- [ ] **Step 2: Source it from `spawn.sh`.** After the `jget()` definition (current line 12), add:

```bash
LIBDIR="$(cd "$(dirname "$0")" && pwd)/lib"
. "$LIBDIR/transcript.sh"
```

Then DELETE the now-duplicated `_claude_slug`, `_candidate_set`, `_diff_new`, `_write_meta` definitions from `spawn.sh` (current lines ~14-49), and replace every remaining call to them with the `transcript_`-prefixed names (in the `__deliver` resolution block, the `--recover` branch, and the debug branches).

- [ ] **Step 3: Rename debug entrypoints to the hidden `__` namespace.** In `spawn.sh`, change the three debug branches to:

```bash
if [ "${1:-}" = "__candidate-set" ]; then transcript_candidate_set "$2" "$3"; exit 0; fi
if [ "${1:-}" = "__diff-new" ]; then transcript_diff_new "$2" "$3" "$4"; exit 0; fi
if [ "${1:-}" = "__write-meta" ]; then transcript_write_meta "$2" "$3" "$4" "$5" "$6"; exit 0; fi
```

- [ ] **Step 4: Update `tests/run.sh`** to call the renamed entrypoints. Replace `--candidate-set`→`__candidate-set`, `--diff-new`→`__diff-new`, `--write-meta`→`__write-meta` (in the Task 6/7/8 blocks of the recovery suite).

- [ ] **Step 5: Run the suite (green gate, no commit).**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: `spawn.sh` parses; all 23 assertions `ok`; exit 0.

---

## Task 2: Extract `lib/herdr.sh` (move herdr primitives)

**Files:**
- Create: `skills/iso-spawn/scripts/lib/herdr.sh`
- Modify: `skills/iso-spawn/scripts/spawn.sh`

- [ ] **Step 1: Create `lib/herdr.sh`:**

```bash
#!/usr/bin/env bash
# herdr.sh — thin wrappers over the herdr CLI. Every call guarded so a non-zero never aborts
# a caller running under `set -euo pipefail`. Assumes the caller set pipefail.

# Extract a value from herdr JSON on stdin by a ["a"]["b"][0] path.
herdr_jget() {
  python3 -c 'import json,sys,re
d=json.load(sys.stdin); cur=d
for k in re.findall(r"\[(?:\"([^\"]+)\"|(\d+))\]", sys.argv[1]): cur=cur[k[0] if k[0] else int(k[1])]
print(cur)' "$1"
}

# Resolve the caller pane -> "WORKSPACE\tCWD". Fails (rc 1) if $HERDR_PANE_ID unset/unresolvable.
herdr_caller_context() {
  [ -n "${HERDR_PANE_ID:-}" ] || return 1
  local info ws cwd
  info=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null) || return 1
  ws=$(printf '%s' "$info" | herdr_jget '["result"]["pane"]["workspace_id"]') || return 1
  cwd=$(printf '%s' "$info" | herdr_jget '["result"]["pane"]["cwd"]' 2>/dev/null || true)
  printf '%s\t%s' "$ws" "$cwd"
}

herdr_agent_status() { herdr agent get "$1" 2>/dev/null | herdr_jget '["result"]["agent"]["agent_status"]' 2>/dev/null || echo unknown; }
herdr_pane_for()     { herdr agent get "$1" 2>/dev/null | herdr_jget '["result"]["agent"]["pane_id"]'  2>/dev/null || true; }
herdr_tab_for()      { herdr agent get "$1" 2>/dev/null | herdr_jget '["result"]["agent"]["tab_id"]'   2>/dev/null || true; }
herdr_pane_read()    { herdr pane read "$1" --source visible --lines "${2:-40}" 2>/dev/null || true; }
herdr_pane_run()     { herdr pane run "$1" "$2" >/dev/null 2>&1 || true; }
herdr_send_keys()    { local p="$1"; shift; herdr pane send-keys "$p" "$@" >/dev/null 2>&1 || true; }
herdr_tab_close()    { herdr tab close "$1" >/dev/null 2>&1 || true; }

# All live agent terminal_ids, one per line.
herdr_agent_terms() {
  herdr agent list 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join(a.get("terminal_id","") for a in json.load(sys.stdin)["result"]["agents"]))
except Exception: pass' || true
}

# All live agent names, one per line (for name-collision avoidance).
herdr_agent_names() {
  herdr agent list 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join((a.get("name") or a.get("agent") or "") for a in json.load(sys.stdin)["result"]["agents"]))
except Exception: pass' || true
}

# Bounded scrollback text for a (live) agent. Empty after the tab is closed.
herdr_scrollback() {
  herdr agent read "$1" --source recent --lines "${2:-5000}" --format text 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["read"]["text"])
except Exception: pass'
}
```

- [ ] **Step 2: Source it and replace inline calls.** In `spawn.sh`, after sourcing `transcript.sh`, add `. "$LIBDIR/herdr.sh"`. Then:
  - DELETE the local `jget()` definition (now `herdr_jget`); replace all `jget` calls in `spawn.sh` with `herdr_jget`.
  - In the main flow's "resolve caller pane" block (current lines ~202-207), replace the manual `herdr pane get $HERDR_PANE_ID` + jget extraction with:

```bash
CTX=$(herdr_caller_context) || { echo "error: \$HERDR_PANE_ID unset or unresolvable — run inside a herdr pane" >&2; exit 1; }
WS=${CTX%%$'\t'*}; CALLER_CWD=${CTX#*$'\t'}
[ -n "$CWD" ] || CWD="$CALLER_CWD"
export WS
```
  - Replace the agent-name dedup block's inline python (current ~216-218) with `TAKEN=$(herdr_agent_names)`.
  - Replace `--recover`'s scrollback fallback python pipeline with `herdr_scrollback "$RTERM"` (keep the `# source: scrollback …` header line before it).
  - Replace the `status()` helper inside `__deliver` and the post-`--wait` status read with `herdr_agent_status`.

- [ ] **Step 3: Green gate.**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: parses; 23 `ok`; exit 0.

---

## Task 3: Extract `lib/deliver.sh` (delivery loop + placement)

**Files:**
- Create: `skills/iso-spawn/scripts/lib/deliver.sh`
- Modify: `skills/iso-spawn/scripts/spawn.sh`

- [ ] **Step 1: Create `lib/deliver.sh`** by moving the `__deliver` poll-loop body into a function `deliver_worker`, the session_file resolution into it, using the lib helpers. Content:

```bash
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
    C=$(printf '%s' "$S" | deliver_classify "$PROMPT")
    if [ "$injected" = 1 ]; then
      case "$(herdr_agent_status "$TERM2")" in working|done|blocked) break;; esac
      [ "$C" = submitted ] && break
      if [ "$C" = pending ]; then herdr_send_keys "$PANE" Enter; sleep 1; continue; fi
    fi
    if [ "$C" = pending ]; then herdr_send_keys "$PANE" Enter; sleep 1
    elif printf '%s' "$S" | grep -qiE "$READY"; then herdr_pane_run "$PANE" "$PROMPT"; injected=1; sleep 2
    else sleep 1; fi
  done
  # Record the transcript now that the agent is live (prompt-fingerprint added in a later task).
  if [ -n "$SPAWNFILE" ] && [ -f "$SPAWNFILE" ]; then
    local m_agent m_cwd m_pre a newf
    m_agent=$(grep '^agent=' "$SPAWNFILE" | head -1 | cut -d= -f2- || true)
    m_cwd=$(grep '^cwd=' "$SPAWNFILE" | head -1 | cut -d= -f2- || true)
    m_pre=$(grep '^pre=' "$SPAWNFILE" | cut -d= -f2- || true)
    case "$m_agent" in claude*) a=claude;; *) a=codex;; esac
    newf=$(transcript_diff_new "$a" "$m_cwd" "$m_pre")
    [ -n "$newf" ] && echo "session_file=$newf" >> "$SPAWNFILE"
  fi
  [ "$WAIT" = 1 ] && herdr agent wait "$TERM2" --status idle --timeout "$WAIT_MS" >/dev/null 2>&1 || true
}
```

- [ ] **Step 2: Replace the `__deliver` branch in `spawn.sh`** with a thin shim that sources libs (already sourced at top) and calls the function:

```bash
if [ "${1:-}" = "__deliver" ]; then
  [ "${ISO_TRACE:-}" = 1 ] && set -x
  deliver_worker "$2" "$3" "$4" "$5" "$6" "${7:-}"
  exit 0
fi
```

(The `SELF` re-exec in the dispatch section keeps passing the same 6 args.)

- [ ] **Step 3: Green gate.**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: parses; 23 `ok`; exit 0. (Delivery loop itself is covered by the live smoke test in Task 11.)

---

## Task 4: Concurrency-safe mapping — prompt fingerprint

**Files:**
- Modify: `skills/iso-spawn/scripts/lib/transcript.sh`
- Modify: `skills/iso-spawn/scripts/lib/deliver.sh`
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add a failing test.** Append to `tests/run.sh` before `exit $fail`:

```bash
# --- Task 4: prompt-fingerprint disambiguation (concurrent same-cwd spawns) ---
. "$HERE/../scripts/lib/transcript.sh"
TMP=$(mktemp -d); mkdir -p "$TMP/codex/2026/05/27"
touch "$TMP/codex/2026/05/27/rollout-OLD.jsonl"
PRE=$(ISO_CODEX_SESS="$TMP/codex" transcript_candidate_set codex /tmp/fixture)
# two new files appear; only the SECOND (older mtime via touch order) contains our prompt
printf '{"payload":{"type":"user_message","message":"OTHER agent prompt"}}\n' > "$TMP/codex/2026/05/27/rollout-NEW-other.jsonl"
sleep 1
printf '{"payload":{"type":"user_message","message":"UNIQUE-FINGERPRINT-XYZ"}}\n' > "$TMP/codex/2026/05/27/rollout-NEW-mine.jsonl"
got=$(ISO_CODEX_SESS="$TMP/codex" transcript_resolve_new codex /tmp/fixture "$PRE" "UNIQUE-FINGERPRINT-XYZ")
assert_eq "fingerprint beats newest-by-mtime" "$(basename "$got")" "rollout-NEW-mine.jsonl"
# no prompt -> falls back to newest (the later-touched 'mine')
gotn=$(ISO_CODEX_SESS="$TMP/codex" transcript_resolve_new codex /tmp/fixture "$PRE" "")
assert_eq "no prompt -> newest-by-mtime" "$(basename "$gotn")" "rollout-NEW-mine.jsonl"
rm -rf "$TMP"
```

- [ ] **Step 2: Run — expect FAIL** (`transcript_resolve_new` undefined).

Run: `bash skills/iso-spawn/tests/run.sh`

- [ ] **Step 3: Add `transcript_resolve_new` to `lib/transcript.sh`:**

```bash
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
```

- [ ] **Step 4: Use it in the worker.** In `lib/deliver.sh` `deliver_worker`, replace the `newf=$(transcript_diff_new "$a" "$m_cwd" "$m_pre")` line with:

```bash
    newf=$(transcript_resolve_new "$a" "$m_cwd" "$m_pre" "$PROMPT")
```

- [ ] **Step 5: Run — all green.**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: new fingerprint assertions `ok`; all prior `ok`; exit 0.

---

## Task 5: `lib/cleanup.sh` + `cleanup` verb

**Files:**
- Create: `skills/iso-spawn/scripts/lib/cleanup.sh`
- Modify: `skills/iso-spawn/scripts/spawn.sh`
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add failing tests** (stub `herdr_agent_terms` to control "live" agents). Append to `run.sh` before `exit $fail`:

```bash
# --- Task 5: cleanup (orphaned + named, grace window) ---
. "$HERE/../scripts/lib/herdr.sh"; . "$HERE/../scripts/lib/cleanup.sh"
TMP=$(mktemp -d)
herdr_agent_terms() { echo "term_LIVE"; }              # stub: only term_LIVE is alive
: > "$TMP/a__term_LIVE.spawn"                            # alive -> keep
: > "$TMP/b__term_DEAD.spawn"; touch -t 202001010000 "$TMP/b__term_DEAD.spawn"  # dead+old -> reap
: > "$TMP/c__term_FRESH.spawn"                           # dead but fresh (<grace) -> keep
ISO_SPAWN_LOGDIR="$TMP" ISO_ORPHAN_GRACE=60 cleanup_orphaned
[ -f "$TMP/a__term_LIVE.spawn" ];  assert_eq "live sidecar kept"  "$?" "0"
[ -f "$TMP/b__term_DEAD.spawn" ];  assert_eq "dead+old reaped"    "$?" "1"
[ -f "$TMP/c__term_FRESH.spawn" ]; assert_eq "dead+fresh kept"    "$?" "0"
cleanup_rm_sidecar term_FRESH "$TMP"
[ -f "$TMP/c__term_FRESH.spawn" ]; assert_eq "rm_sidecar removes named" "$?" "1"
unset -f herdr_agent_terms
rm -rf "$TMP"
```

- [ ] **Step 2: Run — expect FAIL** (`cleanup_*` undefined).

- [ ] **Step 3: Create `lib/cleanup.sh`:**

```bash
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
# window (ISO_ORPHAN_GRACE seconds, default 60). Searches ISO_SPAWN_LOGDIR or ./.iso.
cleanup_orphaned() {
  local dir grace live now mtime term f
  dir="${ISO_SPAWN_LOGDIR:-./.iso/logs/spawn}"
  grace="${ISO_ORPHAN_GRACE:-60}"
  [ -d "$dir" ] || return 0
  live=$(herdr_agent_terms)
  now=$(date +%s)
  for f in "$dir"/*.spawn; do
    [ -f "$f" ] || continue
    term=$(grep '^term=' "$f" | head -1 | cut -d= -f2- || true)
    [ -n "$term" ] || term="${f##*__}"; term="${term%.spawn}"
    printf '%s\n' "$live" | grep -qx "$term" && continue          # still alive -> keep
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
    [ $((now - mtime)) -ge "$grace" ] && rm -f "$f" 2>/dev/null || true
  done
}
```

- [ ] **Step 4: Source cleanup in `spawn.sh`** (add `. "$LIBDIR/cleanup.sh"` with the other sources). Run — all green.

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: cleanup assertions `ok`; all prior `ok`.

---

## Task 6: Dispatcher + `send` / `status` / `cleanup` verbs + bare alias

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh`
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add a failing dispatch test.** Append to `run.sh` before `exit $fail`:

```bash
# --- Task 6: dispatch routing ---
out=$("$SPAWN" recover dummyterm --session-file "$FIX/codex.jsonl" --agent codex --what output)
assert_eq "verb: recover routes" "$out" "FINAL_ANSWER_42"
err=$("$SPAWN" bogusverb 2>&1 || true)
assert_has "unknown verb -> usage" "$err" "Usage:"
```

- [ ] **Step 2: Run — expect FAIL** (`recover` as a subcommand not yet routed; `bogusverb` currently hits the `codex|claude` type error, not usage).

- [ ] **Step 3: Restructure `spawn.sh` into a dispatcher.** After the lib sourcing and the hidden `__*` branches, replace the current `[ $# -ge 1 ] || usage` + `TYPE="$1"` logic with a subcommand router. The existing `--recover` branch body becomes the `recover` verb; the main spawn flow becomes the `spawn` verb (wrapped so the bare alias works). Concretely:

```bash
[ $# -ge 1 ] || { usage; exit 1; }
VERB="$1"
case "$VERB" in
  codex|claude) VERB="spawn" ;;            # bare alias: spawn.sh codex … == spawn.sh spawn codex …
  spawn|deliver|send|recover|status|cleanup) shift ;;
  *) echo "error: unknown command $VERB" >&2; usage; exit 1;;
esac

case "$VERB" in
  send)    # send <TERM> <text> [--kill]
    RTERM="$1"; shift; TEXT="${1:-}"; shift || true; KILL=0
    [ "${1:-}" = "--kill" ] && KILL=1
    [ -n "$RTERM" ] && [ -n "$TEXT" ] || { echo "error: send <TERM> <text>" >&2; exit 1; }
    PANE=$(herdr_pane_for "$RTERM"); [ -n "$PANE" ] || { echo "error: agent $RTERM has no live pane" >&2; exit 1; }
    herdr_pane_run "$PANE" "$TEXT"; echo "sent to $RTERM"
    [ "$KILL" = 1 ] && cleanup_kill_agent "$RTERM"
    exit 0 ;;
  status)  # status <TERM> [--kill]
    RTERM="$1"; shift; KILL=0; [ "${1:-}" = "--kill" ] && KILL=1
    [ -n "$RTERM" ] || { echo "error: status <TERM>" >&2; exit 1; }
    herdr_agent_status "$RTERM"
    [ "$KILL" = 1 ] && cleanup_kill_agent "$RTERM"
    exit 0 ;;
  cleanup) # cleanup (<TERM> [--kill] | --orphaned)
    if [ "${1:-}" = "--orphaned" ]; then cleanup_orphaned; echo "orphaned sidecars pruned"; exit 0; fi
    RTERM="$1"; shift || true; [ -n "$RTERM" ] || { echo "error: cleanup <TERM>|--orphaned" >&2; exit 1; }
    if [ "${1:-}" = "--kill" ]; then cleanup_kill_agent "$RTERM"; echo "killed $RTERM"; else cleanup_rm_sidecar "$RTERM"; echo "sidecar removed for $RTERM"; fi
    exit 0 ;;
esac
```

Then the existing `recover` body runs for `VERB=recover` (keep the current branch, but change its guard from `[ "${1:-}" = "--recover" ]` to `[ "$VERB" = recover ]`, and remove the leading `shift`/`RTERM=$1;shift` that consumed `--recover` — now positional `$1` is already the TERM after the router's `shift`). Add `--kill` handling at the end of the recover branch: after the `exec python3 …` is replaced by a non-exec call so kill can run:

```bash
  python3 "$SELFDIR/recover.py" "$RAGENT" "$RWHAT" "$RSESS" "$RFMT"; rc=$?
  [ "${RKILL:-0}" = 1 ] && cleanup_kill_agent "$RTERM"
  exit $rc
```
(parse `--kill` into `RKILL` in the recover option loop.)

For `VERB=spawn`/`deliver`, fall through to the spawn flow (Task 7 wires `deliver`).

- [ ] **Step 4: Add `send`/`status`/`cleanup`/`recover`/`deliver` to `usage()`** (and ensure usage starts with the line `Usage:`).

- [ ] **Step 5: Run — green.**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: dispatch assertions `ok`; the bare-alias spawn path and all prior `ok`.

---

## Task 7: `deliver` wrapper

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh`
- Modify: `skills/iso-spawn/scripts/lib/deliver.sh`

- [ ] **Step 1: Implement `deliver` as spawn + recover.** The simplest reliable composition: `deliver` runs the normal spawn flow with `WAIT=1` forced and a recover at the end. In `spawn.sh`, where the spawn flow ends (after the `--wait` status print), generalize the existing `--recover` companion so it also serves `deliver`:
  - When `VERB=deliver`: force `WAIT=1`, require `--prompt`, default `RECOVER_WHAT=output` if unset, and after recovery verify a non-empty result:

```bash
  if [ "$VERB" = deliver ] || [ -n "$RECOVER_WHAT" ]; then
    echo "--- recovered (${RECOVER_WHAT:-output}) ---"
    RESULT=$("$SELF" recover "$TERM" --what "${RECOVER_WHAT:-output}" || true)
    printf '%s\n' "$RESULT"
    if [ "$VERB" = deliver ] && [ -z "$(printf '%s' "$RESULT" | tr -d '[:space:]')" ]; then
      echo "warning: deliver got an empty result from $TERM" >&2
    fi
    [ "${KILL:-0}" = 1 ] && cleanup_kill_agent "$TERM"
  fi
```
  - Parse `--what` and `--kill` for the `deliver`/`spawn` flows into `RECOVER_WHAT` and `KILL` in the main option loop (extend the existing `--recover` handling; add `--what` and `--kill`).

- [ ] **Step 2: Syntax + green gate.**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: parses; all `ok` (deliver exercised live in Task 11).

---

## Task 8: `--kill` on `spawn`-flow recover + remove the TTL prune

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh`

- [ ] **Step 1: Remove the 7-day prune.** Delete the two `find … -mtime +7 -delete` lines added by the recovery feature (they sit right after `SPAWNFILE=…`/`_write_meta`). Orphan-based `cleanup --orphaned` replaces them.

- [ ] **Step 2: Confirm `--kill` is wired** for `deliver` (Task 7) and the agent-targeting verbs `send`/`status`/`recover`/`cleanup` (Task 6). Bare `spawn` must NOT accept `--kill` — verify the spawn option loop rejects `--kill` with the usual "unknown option" path (it should, since only `deliver` sets it meaningfully; if `--kill` is in the shared loop, gate it so a bare `spawn` without `--wait`/`deliver` warns it's a no-op). Simplounded approach: accept `--kill` in the shared loop but only act on it in the `deliver`/recover/send/status/cleanup paths; document that on a bare async `spawn` it is ignored.

- [ ] **Step 3: Syntax + green gate.**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: parses; all `ok`.

---

## Task 9: Live integration smoke test

**Files:** none (manual verification; requires a herdr pane).

- [ ] **Step 1: deliver + kill.**

```bash
skills/iso-spawn/scripts/spawn.sh deliver codex \
  --prompt "Reply with EXACTLY this line then stop: DELIVER_TOKEN=mike-9" \
  --name dtest --kill
```
Expected: prints `--- recovered (output) ---` then `DELIVER_TOKEN=mike-9`; afterwards the agent is **absent** from `herdr agent list` (tab killed). Verify:
```bash
herdr agent list | grep -c dtest   # expect 0
```

- [ ] **Step 2: send + status on a live agent.**

```bash
skills/iso-spawn/scripts/spawn.sh codex --prompt "Wait for my next instruction." --name stest
T=$(herdr agent list | python3 -c 'import json,sys
for a in json.load(sys.stdin)["result"]["agents"]:
  if (a.get("name") or "").startswith("stest"): print(a["terminal_id"])')
skills/iso-spawn/scripts/spawn.sh status "$T"          # idle|working
skills/iso-spawn/scripts/spawn.sh send "$T" "Print the number 7 and stop."
sleep 5
skills/iso-spawn/scripts/spawn.sh recover "$T" --what chat | tail
skills/iso-spawn/scripts/spawn.sh cleanup "$T" --kill   # close + drop sidecar
```
Expected: `status` prints a state; `send` reports `sent to <T>`; `recover --what chat` shows the "7" turn; after `cleanup --kill`, the agent is gone and its sidecar removed.

- [ ] **Step 3: orphaned cleanup.**

```bash
skills/iso-spawn/scripts/spawn.sh cleanup --orphaned   # prunes sidecars of agents no longer live (older than grace)
```
Expected: `orphaned sidecars pruned`; sidecars for already-closed agents (older than 60s) removed; any live agent's sidecar untouched.

---

## Task 10: Docs — verb surface + lib layout

**Files:**
- Modify: `skills/iso-spawn/SKILL.md`
- Modify: `skills/iso-spawn/REFERENCE.md`
- Modify: `skills/iso-spawn/README.md`

- [ ] **Step 1: SKILL.md** — replace the single-command framing with the verb table (`spawn`/`deliver`/`send`/`recover`/`status`/`cleanup`), note the bare `<codex|claude>` alias, document `--kill` (opt-in, not on bare spawn), and the `lib/` layout (one line per module). Keep the existing "Recover output" section; add a short "Interact & clean up" section showing `send`/`status`/`cleanup`.

- [ ] **Step 2: REFERENCE.md** — under the `.spawn` sidecar section, add: the concurrency model (TERM-keyed lanes; mapping = snapshot-diff → prompt fingerprint → newest; orphan reap gated by `ISO_ORPHAN_GRACE`=60s); and the module map (herdr/transcript/deliver/cleanup responsibilities).

- [ ] **Step 3: README.md (iso-spawn)** — add a `deliver`/`send`/`status`/`cleanup` line to the Options/verbs area and a one-line mention of `--kill` and orphan cleanup. Do NOT touch the repo-root README.md (it carries unrelated concurrent edits).

- [ ] **Step 4: Final green gate.**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: parses; every assertion `ok`; exit 0.

---

## Notes for the implementer

- **NO COMMITS.** Leave everything uncommitted. Use the test suite as the per-task gate.
- **Hidden `__*` entrypoints** (`__deliver`, `__candidate-set`, `__diff-new`, `__write-meta`) exist for the worker + tests; keep them.
- **Sourcing order in `spawn.sh`:** `transcript.sh` → `herdr.sh` → `deliver.sh` → `cleanup.sh` (deliver uses herdr+transcript; cleanup uses herdr+transcript). All must be sourced before the `__deliver` shim and the dispatcher.
- **Portability:** keep `stat -f %m` (macOS) with `stat -c %Y` (Linux) fallback in every mtime read.
- **`set -e` in workers:** every herdr call is wrapped in `herdr_*` (guarded `|| true`); a no-match `grep` inside `$(...)` is fine. Never introduce an unguarded non-zero in `deliver_worker`.
- **`$SELF`/`$SELFDIR`:** `spawn.sh` keeps `SELF` (absolute path to itself, for the `__deliver` re-exec) and `SELFDIR` (for `recover.py`). The dispatcher calls `"$SELF" recover …` for the deliver wrapper.
```

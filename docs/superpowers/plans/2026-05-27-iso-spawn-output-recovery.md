# iso-spawn Output Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--recover` command to `iso-spawn` that returns a spawned agent's clean final answer (default) or full transcript (`--what chat`), read from the agent's native JSONL transcript, with herdr scrollback as a degraded fallback.

**Architecture:** A standalone, pure parser (`scripts/recover.py`) extracts turns from a codex or claude JSONL file. `scripts/spawn.sh` gains: (1) a spawn-time snapshot that records the candidate transcript set, (2) a `__deliver` step that diffs the set after the agent boots and records the resolved `session_file`, both persisted in a merged `.spawn` sidecar that replaces today's `.log`, and (3) a `--recover` branch that resolves the transcript file and calls the parser, falling back to scrollback when the file can't be mapped.

**Tech Stack:** bash + python3 (stdlib only), herdr CLI. No build step, no package manager (matches repo conventions in CLAUDE.md). Tests are a self-contained bash runner over committed JSONL fixtures.

**Spec:** `docs/superpowers/specs/2026-05-27-iso-spawn-output-recovery-design.md`

---

## File Structure

- **Create** `skills/iso-spawn/scripts/recover.py` — pure JSONL→turns parser; codex + claude; `output`/`chat`; `text`/`json`. No filesystem mapping, no herdr — deterministic on a file path. The single testable core.
- **Create** `skills/iso-spawn/tests/run.sh` — bash test runner with assert helpers; exits non-zero on any failure.
- **Create** `skills/iso-spawn/tests/fixtures/codex.jsonl` — minimal valid codex rollout.
- **Create** `skills/iso-spawn/tests/fixtures/claude.jsonl` — minimal valid claude session (incl. a trailing `tool_use`-only assistant line).
- **Create** `skills/iso-spawn/tests/fixtures/empty.jsonl` — a transcript with no assistant turn.
- **Modify** `skills/iso-spawn/scripts/spawn.sh` — add `--recover` branch + recovery helper functions; spawn-time snapshot; `.spawn` sidecar (merging the trace log); `session_file` resolution in `__deliver`; `--wait --recover` companion.
- **Modify** `skills/iso-spawn/SKILL.md`, `REFERENCE.md`, `README.md` — document `--recover`, the `.spawn` sidecar, recovery model.
- **Modify** `.gitignore` (repo root) — ignore `.iso/`.

The parser is isolated from spawn.sh so it can be unit-tested directly and so a third agent type later is one function. Mapping/snapshot logic in spawn.sh is made testable via env-var directory overrides (`ISO_CODEX_SESS`, `ISO_CLAUDE_PROJ`).

---

## Task 1: Parser core — codex output

**Files:**
- Create: `skills/iso-spawn/scripts/recover.py`
- Create: `skills/iso-spawn/tests/fixtures/codex.jsonl`
- Create: `skills/iso-spawn/tests/fixtures/empty.jsonl`
- Create: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Write the codex fixture**

Create `skills/iso-spawn/tests/fixtures/codex.jsonl` (exact lines, match real codex schema verified 2026-05-27):

```jsonl
{"type":"session_meta","payload":{"id":"test-uuid-codex","timestamp":"2026-05-27T00:00:00Z","cwd":"/tmp/fixture"}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"user_message","message":"hello question"}}
{"type":"response_item","payload":{"type":"reasoning","summary":[]}}
{"type":"event_msg","payload":{"type":"agent_message","message":"FINAL_ANSWER_42"}}
{"type":"event_msg","payload":{"type":"token_count"}}
{"type":"event_msg","payload":{"type":"task_complete"}}
```

- [ ] **Step 2: Write the empty fixture**

Create `skills/iso-spawn/tests/fixtures/empty.jsonl`:

```jsonl
{"type":"session_meta","payload":{"id":"test-uuid-empty","cwd":"/tmp/fixture"}}
{"type":"event_msg","payload":{"type":"user_message","message":"only a question, no answer"}}
```

- [ ] **Step 3: Write the failing test (codex output)**

Create `skills/iso-spawn/tests/run.sh`:

```bash
#!/usr/bin/env bash
# iso-spawn test runner. Pure bash, no external deps. Exits non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RECOVER="$HERE/../scripts/recover.py"
SPAWN="$HERE/../scripts/spawn.sh"
FIX="$HERE/fixtures"
fail=0

assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok: $1"
  else echo "FAIL: $1"; echo "  expected: [$3]"; echo "  actual:   [$2]"; fail=1; fi
}
assert_has() { # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"
  else echo "FAIL: $1 (missing: [$3])"; echo "  in: [$2]"; fail=1; fi
}
assert_before() { # name haystack first second
  local a b; a=$(printf '%s' "$2" | grep -nF -- "$3" | head -1 | cut -d: -f1)
  b=$(printf '%s' "$2" | grep -nF -- "$4" | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "ok: $1"
  else echo "FAIL: $1 ([$3]@$a not before [$4]@$b)"; fail=1; fi
}

# --- Task 1: codex output ---
out=$(python3 "$RECOVER" codex output "$FIX/codex.jsonl" text)
assert_eq "codex output = final answer" "$out" "FINAL_ANSWER_42"

exit $fail
```

Make it executable: `chmod +x skills/iso-spawn/tests/run.sh`

- [ ] **Step 4: Run test to verify it fails**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — `python3 ... recover.py: No such file or directory`, runner exits non-zero.

- [ ] **Step 5: Write minimal recover.py (codex only, output only)**

Create `skills/iso-spawn/scripts/recover.py`:

```python
#!/usr/bin/env python3
"""Parse a spawned agent's JSONL transcript and emit its output or full chat.

Usage: recover.py <codex|claude> <output|chat> <jsonl_path> <text|json>
Prints to stdout. Exits 1 (with a note) when output is requested but no
assistant turn exists.
"""
import json
import sys


def codex_turns(path):
    """Yield (role, text) from a codex rollout, using the clean event_msg stream."""
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        pay = d.get("payload") if isinstance(d.get("payload"), dict) else d
        t = pay.get("type")
        if t == "user_message":
            msg = pay.get("message") or ""
            if msg.strip():
                yield ("user", msg)
        elif t == "agent_message":
            msg = pay.get("message") or ""
            if msg.strip():
                yield ("assistant", msg)


def main():
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: recover.py <codex|claude> <output|chat> <file> <text|json>\n"
        )
        sys.exit(2)
    agent, what, path, fmt = sys.argv[1:5]
    turns = list(codex_turns(path))
    asst = [t for t in turns if t[0] == "assistant"]
    if not asst:
        sys.stdout.write("# (no assistant output found)\n")
        sys.exit(1)
    print(asst[-1][1])


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: `ok: codex output = final answer`, runner exits 0.

- [ ] **Step 7: Commit**

```bash
git add skills/iso-spawn/scripts/recover.py skills/iso-spawn/tests/
git commit -m "feat(iso-spawn): parse codex transcript final answer"
```

---

## Task 2: Parser — codex chat + the no-assistant case

**Files:**
- Modify: `skills/iso-spawn/scripts/recover.py`
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add failing tests (chat + empty)**

Append to `skills/iso-spawn/tests/run.sh` before `exit $fail`:

```bash
# --- Task 2: codex chat + empty ---
chat=$(python3 "$RECOVER" codex chat "$FIX/codex.jsonl" text)
assert_has "codex chat has question" "$chat" "hello question"
assert_has "codex chat has answer" "$chat" "FINAL_ANSWER_42"
assert_before "codex chat user before assistant" "$chat" "hello question" "FINAL_ANSWER_42"

emptyout=$(python3 "$RECOVER" codex output "$FIX/empty.jsonl" text); rc=$?
assert_eq "empty output note" "$emptyout" "# (no assistant output found)"
assert_eq "empty output exit 1" "$rc" "1"
```

- [ ] **Step 2: Run to verify chat assertions fail**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: `codex chat *` assertions FAIL (chat mode not implemented — currently always prints last answer); empty assertions already pass.

- [ ] **Step 3: Implement chat mode in recover.py**

Replace the `main()` function in `skills/iso-spawn/scripts/recover.py`:

```python
def emit(turns, what, fmt):
    if what == "output":
        asst = [t for t in turns if t[0] == "assistant"]
        if not asst:
            sys.stdout.write("# (no assistant output found)\n")
            sys.exit(1)
        selected = [asst[-1]]
    else:  # chat
        selected = turns
    if fmt == "json":
        print(json.dumps([{"role": r, "text": t} for r, t in selected]))
    elif what == "output":
        print(selected[0][1])
    else:
        for r, t in selected:
            print(f"=== {r} ===")
            print(t)
            print()


def main():
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: recover.py <codex|claude> <output|chat> <file> <text|json>\n"
        )
        sys.exit(2)
    agent, what, path, fmt = sys.argv[1:5]
    turns = list(codex_turns(path))
    emit(turns, what, fmt)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run to verify all codex tests pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all `codex *` and `empty *` assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/iso-spawn/scripts/recover.py skills/iso-spawn/tests/run.sh
git commit -m "feat(iso-spawn): codex chat transcript + empty-output handling"
```

---

## Task 3: Parser — claude (output + chat), skip empty assistant turns

**Files:**
- Modify: `skills/iso-spawn/scripts/recover.py`
- Create: `skills/iso-spawn/tests/fixtures/claude.jsonl`
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Write the claude fixture**

Create `skills/iso-spawn/tests/fixtures/claude.jsonl` (exact; final assistant line is `tool_use`-only to prove "output" picks the last NON-empty assistant text):

```jsonl
{"type":"user","message":{"role":"user","content":"hello question"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"FINAL_ANSWER_42"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
```

- [ ] **Step 2: Add failing claude tests**

Append to `run.sh` before `exit $fail`:

```bash
# --- Task 3: claude ---
cout=$(python3 "$RECOVER" claude output "$FIX/claude.jsonl" text)
assert_eq "claude output skips tool_use line" "$cout" "FINAL_ANSWER_42"
cchat=$(python3 "$RECOVER" claude chat "$FIX/claude.jsonl" text)
assert_has "claude chat has question" "$cchat" "hello question"
assert_has "claude chat has answer" "$cchat" "FINAL_ANSWER_42"
```

- [ ] **Step 3: Run to verify failure**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: claude assertions FAIL (parser only knows codex → produces wrong/empty output).

- [ ] **Step 4: Add claude_turns and dispatch in recover.py**

Add this function after `codex_turns` in `skills/iso-spawn/scripts/recover.py`:

```python
def claude_turns(path):
    """Yield (role, text) from a claude session; only turns with real text."""
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("type") not in ("user", "assistant"):
            continue
        content = (d.get("message") or {}).get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "".join(
                b.get("text", "")
                for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
        else:
            text = ""
        if text.strip():
            yield (d["type"], text)
```

Change the parser selection line in `main()` from:

```python
    turns = list(codex_turns(path))
```

to:

```python
    parser = codex_turns if agent.startswith("codex") else claude_turns
    turns = list(parser(path))
```

- [ ] **Step 5: Run to verify all parser tests pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add skills/iso-spawn/scripts/recover.py skills/iso-spawn/tests/
git commit -m "feat(iso-spawn): parse claude transcripts (output + chat)"
```

---

## Task 4: Parser — JSON output format

**Files:**
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add failing json test**

Append to `run.sh` before `exit $fail`:

```bash
# --- Task 4: json format ---
j=$(python3 "$RECOVER" codex output "$FIX/codex.jsonl" json)
role=$(printf '%s' "$j" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["role"])')
txt=$(printf '%s' "$j" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["text"])')
assert_eq "json output role" "$role" "assistant"
assert_eq "json output text" "$txt" "FINAL_ANSWER_42"
jc=$(python3 "$RECOVER" codex chat "$FIX/codex.jsonl" json)
n=$(printf '%s' "$jc" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
assert_eq "json chat turn count" "$n" "2"
```

- [ ] **Step 2: Run to verify**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: PASS for all — the `emit()` from Task 2 already implements the `json` branch.

If any json assertion fails, the `emit()` json branch is wrong; re-check Task 2 Step 3. Otherwise this task only adds regression coverage.

- [ ] **Step 3: Commit**

```bash
git add skills/iso-spawn/tests/run.sh
git commit -m "test(iso-spawn): cover recover json output format"
```

---

## Task 5: `--recover` branch in spawn.sh (parser wiring + `--session-file` seam)

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh` (add branch after the `__deliver` branch, before `usage()` at line 61)
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add failing end-to-end test through spawn.sh**

Append to `run.sh` before `exit $fail`:

```bash
# --- Task 5: spawn.sh --recover with --session-file seam ---
e2e=$("$SPAWN" --recover dummyterm --session-file "$FIX/codex.jsonl" --agent codex --what output)
assert_eq "spawn --recover output via session-file" "$e2e" "FINAL_ANSWER_42"
e2ec=$("$SPAWN" --recover dummyterm --session-file "$FIX/claude.jsonl" --agent claude --what chat)
assert_has "spawn --recover claude chat" "$e2ec" "hello question"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — spawn.sh treats `--recover` as an unknown type and errors `type must be codex or claude`.

- [ ] **Step 3: Add the `--recover` branch and helper**

In `skills/iso-spawn/scripts/spawn.sh`, immediately after the `__deliver` branch closes (the `fi` on line 59) and before `usage()`, insert:

```bash
SELFDIR="$(cd "$(dirname "$0")" && pwd)"

# ---- recovery: print a spawned agent's output|chat from its native transcript ----
# Usage: spawn.sh --recover <TERM> [--session-file F] [--agent codex|claude]
#                 [--what output|chat] [--format text|json]
# --session-file bypasses mapping (used by tests and power users).
if [ "${1:-}" = "--recover" ]; then
  shift
  RTERM="${1:-}"; [ $# -ge 1 ] && shift || true
  RSESS=""; RAGENT=""; RWHAT="output"; RFMT="text"
  while [ $# -gt 0 ]; do
    case "$1" in
      --session-file) RSESS="$2"; shift 2;;
      --agent) RAGENT="$2"; shift 2;;
      --what) RWHAT="$2"; shift 2;;
      --format) RFMT="$2"; shift 2;;
      *) echo "error: unknown --recover option $1" >&2; exit 1;;
    esac
  done
  case "$RWHAT" in output|chat) ;; *) echo "error: --what must be output|chat" >&2; exit 1;; esac
  case "$RFMT" in text|json) ;; *) echo "error: --format must be text|json" >&2; exit 1;; esac
  if [ -z "$RSESS" ]; then
    echo "error: --session-file required (mapping resolution added in a later task)" >&2
    exit 1
  fi
  [ -n "$RAGENT" ] || { echo "error: --agent required with --session-file" >&2; exit 1; }
  exec python3 "$SELFDIR/recover.py" "$RAGENT" "$RWHAT" "$RSESS" "$RFMT"
fi
```

- [ ] **Step 4: Run to verify pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/iso-spawn/scripts/spawn.sh skills/iso-spawn/tests/run.sh
git commit -m "feat(iso-spawn): --recover branch wiring parser via --session-file"
```

---

## Task 6: Candidate-set + snapshot-diff resolution (pure fs, env-overridable)

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh` (add helper functions near top, after `jget()` at line 12)
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add failing tests for candidate-set and diff**

Append to `run.sh` before `exit $fail`:

```bash
# --- Task 6: candidate set + snapshot diff (env-overridable dirs) ---
TMP=$(mktemp -d)
mkdir -p "$TMP/codex/2026/05/27" "$TMP/claude/-tmp-fixture"
touch "$TMP/codex/2026/05/27/rollout-A.jsonl"
# pre snapshot, then a new file appears
PRE=$(ISO_CODEX_SESS="$TMP/codex" "$SPAWN" --candidate-set codex /tmp/fixture)
touch "$TMP/codex/2026/05/27/rollout-B.jsonl"
NEW=$(ISO_CODEX_SESS="$TMP/codex" "$SPAWN" --diff-new codex /tmp/fixture "$PRE")
assert_eq "snapshot diff finds new codex file" "$(basename "$NEW")" "rollout-B.jsonl"
# claude slug derivation: /tmp/fixture -> -tmp-fixture
touch "$TMP/claude/-tmp-fixture/sess-A.jsonl"
CPRE=$(ISO_CLAUDE_PROJ="$TMP/claude" "$SPAWN" --candidate-set claude /tmp/fixture)
touch "$TMP/claude/-tmp-fixture/sess-B.jsonl"
CNEW=$(ISO_CLAUDE_PROJ="$TMP/claude" "$SPAWN" --diff-new claude /tmp/fixture "$CPRE")
assert_eq "snapshot diff finds new claude file" "$(basename "$CNEW")" "sess-B.jsonl"
rm -rf "$TMP"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — `--candidate-set` is an unknown type.

- [ ] **Step 3: Add helper functions and debug branches**

In `spawn.sh`, after the `jget()` function (line 12), add:

```bash
# Slug a cwd the way claude names its project dir: '/' and '.' -> '-'.
_claude_slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

# Print the current set of candidate transcript files for an agent+cwd, one per line.
# Dirs are env-overridable for testing (ISO_CODEX_SESS, ISO_CLAUDE_PROJ).
_candidate_set() { # $1=codex|claude  $2=cwd
  case "$1" in
    codex)
      find "${ISO_CODEX_SESS:-$HOME/.codex/sessions}" -name 'rollout-*.jsonl' 2>/dev/null | sort ;;
    claude*)
      local d="${ISO_CLAUDE_PROJ:-$HOME/.claude/projects}/$(_claude_slug "$2")"
      find "$d" -maxdepth 1 -name '*.jsonl' 2>/dev/null | sort ;;
  esac
}

# Given a pre-snapshot (newline-joined paths), print the newest file that is in the
# current set but NOT in pre. Empty if none.
_diff_new() { # $1=agent $2=cwd $3=pre(newline-joined)
  local post; post=$(_candidate_set "$1" "$2")
  comm -13 <(printf '%s\n' "$3" | sort) <(printf '%s\n' "$post" | sort) \
    | grep -v '^$' \
    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"; done \
    | sort -rn | head -1 | cut -f2-
}
```

Then add debug branches right after the `__recover` branch's `fi` (so tests can call the helpers directly). Insert before `usage()`:

```bash
if [ "${1:-}" = "--candidate-set" ]; then _candidate_set "$2" "$3"; exit 0; fi
if [ "${1:-}" = "--diff-new" ]; then _diff_new "$2" "$3" "$4"; exit 0; fi
```

Note: `stat -f %m` (BSD/macOS) with `stat -c %Y` (GNU/Linux) fallback keeps mtime sorting portable.

- [ ] **Step 4: Run to verify pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: both snapshot-diff assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/iso-spawn/scripts/spawn.sh skills/iso-spawn/tests/run.sh
git commit -m "feat(iso-spawn): candidate-set snapshot + diff helpers"
```

---

## Task 7: Spawn-time snapshot + `.spawn` sidecar meta block

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh` (steps 1, 3, 7 of the main flow)
- Modify: `skills/iso-spawn/tests/run.sh`

This captures the pre-snapshot **before** `agent start`, then writes the `.spawn` meta block. `__deliver` (Task 8) appends `session_file=`.

- [ ] **Step 1: Add a failing test that a `.spawn` meta file is written**

The full spawn path needs herdr, so this test asserts the meta-writing helper in isolation. Append to `run.sh` before `exit $fail`:

```bash
# --- Task 7: .spawn meta block writer ---
TMP=$(mktemp -d)
SF="$TMP/x.spawn"
"$SPAWN" --write-meta "$SF" term_X codex /tmp/fixture "$(printf '/a.jsonl\n/b.jsonl')"
assert_has "meta has term" "$(cat "$SF")" "term=term_X"
assert_has "meta has agent" "$(cat "$SF")" "agent=codex"
assert_has "meta has cwd" "$(cat "$SF")" "cwd=/tmp/fixture"
assert_has "meta has pre a" "$(cat "$SF")" "pre=/a.jsonl"
assert_has "meta has pre b" "$(cat "$SF")" "pre=/b.jsonl"
rm -rf "$TMP"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — `--write-meta` unknown.

- [ ] **Step 3: Add `_write_meta` helper + debug branch**

In `spawn.sh`, after `_diff_new` (Task 6), add:

```bash
# Write the .spawn meta block. __deliver later appends `session_file=`.
_write_meta() { # $1=spawnfile $2=term $3=agent $4=cwd $5=pre(newline-joined)
  {
    echo "[meta]"
    echo "term=$2"
    echo "agent=$3"
    echo "cwd=$4"
    [ "$3" = claude ] && echo "slug=$(_claude_slug "$4")"
    printf '%s\n' "$5" | grep -v '^$' | while IFS= read -r p; do echo "pre=$p"; done
  } > "$1"
}
```

Add a debug branch before `usage()`:

```bash
if [ "${1:-}" = "--write-meta" ]; then _write_meta "$2" "$3" "$4" "$5" "$6"; exit 0; fi
```

- [ ] **Step 4: Run to verify pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all meta assertions `ok`, exit 0.

- [ ] **Step 5: Wire snapshot + meta into the main spawn flow**

In `spawn.sh` main flow, capture the pre-snapshot just before `agent start`. Find the line (currently spawn.sh:134):

```bash
SR=$(herdr "${START_ARGS[@]}" 2>&1) \
```

Immediately **above** it, insert:

```bash
# Snapshot the candidate transcript set BEFORE the agent starts (race-free mapping).
PRE_SNAPSHOT=$(_candidate_set "$TYPE" "$CWD")
```

Then locate the delivery section (currently spawn.sh:153-169). Replace the whole block from `# 7. Delivery.` through the final `echo "done"` with:

```bash
# 7. Build the per-spawn sidecar path (.iso/logs/spawn or temp fallback) and write meta.
LOGDIR="${TMPDIR:-/tmp}"
if [ -n "$CWD" ] && mkdir -p "$CWD/.iso/logs/spawn" 2>/dev/null; then LOGDIR="$CWD/.iso/logs/spawn"; fi
[ "$TYPE" = claude ] && AGENTLABEL=claude-code || AGENTLABEL=codex
SPAWNFILE="$LOGDIR/$(date +%Y%m%d-%H%M%S)__${AGENTLABEL}__${NAME}__${TERM}.spawn"
_write_meta "$SPAWNFILE" "$TERM" "$TYPE" "$CWD" "$PRE_SNAPSHOT"
echo "spawn-file: $SPAWNFILE"

# 8. Delivery. --wait => synchronous (block, report status). default => detached worker.
# __deliver resolves session_file into SPAWNFILE in both paths (Task 8).
if [ "$WAIT" = 1 ]; then
  "$SELF" __deliver "$TERM" "$PANE" 1 "$WAIT_MS" "$PROMPT" "$SPAWNFILE"
  st=$(herdr agent get "$TERM" 2>/dev/null | jget '["result"]["agent"]["agent_status"]' 2>/dev/null || echo unknown)
  echo "status: $st"
else
  ISO_TRACE=1 nohup "$SELF" __deliver "$TERM" "$PANE" 0 "$WAIT_MS" "$PROMPT" "$SPAWNFILE" >>"$SPAWNFILE" 2>&1 &
  disown 2>/dev/null || true
  [ -n "$PROMPT" ] && echo "delivering prompt in background — monitor: herdr agent get $TERM  |  sidecar: $SPAWNFILE"
fi
echo "done"
```

Note: `echo "spawned: ..."` line (spawn.sh:151) stays as-is above this block. The background worker now appends its trace to `SPAWNFILE` (after the meta block already written by the parent), merging trace + meta into one file.

- [ ] **Step 6: Run the parser tests (must still pass; spawn path untested here)**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all existing assertions still `ok` (no live-spawn test yet; integration smoke test is Task 12).

- [ ] **Step 7: Commit**

```bash
git add skills/iso-spawn/scripts/spawn.sh skills/iso-spawn/tests/run.sh
git commit -m "feat(iso-spawn): snapshot pre-set and write .spawn meta at spawn"
```

---

## Task 8: `__deliver` resolves and appends `session_file=`

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh` (the `__deliver` branch, lines 19-59)

- [ ] **Step 1: Accept SPAWNFILE arg and append session_file after acceptance**

In the `__deliver` branch, change the argument capture line (spawn.sh:21) from:

```bash
  TERM="$2"; PANE="$3"; WAIT="$4"; WAIT_MS="$5"; PROMPT="$6"
```

to:

```bash
  TERM="$2"; PANE="$3"; WAIT="$4"; WAIT_MS="$5"; PROMPT="$6"; SPAWNFILE="${7:-}"
```

Then, immediately after the poll loop's `done` (spawn.sh:56, before the `[ "$WAIT" = 1 ]` line at 57), insert the resolution:

```bash
  # Resolve the agent's transcript now that it is live, and record it in the sidecar.
  if [ -n "$SPAWNFILE" ] && [ -f "$SPAWNFILE" ]; then
    M_AGENT=$(grep '^agent=' "$SPAWNFILE" | head -1 | cut -d= -f2-)
    M_CWD=$(grep '^cwd=' "$SPAWNFILE" | head -1 | cut -d= -f2-)
    M_PRE=$(grep '^pre=' "$SPAWNFILE" | cut -d= -f2-)
    case "$M_AGENT" in claude*) A=claude;; *) A=codex;; esac
    NEWF=$(_diff_new "$A" "$M_CWD" "$M_PRE")
    [ -n "$NEWF" ] && echo "session_file=$NEWF" >> "$SPAWNFILE"
  fi
```

The `_diff_new`, `_candidate_set`, `_claude_slug` functions are defined above the `__deliver` branch? They are NOT — `__deliver` is at the very top (line 19). Move the three helper definitions (`_claude_slug`, `_candidate_set`, `_diff_new`) to **above** the `__deliver` branch (i.e. right after `jget()` on line 12, which Task 6 already did). Confirm their definitions precede line 19 so `__deliver` can call `_diff_new`.

- [ ] **Step 2: Verify helper ordering**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh`
Expected: no syntax error. Then visually confirm `_diff_new` is defined before the `if [ "${1:-}" = "__deliver" ]` line.

- [ ] **Step 3: Unit-test the append path with a fake sidecar**

Append to `run.sh` before `exit $fail`:

```bash
# --- Task 8: __deliver-style session_file append (via _diff_new + grep) ---
TMP=$(mktemp -d); mkdir -p "$TMP/codex/2026/05/27"
touch "$TMP/codex/2026/05/27/rollout-OLD.jsonl"
SF="$TMP/y.spawn"
"$SPAWN" --write-meta "$SF" term_Y codex /tmp/fixture "$TMP/codex/2026/05/27/rollout-OLD.jsonl"
touch "$TMP/codex/2026/05/27/rollout-NEWEST.jsonl"
NEWF=$(ISO_CODEX_SESS="$TMP/codex" "$SPAWN" --diff-new codex /tmp/fixture "$(grep '^pre=' "$SF" | cut -d= -f2-)")
assert_eq "deliver resolves newest as session_file" "$(basename "$NEWF")" "rollout-NEWEST.jsonl"
rm -rf "$TMP"
```

- [ ] **Step 4: Run to verify pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all assertions `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/iso-spawn/scripts/spawn.sh skills/iso-spawn/tests/run.sh
git commit -m "feat(iso-spawn): __deliver records resolved session_file in sidecar"
```

---

## Task 9: `--recover <TERM>` mapping resolution + scrollback fallback

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh` (the `--recover` branch from Task 5)
- Modify: `skills/iso-spawn/tests/run.sh`

- [ ] **Step 1: Add failing test — recover by TERM via a `.spawn` file**

Append to `run.sh` before `exit $fail`:

```bash
# --- Task 9: --recover <TERM> resolves session_file from .spawn sidecar ---
TMP=$(mktemp -d)
cp "$FIX/codex.jsonl" "$TMP/real.jsonl"
SF="$TMP/20260527-000000__codex__t__term_Z.spawn"
{ echo "[meta]"; echo "term=term_Z"; echo "agent=codex"; echo "cwd=/tmp/fixture"; echo "session_file=$TMP/real.jsonl"; } > "$SF"
got=$(ISO_SPAWN_LOGDIR="$TMP" "$SPAWN" --recover term_Z --what output)
assert_eq "recover by TERM uses sidecar session_file" "$got" "FINAL_ANSWER_42"
rm -rf "$TMP"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — current `--recover` requires `--session-file` and errors otherwise.

- [ ] **Step 3: Implement mapping resolution + scrollback fallback**

Replace the `--recover` branch body (from Task 5) so that when `--session-file` is absent it resolves via the sidecar. Replace the section after the `--what`/`--format` validation:

```bash
  if [ -z "$RSESS" ]; then
    [ -n "$RTERM" ] || { echo "error: --recover needs <TERM> or --session-file" >&2; exit 1; }
    # Warn (don't block) if the agent is still working — recovered output may be partial.
    RST=$(herdr agent get "$RTERM" 2>/dev/null | jget '["result"]["agent"]["agent_status"]' 2>/dev/null || echo unknown)
    [ "$RST" = working ] && echo "warning: agent $RTERM is still working; output may be partial" >&2
    # Find the .spawn sidecar for this TERM (search the .iso logdir and temp fallback).
    SF=""
    for base in "${ISO_SPAWN_LOGDIR:-}" "./.iso/logs/spawn" "${TMPDIR:-/tmp}"; do
      [ -n "$base" ] || continue
      cand=$(find "$base" -maxdepth 1 -name "*__${RTERM}.spawn" 2>/dev/null | head -1)
      [ -n "$cand" ] && { SF="$cand"; break; }
    done
    if [ -n "$SF" ]; then
      RAGENT=$(grep '^agent=' "$SF" | head -1 | cut -d= -f2-)
      case "$RAGENT" in claude*) RAGENT=claude;; *) RAGENT=codex;; esac
      RSESS=$(grep '^session_file=' "$SF" | head -1 | cut -d= -f2-)
      M_CWD=$(grep '^cwd=' "$SF" | head -1 | cut -d= -f2-)
      M_PRE=$(grep '^pre=' "$SF" | cut -d= -f2-)
      # Fallbacks if session_file wasn't recorded or no longer exists.
      if [ -z "$RSESS" ] || [ ! -f "$RSESS" ]; then RSESS=$(_diff_new "$RAGENT" "$M_CWD" "$M_PRE"); fi
      if [ -z "$RSESS" ] || [ ! -f "$RSESS" ]; then
        RSESS=$(_candidate_set "$RAGENT" "$M_CWD" | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f"; done | sort -rn | head -1 | cut -f2-)
      fi
    fi
    # Last resort: scrollback scrape (bounded; note the degradation).
    if [ -z "$RSESS" ] || [ ! -f "$RSESS" ]; then
      echo "# source: scrollback (jsonl unmapped; may be truncated)"
      herdr agent read "$RTERM" --source recent --lines 5000 --format text 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["read"]["text"])
except Exception: pass'
      exit 0
    fi
  fi
  [ -n "$RAGENT" ] || { echo "error: --agent required (could not infer)" >&2; exit 1; }
  exec python3 "$SELFDIR/recover.py" "$RAGENT" "$RWHAT" "$RSESS" "$RFMT"
```

- [ ] **Step 4: Run to verify pass**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all assertions `ok` (the `--session-file` seam tests from Task 5 still pass; the new TERM-resolution test passes), exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/iso-spawn/scripts/spawn.sh skills/iso-spawn/tests/run.sh
git commit -m "feat(iso-spawn): --recover resolves transcript by TERM with scrollback fallback"
```

---

## Task 10: `--wait --recover` companion

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh` (arg parser + the `--wait` delivery branch)

- [ ] **Step 1: Add `--recover` as a spawn flag**

In the main option parser (spawn.sh:80-92), add a flag. After the `--wait) WAIT=1; shift;;` line, add:

```bash
    --recover) RECOVER_WHAT="${2:-output}"; case "$RECOVER_WHAT" in output|chat) shift 2;; *) RECOVER_WHAT=output; shift;; esac;;
```

And initialise it with the other defaults (spawn.sh:79). Append to that line:

```bash
RECOVER_WHAT=""
```

- [ ] **Step 2: After `--wait` completes, print recovered output**

In the delivery section (the `if [ "$WAIT" = 1 ]; then` block from Task 7), after the `echo "status: $st"` line, add:

```bash
  if [ -n "$RECOVER_WHAT" ]; then
    echo "--- recovered ($RECOVER_WHAT) ---"
    "$SELF" --recover "$TERM" --what "$RECOVER_WHAT" || true
  fi
```

- [ ] **Step 3: Syntax check**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh`
Expected: no syntax errors.

- [ ] **Step 4: Run parser/unit tests (still green)**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all `ok` (this task's behavior is exercised by the live smoke test in Task 12).

- [ ] **Step 5: Commit**

```bash
git add skills/iso-spawn/scripts/spawn.sh
git commit -m "feat(iso-spawn): --wait --recover prints output after idle"
```

---

## Task 11: Hygiene — gitignore `.iso/` + retention prune

**Files:**
- Modify: `.gitignore` (repo root)
- Modify: `skills/iso-spawn/scripts/spawn.sh`

- [ ] **Step 1: Ignore `.iso/`**

Check current ignore: `git check-ignore .iso || echo "not ignored"` (expected: `not ignored`).

Append to the repo-root `.gitignore` (create the entry if the file exists; if no `.gitignore` exists, create it):

```gitignore
# iso-spawn / IsaiaScope per-run artifacts
.iso/
```

- [ ] **Step 2: Verify it's ignored**

Run: `git check-ignore .iso/logs/spawn/x.spawn`
Expected: prints `.iso/logs/spawn/x.spawn` (now ignored).

- [ ] **Step 3: Add a 7-day retention prune at spawn**

In `spawn.sh`, right after `SPAWNFILE=...` is computed (Task 7, step 5), add:

```bash
# Bound sidecar growth: drop spawn artifacts older than 7 days (best-effort).
find "$LOGDIR" -maxdepth 1 -name '*.spawn' -mtime +7 -delete 2>/dev/null || true
find "$LOGDIR" -maxdepth 1 -name '*.log'   -mtime +7 -delete 2>/dev/null || true
```

- [ ] **Step 4: Syntax check + tests**

Run: `bash -n skills/iso-spawn/scripts/spawn.sh && bash skills/iso-spawn/tests/run.sh`
Expected: no syntax error; all assertions `ok`.

- [ ] **Step 5: Commit**

```bash
git add .gitignore skills/iso-spawn/scripts/spawn.sh
git commit -m "chore(iso-spawn): gitignore .iso/ and prune spawn artifacts >7d"
```

---

## Task 12: Live integration smoke test + docs

**Files:**
- Modify: `skills/iso-spawn/SKILL.md`
- Modify: `skills/iso-spawn/REFERENCE.md`
- Modify: `skills/iso-spawn/README.md`

- [ ] **Step 1: Live smoke test (manual, requires a herdr pane)**

Run from inside a herdr pane:

```bash
skills/iso-spawn/scripts/spawn.sh codex \
  --prompt "Reply with EXACTLY this one line and nothing else, then stop: SMOKE_TOKEN=lima-77" \
  --name smoketest --wait --recover output
```

Expected: ends with
```
--- recovered (output) ---
SMOKE_TOKEN=lima-77
```
(exact token, single line, no box chrome). Then verify standalone recovery using the `term=` printed in the `spawned:` line:

```bash
TERM=$(herdr agent list | python3 -c 'import json,sys
for a in json.load(sys.stdin)["result"]["agents"]:
  if (a.get("name") or "").startswith("smoketest"): print(a["terminal_id"])')
skills/iso-spawn/scripts/spawn.sh --recover "$TERM" --what chat | head
```
Expected: ordered transcript containing the prompt and `SMOKE_TOKEN=lima-77`.

Clean up:
```bash
herdr agent list | python3 -c 'import json,sys
for a in json.load(sys.stdin)["result"]["agents"]:
  if (a.get("name") or "").startswith("smoketest"): print(a["tab_id"])' \
  | while read t; do herdr tab close "$t"; done
```

- [ ] **Step 2: Document `--recover` in SKILL.md**

In `skills/iso-spawn/SKILL.md`, add to the options table (after the `--wait` row):

```markdown
| `--recover [output\|chat]` | with `--wait`: after the agent goes idle, print its recovered output (default `output`) |
```

And add a new section after "Verify / monitor":

```markdown
## Recover output

After an agent finishes, pull its work from its native transcript (codex/claude JSONL),
keyed off the `term` printed at spawn:

```bash
# clean final answer
scripts/spawn.sh --recover <TERM>

# full transcript for debugging
scripts/spawn.sh --recover <TERM> --what chat

# block on a task then print its answer in one call
scripts/spawn.sh codex --prompt "…" --wait --recover
```

`--recover` reads the `.spawn` sidecar (written at spawn) to map `<TERM>` to the agent's
transcript file. If the transcript can't be mapped it falls back to herdr scrollback
(bounded; may be truncated on long runs), printing a `# source: scrollback` header.
```

- [ ] **Step 3: Document the `.spawn` sidecar in REFERENCE.md**

In `skills/iso-spawn/REFERENCE.md`, under "Delivery model", add:

```markdown
### The `.spawn` sidecar (one file per spawn)

`<cwd>/.iso/logs/spawn/<date>__<agent>__<name>__<TERM>.spawn` holds two regions:
- **meta** (always, both `--wait` and background): `term=`, `agent=`, `cwd=`, `slug=`
  (claude), `pre=` (the candidate transcript set snapshotted before `agent start`), and
  `session_file=` (the resolved transcript, appended by `__deliver` after the agent boots).
- **trace** (background always; `--wait` only when `ISO_TRACE=1`): the delivery xtrace
  used to diagnose a silently-lost prompt / worker death / unrecognised trust modal.

`--recover <TERM>` reads the meta region; debugging reads the trace region. This file
replaces the former `.log` — same one-file-per-spawn footprint, now carrying the mapping.

Transcript sources: codex `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
(final answer = `event_msg`/`agent_message`); claude `~/.claude/projects/<slug>/*.jsonl`
(`slug` = cwd with `/` and `.` → `-`; final answer = last `assistant` message with text).
Mapping is race-free: the new file is the one that appears between the pre- and
post-`agent start` snapshots, so concurrent same-cwd spawns each resolve distinctly.
```

- [ ] **Step 4: Update README.md feature list**

In `skills/iso-spawn/README.md`, add a bullet to the feature/quick-start area describing
`--recover` (clean final answer or full transcript, via the agent's native JSONL with a
scrollback fallback). Match the README's existing tone and structure.

- [ ] **Step 5: Run the full test suite once more**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: every assertion `ok`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add skills/iso-spawn/SKILL.md skills/iso-spawn/REFERENCE.md skills/iso-spawn/README.md
git commit -m "docs(iso-spawn): document --recover and the .spawn sidecar"
```

---

## Notes for the implementer

- **Debug branches** (`--candidate-set`, `--diff-new`, `--write-meta`) exist purely to make
  the bash logic unit-testable without herdr. They are harmless (undocumented, internal) and
  may stay; do not remove them or the tests break.
- **Portability:** mtime uses `stat -f %m` (macOS) with `stat -c %Y` (Linux) fallback. Keep
  both.
- **No live agent in `run.sh`:** every assertion runs against committed fixtures or temp dirs.
  Live behavior is the manual smoke test in Task 12.
- **`set -euo pipefail` in `__deliver`:** keep guarding every herdr call with `|| true`
  (REFERENCE.md:86-92). The new `session_file` resolution uses only `grep`/`_diff_new` on
  local files; ensure a no-match `grep` can't abort the worker (it runs inside the `if
  [ -f "$SPAWNFILE" ]` guard, and `grep` returning 1 on no match is acceptable there because
  the results are captured in `$(...)`, which does not trip `set -e`).
```

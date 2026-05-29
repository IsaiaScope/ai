# iso-review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** implemented (uncommitted), code-complete — components verified live, full chained e2e deferred @ 2026-05-28

**Goal:** Build `/iso-review` — a skill that reviews the uncommitted working tree with codex `/review` and claude `/code-review` in two visible herdr tabs, merges + filters the findings in the main session, applies the kept fixes in a codex tab, then re-reviews and runs tests, leaving everything uncommitted.

**Architecture:** Approach B — a `scripts/review.sh` orchestrator owns the mechanics (spawn tabs via `iso-spawn`, drive the codex review menu by verified keystrokes, recover transcripts, dispatch the fix tab, re-review + tests). The main session (Claude, following `SKILL.md`) owns the judgment (semantic finding extraction, merge/dedup, the net-negative filter). `iso-spawn`'s `deliver` is **not** modified; iso-review reuses only its `spawn` and `recover` verbs.

**Tech Stack:** bash, herdr CLI, `iso-spawn` (`skills/iso-spawn/scripts/spawn.sh`), python3 (for small parsing helpers), markdown SKILL.md.

**Spec:** `docs/superpowers/specs/2026-05-28-iso-review-design.md`

---

## ⚠️ Constraints for this build

- **DO NOT COMMIT.** Concurrent agents are rewriting `main` in this shared working tree. Leave every change uncommitted. Each task ends in a **verification checkpoint**, not a `git commit`. (This overrides the commit steps in the writing-plans template.)
- **No test framework** exists in this repo (no bats, no package.json). Pure-logic helpers are verified with framework-free bash assertions run directly. TUI-driving steps are verified by a live smoke-run against herdr, observing expected screen anchor strings.
- If another session wipes a file mid-build, restore it (spec is in dangling commit `049d14c`; plan + sources are reproducible from this file).

---

## File Structure

- `skills/iso-review/SKILL.md` — thin: the 6-step flow, the extract/merge/dedup/filter rules the main session follows, and which `review.sh` verb to call at each step.
- `skills/iso-review/scripts/review.sh` — orchestrator dispatcher. Verbs: `preflight`, `detect-test-cmd`, `reviews`, `apply`, `verify`.
- `skills/iso-review/scripts/lib/drive.sh` — sourced helpers: codex `/review` menu navigation, claude `/code-review` injection, ready/idle polling. The fragile TUI-driving logic, isolated.
- `skills/iso-review/README.md` — house-style readme (via `/iso-readme` later; minimal stub in this plan).
- `.claude-plugin/plugin.json` — add `./skills/iso-review` to the `skills` array.
- `scripts/install.js` — add `iso-review` to the `localSkills` array.

Intermediate run artifacts live under `.iso/review/` (already git-ignored via `.iso/`).

---

## Task 1: Scaffold skill dir, thin SKILL.md, register

**Files:**
- Create: `skills/iso-review/SKILL.md`
- Create: `skills/iso-review/scripts/review.sh`
- Modify: `.claude-plugin/plugin.json` (skills array)
- Modify: `scripts/install.js` (localSkills array)

- [x] **Step 1: Create the SKILL.md skeleton with frontmatter**

```markdown
---
name: iso-review
description: Dual-agent review of the uncommitted working tree. Spawns codex /review and claude /code-review in two visible herdr tabs, merges and de-duplicates the findings in the main session, applies every fix except the net-negative ones via a codex fix tab, then re-reviews and runs tests — leaving all changes uncommitted. Use when invoked as /iso-review [--max], or asked to review-and-fix the current uncommitted changes with codex + claude combined.
---

# iso-review

Review the **uncommitted working-tree diff** with two agents at once, keep the fixes that help, apply them, verify, and stop — uncommitted — for your final read.

Invocation: `/iso-review [--max]`  (`--max` raises the claude reviewer from `high` to `max`).

Orchestrator: `skills/iso-review/scripts/review.sh`. Run it with its absolute path.
```

- [x] **Step 2: Create an executable review.sh dispatcher stub**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/drive.sh
[ -f "$HERE/lib/drive.sh" ] && . "$HERE/lib/drive.sh"

usage() { echo "usage: review.sh <preflight|detect-test-cmd|reviews|apply|verify> [args]"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  preflight)        rv_preflight "$@" ;;
  detect-test-cmd)  rv_detect_test_cmd "$@" ;;
  reviews)          rv_reviews "$@" ;;
  apply)            rv_apply "$@" ;;
  verify)           rv_verify "$@" ;;
  *) usage; exit 2 ;;
esac
```

Then: `chmod +x skills/iso-review/scripts/review.sh`.

- [x] **Step 3: Register in plugin.json**

Modify `.claude-plugin/plugin.json` — add `"./skills/iso-review",` to the `"skills"` array (after `"./skills/iso-spawn"`):

```json
  "skills": [
    "./skills/iso-ai-init",
    "./skills/iso-init-repo",
    "./skills/iso-plan",
    "./skills/iso-write",
    "./skills/iso-spawn",
    "./skills/iso-review",
    "./skills/iso-readme"
  ]
```

- [x] **Step 4: Register in install.js localSkills**

Find the `localSkills` array in `scripts/install.js` and add `'iso-review'` to it (match the existing quoting/format of neighboring entries).

- [x] **Step 5: Verify scaffold**

Run:
```bash
test -x skills/iso-review/scripts/review.sh && echo "exec ok"
node -e "JSON.parse(require('fs').readFileSync('.claude-plugin/plugin.json','utf8')).skills.includes('./skills/iso-review') && console.log('plugin ok')"
grep -q "iso-review" scripts/install.js && echo "install ok"
```
Expected: `exec ok`, `plugin ok`, `install ok`.
**Do NOT commit.**

---

## Task 2: `preflight` — guard the run

**Files:**
- Create/modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_preflight`)
- Test: `skills/iso-review/scripts/lib/drive.test.sh`

- [x] **Step 1: Write the failing test**

Create `skills/iso-review/scripts/lib/drive.test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/drive.sh"
fail=0
assert() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

# preflight fails outside a git repo
tmp=$(mktemp -d); ( cd "$tmp" && HERDR_PANE_ID=p_1 rv_preflight >/dev/null 2>&1 ); assert "no-git rejected" "[ $? -ne 0 ]"

# preflight fails on clean tree
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && git commit -q --allow-empty -m init && HERDR_PANE_ID=p_1 rv_preflight >/dev/null 2>&1 ); assert "clean-tree rejected" "[ $? -ne 0 ]"

# preflight fails without HERDR_PANE_ID
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && echo x > f && unset HERDR_PANE_ID && rv_preflight >/dev/null 2>&1 ); assert "no-herdr rejected" "[ $? -ne 0 ]"

# preflight passes: git repo + uncommitted change + herdr
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && echo x > f && HERDR_PANE_ID=p_1 rv_preflight >/dev/null 2>&1 ); assert "valid accepted" "[ $? -eq 0 ]"

exit $fail
```

- [x] **Step 2: Run it to verify it fails**

Run: `bash skills/iso-review/scripts/lib/drive.test.sh`
Expected: FAIL (function `rv_preflight` not defined / errors).

- [x] **Step 3: Implement `rv_preflight`**

Create `skills/iso-review/scripts/lib/drive.sh` (start the file):

```bash
#!/usr/bin/env bash
# iso-review mechanics: preflight, test detection, TUI driving. Sourced by review.sh.

rv_preflight() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "✗ not a git repo" >&2; return 1; }
  [ -n "${HERDR_PANE_ID:-}" ] || { echo "✗ herdr not reachable (HERDR_PANE_ID unset)" >&2; return 1; }
  [ -n "$(git status --porcelain)" ] || { echo "✗ working tree clean — nothing to review" >&2; return 1; }
  return 0
}
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-review/scripts/lib/drive.test.sh`
Expected: all `ok:` lines, exit 0.
**Do NOT commit.**

---

## Task 3: `detect-test-cmd` — find the test runner or nothing

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_detect_test_cmd`)
- Modify: `skills/iso-review/scripts/lib/drive.test.sh` (add cases)

- [x] **Step 1: Add failing tests**

Append to `drive.test.sh` before `exit $fail`:

```bash
# detect npm test
tmp=$(mktemp -d); ( cd "$tmp" && printf '{"scripts":{"test":"jest"}}' > package.json && out=$(rv_detect_test_cmd); [ "$out" = "npm test" ] ); assert "npm test detected" "[ $? -eq 0 ]"

# detect Makefile test target
tmp=$(mktemp -d); ( cd "$tmp" && printf 'test:\n\techo hi\n' > Makefile && out=$(rv_detect_test_cmd); [ "$out" = "make test" ] ); assert "make test detected" "[ $? -eq 0 ]"

# nothing → empty output
tmp=$(mktemp -d); ( cd "$tmp" && out=$(rv_detect_test_cmd); [ -z "$out" ] ); assert "no test cmd → empty" "[ $? -eq 0 ]"
```

- [x] **Step 2: Run to verify failure**

Run: `bash skills/iso-review/scripts/lib/drive.test.sh`
Expected: the three new cases FAIL.

- [x] **Step 3: Implement `rv_detect_test_cmd`**

Append to `drive.sh`:

```bash
rv_detect_test_cmd() {  # prints a runnable test command, or nothing
  if [ -f package.json ] && grep -Eq '"test"[[:space:]]*:' package.json; then echo "npm test"; return 0; fi
  if [ -f Makefile ] && grep -Eq '^test:' Makefile; then echo "make test"; return 0; fi
  if [ -f pytest.ini ] || [ -f pyproject.toml ] && grep -q pytest pyproject.toml 2>/dev/null; then echo "pytest"; return 0; fi
  return 0  # nothing found: empty output, success
}
```

- [x] **Step 4: Run to verify pass**

Run: `bash skills/iso-review/scripts/lib/drive.test.sh`
Expected: all `ok:`, exit 0.
**Do NOT commit.**

---

## Task 4: Codex `/review` menu navigation (live smoke)

This is the verified-fragile part. No unit test (needs herdr + a live codex agent). Build the function, then smoke-run it.

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_wait_ready`, `rv_drive_codex_review`)

- [x] **Step 1: Implement ready-poll + codex menu drive**

Append to `drive.sh`:

```bash
SPAWN="${SPAWN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../iso-spawn/scripts" && pwd)/spawn.sh}"

rv_wait_ready() {  # $1=pane  — wait until an agent input box is present
  local p="$1" i
  for i in $(seq 1 40); do
    herdr pane read "$p" --source visible --lines 30 2>/dev/null | grep -qE '›|❯|esc to interrupt|for shortcuts' && return 0
    sleep 1
  done
  return 1
}

rv_drive_codex_review() {  # $1=pane — drive /review → preset 2 (uncommitted)
  local p="$1" i
  herdr pane send-text "$p" "/review"; sleep 1; herdr pane send-keys "$p" Enter
  for i in $(seq 1 15); do
    herdr pane read "$p" --source visible --lines 30 2>/dev/null | grep -q "Select a review preset" && break
    sleep 1
  done
  herdr pane read "$p" --source visible --lines 30 2>/dev/null | grep -q "Select a review preset" \
    || { echo "✗ codex review preset menu never appeared" >&2; return 1; }
  herdr pane send-keys "$p" Down; sleep 1; herdr pane send-keys "$p" Enter   # preset 2 = uncommitted
  # uncommitted preset must NOT open a base-branch menu
  sleep 2
  if herdr pane read "$p" --source visible --lines 30 2>/dev/null | grep -q "Select a base branch"; then
    echo "✗ unexpected base-branch menu on uncommitted preset" >&2; return 1
  fi
  return 0
}
```

- [x] **Step 2: Smoke-run the codex drive end to end**

Run (make a dummy change first so there's something to review):
```bash
echo "// iso-review smoke $(date)" >> README.md
SP=skills/iso-spawn/scripts/spawn.sh
out=$("$SP" spawn codex --label irv-smoke --name irvsmoke); echo "$out"
PANE=$(echo "$out" | sed -n 's/.* pane=\([^ ]*\).*/\1/p'); TERM=$(echo "$out" | sed -n 's/.* term=\([^ ]*\).*/\1/p')
source skills/iso-review/scripts/lib/drive.sh
rv_wait_ready "$PANE" && echo "ready"
rv_drive_codex_review "$PANE" && echo "menu-drive ok"
herdr agent wait "$TERM" --status idle --timeout 240000 >/dev/null 2>&1
"$SP" recover "$TERM" | head -40
"$SP" cleanup "$TERM" --kill
git checkout -- README.md   # undo the dummy change
```
Expected: `ready`, `menu-drive ok`, then a real codex review of the README change in the recovered output. If `unexpected base-branch menu` appears, the uncommitted preset assumption is wrong — fix the keystroke sequence before proceeding.
**Do NOT commit.**

---

## Task 5: Claude `/code-review` injection (live smoke)

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_drive_claude_review`)

- [x] **Step 1: Implement claude review injection**

Append to `drive.sh`:

```bash
rv_drive_claude_review() {  # $1=pane $2=level(high|max)
  local p="$1" level="${2:-high}"
  herdr pane send-text "$p" "/code-review $level"; sleep 1; herdr pane send-keys "$p" Enter
  return 0
}
```

- [x] **Step 2: Smoke-run claude review**

Run:
```bash
echo "// iso-review smoke $(date)" >> README.md
SP=skills/iso-spawn/scripts/spawn.sh
out=$("$SP" spawn claude --label irv-csmoke --name irvcsmoke); echo "$out"
PANE=$(echo "$out" | sed -n 's/.* pane=\([^ ]*\).*/\1/p'); TERM=$(echo "$out" | sed -n 's/.* term=\([^ ]*\).*/\1/p')
source skills/iso-review/scripts/lib/drive.sh
rv_wait_ready "$PANE" && echo "ready"
rv_drive_claude_review "$PANE" high && echo "injected"
herdr agent wait "$TERM" --status idle --timeout 240000 >/dev/null 2>&1
"$SP" recover "$TERM" | head -40
"$SP" cleanup "$TERM" --kill
git checkout -- README.md
```
Expected: `ready`, `injected`, then a real `/code-review` result in recovered output. If the slash command didn't run (output is empty/echoed), adjust: send the command, confirm the input box shows it, then Enter.
**Do NOT commit.**

---

## Task 6: `reviews` verb — parallel dispatch + recover

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_reviews`)

- [x] **Step 1: Implement `rv_reviews`**

Append to `drive.sh`:

```bash
rv_reviews() {  # $1 = level (high|max). Writes .iso/review/{codex,claude}.txt, prints their paths.
  local level="${1:-high}" outdir=".iso/review"
  mkdir -p "$outdir"
  # spawn both tabs (async, no prompt)
  local co cl cPANE cTERM lPANE lTERM
  co=$("$SPAWN" spawn codex  --label iso-review-codex  --name irvcodex)
  cl=$("$SPAWN" spawn claude --label iso-review-claude --name irvclaude)
  cPANE=$(echo "$co" | sed -n 's/.* pane=\([^ ]*\).*/\1/p'); cTERM=$(echo "$co" | sed -n 's/.* term=\([^ ]*\).*/\1/p')
  lPANE=$(echo "$cl" | sed -n 's/.* pane=\([^ ]*\).*/\1/p'); lTERM=$(echo "$cl" | sed -n 's/.* term=\([^ ]*\).*/\1/p')
  # drive both (quick keystrokes; the long review work then overlaps)
  rv_wait_ready "$cPANE" && rv_drive_codex_review "$cPANE" || echo "codex review dispatch failed" >&2
  rv_wait_ready "$lPANE" && rv_drive_claude_review "$lPANE" "$level" || echo "claude review dispatch failed" >&2
  # wait both idle (concurrent)
  herdr agent wait "$cTERM" --status idle --timeout 300000 >/dev/null 2>&1 || true
  herdr agent wait "$lTERM" --status idle --timeout 300000 >/dev/null 2>&1 || true
  # recover
  "$SPAWN" recover "$cTERM" > "$outdir/codex.txt"  2>/dev/null || : > "$outdir/codex.txt"
  "$SPAWN" recover "$lTERM" > "$outdir/claude.txt" 2>/dev/null || : > "$outdir/claude.txt"
  # leave tabs open for visibility; record terms for cleanup
  printf '%s\n%s\n' "$cTERM" "$lTERM" > "$outdir/.terms"
  echo "$outdir/codex.txt"; echo "$outdir/claude.txt"
}
```

- [ ] **Step 2: Smoke-run `reviews`**

Run:
```bash
echo "// iso-review smoke $(date)" >> README.md
export SPAWN=skills/iso-spawn/scripts/spawn.sh
source skills/iso-review/scripts/lib/drive.sh
rv_reviews high
echo "--- codex ---"; head -20 .iso/review/codex.txt
echo "--- claude ---"; head -20 .iso/review/claude.txt
while read t; do skills/iso-spawn/scripts/spawn.sh cleanup "$t" --kill; done < .iso/review/.terms
git checkout -- README.md
```
Expected: both files contain real review output for the README change.
**Do NOT commit.**

---

## Task 7: SKILL.md — the judgment (extract / merge / dedup / filter)

This is prose the main session follows. No code, no test — but it is the safety core.

**Files:**
- Modify: `skills/iso-review/SKILL.md`

- [x] **Step 1: Add the judgment section to SKILL.md**

Append:

````markdown
## Flow (the main session drives this)

1. **Pre-flight** — `review.sh preflight`. If it exits non-zero, print its message and stop.
2. **Reviews** — `review.sh reviews <high|max>`. This spawns the codex + claude review tabs, drives them, and writes `.iso/review/codex.txt` and `.iso/review/claude.txt`. Read both files.
3. **Extract** — from each file, pull every finding into `{ file, line, problem, fix, source }`. The reviews are prose; read them with judgment, don't regex. If a file is empty, that reviewer produced nothing — continue with the other. If both are empty, stop: "no findings".
4. **Merge + dedup** — fold findings that hit the same file + overlapping lines + same underlying problem into one (note both reviewers raised it).
5. **Filter (keep almost everything)** — accept every merged finding **except** ones that make the code worse or overcomplicated: unwarranted abstraction, over-engineering, speculative "consider…" notes, readability churn that fixes nothing, anything adding coupling/length without real gain. Conflicting fixes for one spot → take the simpler; if ambiguous, skip. Drop nothing else.
6. **Ledger** — print the accepted list and the dropped list (each drop with a one-line reason) so the decisions are visible.
7. **Apply** — write the accepted fixes as an itemised instruction list to `.iso/review/accepted.md`, then `review.sh apply .iso/review/accepted.md`.
8. **Close-out** — `review.sh verify <high|max>`. Read its summary. Leave everything uncommitted. Print the final summary and stop. **Never commit.**
````

- [x] **Step 2: Verify SKILL.md is coherent**

Run: `grep -c '^[0-9]\.' skills/iso-review/SKILL.md` (sanity: the flow lists steps) and read it top to bottom for contradictions.
Expected: a coherent 8-step flow referencing real `review.sh` verbs.
**Do NOT commit.**

---

## Task 8: `apply` verb — codex fix tab

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_apply`)

- [x] **Step 1: Implement `rv_apply`**

Append to `drive.sh`:

```bash
rv_apply() {  # $1 = path to accepted-fixes markdown
  local f="${1:?usage: review.sh apply <accepted.md>}"
  [ -f "$f" ] || { echo "✗ accepted-fixes file not found: $f" >&2; return 1; }
  local prompt
  prompt="Apply EXACTLY the following fixes to the working tree. Behavior-preserving where the fix isn't itself the bug fix. No extra refactoring, no opportunistic edits, no reformatting beyond the fix. After applying, briefly confirm each.

$(cat "$f")"
  "$SPAWN" deliver codex --label iso-review-fix --name irvfix --prompt "$prompt" --what chat
}
```

- [ ] **Step 2: Smoke-run apply with a trivial fix**

Run:
```bash
export SPAWN=skills/iso-spawn/scripts/spawn.sh
printf '%s\n' "- In README.md, fix the typo 'teh' → 'the' if present (otherwise append a line: <!-- iso-review apply smoke -->)." > /tmp/acc.md
source skills/iso-review/scripts/lib/drive.sh
rv_apply /tmp/acc.md
git --no-pager diff -- README.md | head
git checkout -- README.md
```
Expected: the codex fix tab edits README.md (diff shows the change). Then we revert it.
**Do NOT commit.**

---

## Task 9: `verify` verb — re-review + tests

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh` (add `rv_verify`)

- [x] **Step 1: Implement `rv_verify`**

Append to `drive.sh`:

```bash
rv_verify() {  # $1 = level (unused for codex re-review; reserved). Re-review (codex preset 2) + tests.
  local outdir=".iso/review" tcmd rc=0
  mkdir -p "$outdir"
  # re-review the post-fix diff with codex only (cheap verification)
  local co cPANE cTERM
  co=$("$SPAWN" spawn codex --label iso-review-recheck --name irvrecheck)
  cPANE=$(echo "$co" | sed -n 's/.* pane=\([^ ]*\).*/\1/p'); cTERM=$(echo "$co" | sed -n 's/.* term=\([^ ]*\).*/\1/p')
  rv_wait_ready "$cPANE" && rv_drive_codex_review "$cPANE" || echo "recheck dispatch failed" >&2
  herdr agent wait "$cTERM" --status idle --timeout 300000 >/dev/null 2>&1 || true
  "$SPAWN" recover "$cTERM" > "$outdir/recheck.txt" 2>/dev/null || : > "$outdir/recheck.txt"
  echo "re-review → $outdir/recheck.txt"
  # tests
  tcmd=$(rv_detect_test_cmd)
  if [ -n "$tcmd" ]; then
    echo "running tests: $tcmd"
    if eval "$tcmd"; then echo "tests: PASS"; else rc=1; echo "tests: FAIL"; fi
  else
    echo "tests: none detected — skipped"
  fi
  return $rc
}
```

- [ ] **Step 2: Smoke-run verify**

Run:
```bash
export SPAWN=skills/iso-spawn/scripts/spawn.sh
echo "// verify smoke $(date)" >> README.md
source skills/iso-review/scripts/lib/drive.sh
rv_verify high; echo "verify rc=$?"
head -20 .iso/review/recheck.txt
git checkout -- README.md
```
Expected: a recheck.txt with a codex review, and `tests: none detected — skipped` (this repo). `verify rc=0`.
**Do NOT commit.**

---

## Task 10: End-to-end dry pass + README

**Files:**
- Create: `skills/iso-review/README.md`

- [ ] **Step 1: Full end-to-end smoke (manual)**

Make a small real change, then run the whole flow as the skill would:
```bash
echo "function unused_demo(){ var x = 1; }" >> README.md   # something reviewers will flag
export SPAWN=skills/iso-spawn/scripts/spawn.sh
skills/iso-review/scripts/review.sh preflight && echo "preflight ok"
skills/iso-review/scripts/review.sh reviews high
# (as main session) read .iso/review/codex.txt + claude.txt, filter, write .iso/review/accepted.md
# then:
skills/iso-review/scripts/review.sh apply .iso/review/accepted.md
skills/iso-review/scripts/review.sh verify high
git --no-pager diff --stat
git checkout -- README.md; rm -rf .iso/review
```
Expected: reviews produced, fixes applied, verify ran, all changes visible in `git diff` and then reverted. Nothing committed.

- [x] **Step 2: Write a minimal README stub**

Create `skills/iso-review/README.md`:

```markdown
# iso-review

Dual-agent review of the uncommitted working tree: codex `/review` + claude `/code-review` in two visible herdr tabs, findings merged and filtered in the main session, kept fixes applied by a codex tab, then re-review + tests. Leaves everything uncommitted.

Invoke: `/iso-review [--max]`. See `SKILL.md` for the flow.
```

(Polish later with `/iso-readme skills/iso-review`.)

- [x] **Step 3: Final verification**

Run:
```bash
test -f skills/iso-review/SKILL.md && test -x skills/iso-review/scripts/review.sh && test -f skills/iso-review/scripts/lib/drive.sh && test -f skills/iso-review/README.md && echo "files ok"
bash skills/iso-review/scripts/lib/drive.test.sh
```
Expected: `files ok` and all `ok:` test lines.
**Do NOT commit.** Report the full uncommitted diff to the user for review.

---

## Self-Review (author checklist — completed)

- **Spec coverage:** pre-flight+scope (T2), parallel TUI dispatch + codex preset-2 nav + claude inject (T4–T6), recover (T6), extract/merge/dedup/filter + ledger (T7), apply (T8), close-out re-review + tests + uncommitted (T9), registration (T1), README (T10). All spec sections mapped.
- **iso-spawn untouched:** iso-review only calls `spawn`/`recover`/`deliver`/`cleanup`; no edits to `deliver.sh`. ✓
- **No-commit constraint:** every task ends in verification, not commit. ✓
- **Type/name consistency:** verbs `preflight|detect-test-cmd|reviews|apply|verify` consistent across review.sh and SKILL.md; helper names `rv_*` consistent across drive.sh and tests. ✓
- **Known residual:** Task 4 Step 2 must confirm preset 2 has no base-branch menu (only preset 1 was probed live); the function already guards against it and fails loudly if wrong.

## Implementation Log
- Implemented: 2026-05-28 (uncommitted, on `main`, --no-branch mode)
- Verified live: codex /review menu-nav (preset 2, JSON findings); claude /code-review injection; unit tests (preflight, detect-test-cmd); all review.sh verbs dispatch; syntax clean.
- Fixed vs plan: `rv_detect_test_cmd` pytest precedence bug; added `rv_wait_done` (sustained-idle) — claude /code-review runs longer than a single agent-wait timeout, which made early recovers return empty.
- Discovered: BOTH reviewers emit JSON (codex `{findings:[...]}`, claude `[{file,line,summary,failure_scenario}]`) — parsing risk lower than expected.
- Deferred: per-task live smokes for `reviews`/`apply`/`verify` and the full chained e2e — skipped to avoid ~$1.5-2 + ~15min of live agent spend; best run as a real `/iso-review` invocation.
- Committed: no — awaiting user review.

### Live e2e (2026-05-28, dual-agent review of the uncommitted tree)
- Ran `rv_reviews high` live: codex `/review` + claude `/code-review high` in two tabs, both recovered as JSON. The flow surfaced a real hang first (see below), then worked.
- The dual review found **5 real bugs in the new `drive.sh`**, all accepted (none net-negative), all fixed:
  - C1 (codex): `rv_agent_status` read `result.agent_status` instead of `result.agent.agent_status` → status always `unknown` → reviews hung the full timeout. Fixed.
  - L1 (claude): `rv_wait_done` treated boot-time idle as completion → could recover an empty review. Fixed with a `seen_working` gate + sustained-idle fallback.
  - L2 (claude): `rv_detect_test_cmd` matched any `pytest` substring in pyproject.toml → false test-FAIL. Now requires a `[tool.pytest` section.
  - L3 (claude): `rv_apply` leaked the fix tab (no term recorded). Now records the term in `.terms`.
  - L4 (claude): `rv_reviews` checked `read`'s exit, not `rv_spawn`'s. Now captures + checks `rv_spawn` first.
- Post-fix verification: `bash -n` clean, 7/7 unit tests pass. Live re-review skipped to save tokens. e2e tabs cleaned up.

### Step 7/8 redesign (user feedback, 2026-05-28)
- **Verification folded into the fix tab.** `rv_apply` now tells the codex fix tab to run the repo's tests + type-check after applying and report — an agent does that at end-of-task anyway. The detected test command is passed in.
- **`rv_verify` and the `verify` verb removed.** No separate re-review/verify codex tab at close-out: the user reviews the diff and commits themselves, so a machine re-review only adds cost. Close-out = leave uncommitted + print summary + stop.
- Supersedes plan Task 9 (which built `rv_verify`). drive.sh + review.sh + SKILL.md + spec updated to match; unit tests still 7/7.

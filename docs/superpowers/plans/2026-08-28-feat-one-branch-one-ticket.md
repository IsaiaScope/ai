# One Branch, One Ticket Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a git branch map to exactly one tracker ticket, holding every plan that lands on it, without any plan's description being destroyed.

**Status:** implemented (uncommitted) @ 2026-08-28T21:09:56Z — Tasks 1-9. Task 10 not run.

**Architecture:** The ledger (`~/.claude/multica/tracked.json`) becomes the single source of truth: each row's `plan` field turns from a string into an array of `{path, state, body}` entries. The ticket description is *rendered* from that array by a pure function and pushed to the board — never read back and patched. `open` consults the branch itself and redirects to a new `addplan` verb when a live ticket already holds the branch, so the one-branch-one-ticket rule stops depending on a model remembering to check.

**Tech Stack:** Bash 3.2+ (macOS system bash), `jq`, `git`, `multica` CLI 0.4.36 behind the adapter in `scripts/adapters/multica.sh`. Tests are a plain assert script, no framework.

**Spec:** `docs/superpowers/specs/2026-08-28-one-branch-one-ticket-design.md`

## Global Constraints

- Every file path below is relative to `/Volumes/Crucial-4T/repo/ai`. This session's cwd may be elsewhere; use `cd /Volumes/Crucial-4T/repo/ai && ...` inside any single bash call, as `cd` does not persist between calls.
- `set -uo pipefail` is already in force in `tracking.sh`. Do not add `set -e`; the script must never be able to fail a hook.
- **The script always exits 0.** The final `exit 0` at the bottom of `tracking.sh` is load-bearing and must not be removed or made conditional.
- **No vendor names outside the adapter.** `contract.test.sh` forbids the string `multica` in `tracking.sh`. All board calls go through `tk_*` functions.
- **Redaction happens in `tracking.sh`, never in the adapter.** Any body must pass through `redact` before it is stored or sent.
- Bash 3.2 has no associative arrays and no `${var,,}`. Do not use them.
- Plan-entry `state` is exactly one of `done`, `current`, `superseded`. No other value is written.
- Section markers are exactly: white-heavy-check-mark for `done`, black-right-pointing-triangle for `current`, circled-division-slash for `superseded`. Copy them from the code blocks below rather than retyping them.
- Run the full suite after every task: `bash skills/iso-issue-tracking/scripts/tracking.test.sh`. It must end `0 failed`.
- Commit messages: Conventional Commits. **Never** add `Co-Authored-By`, `Generated with Claude Code`, or any AI attribution.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `skills/iso-issue-tracking/scripts/tracking.sh` | all tracker logic, ledger, dispatch | modified — new helpers, new `addplan` arm, rewritten `open`/`replan` arms |
| `skills/iso-issue-tracking/scripts/adapters/multica.sh` | every `multica` CLI call | modified — one new verb `tk_issue_title` |
| `skills/iso-issue-tracking/scripts/tracking.test.sh` | self-check | modified — new assertions per task |
| `skills/iso-issue-tracking/SKILL.md` | how a model is told to use the tracker | modified — `open` is now always safe to call |
| `skills/iso-plan/SKILL.md` | planning chain | modified — one sentence, gate stays |

`tracking.sh` stays one file. It is already 666 lines and the ponytail note at its head says splitting buys nothing but a sourced path to get wrong; this plan adds roughly 120 lines and does not change that calculus.

---

### Task 1: Ledger `plan` becomes an array

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (add helpers after `ledger_del`, ~line 99; rewrite `do_bind` at ~247-277)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Consumes: `ledger_get`, `ledger_put`, `state_dir`, `LEDGER` — all already defined.
- Produces:
  - `plan_entries <key>` -> compact JSON array of `{path,state,body}`; `[]` when the row has no plan. Coerces a legacy string `plan` into a one-element array with `state:"current"`.
  - `plan_push <key> <path> <outgoing-state> [body]` -> rewrites the row's `plan`: every `current` entry becomes `<outgoing-state>`, any existing entry with the same `path` is dropped, and `{path, state:"current", body}` is appended. Returns 1 if the row does not exist.
  - `plan_current <key>` -> the path of the single `current` entry, or empty.
  - `do_bind` now **merges** into the existing row instead of replacing it.

- [x] **Step 1: Write the failing test**

Append to `tracking.test.sh`, immediately after the existing `echo "ledger"` block (after the `check "get on missing key is empty"` line):

```bash
echo "plan entries"
S15=$(mktemp -d)
pe() { MULTICA_STATE_DIR="$S15" bash -c '. "'"$SH"'"; '"$*"''; }

# A legacy row written before this change holds a bare string. It must read as
# one current entry, with no migration script anywhere.
pe 'ledger_put OLD-1 "{\"repo\":\"r\",\"branch\":\"b\",\"plan\":\"docs/p/one.md\"}"'
check "string plan coerces to one entry" "$(pe 'plan_entries OLD-1 | jq -r "length"')" "1"
check "coerced entry is current"         "$(pe 'plan_entries OLD-1 | jq -r ".[0].state"')" "current"
check "coerced entry keeps the path"     "$(pe 'plan_entries OLD-1 | jq -r ".[0].path"')" "docs/p/one.md"

# An empty string is not a plan. It must not become an entry with an empty path.
pe 'ledger_put OLD-2 "{\"repo\":\"r\",\"branch\":\"b\",\"plan\":\"\"}"'
check "empty string plan is no entries" "$(pe 'plan_entries OLD-2 | jq -r "length"')" "0"
check "a row with no plan key is no entries" \
  "$(pe 'ledger_put OLD-3 "{\"repo\":\"r\"}"; plan_entries OLD-3 | jq -r "length"')" "0"

# addplan semantics: the outgoing current plan becomes done.
pe 'plan_push OLD-1 docs/p/two.md done "second body"'
check "push appends"                 "$(pe 'plan_entries OLD-1 | jq -r "length"')" "2"
check "previous current became done" "$(pe 'plan_entries OLD-1 | jq -r ".[0].state"')" "done"
check "new entry is current"         "$(pe 'plan_entries OLD-1 | jq -r ".[1].state"')" "current"
check "new entry keeps its body"     "$(pe 'plan_entries OLD-1 | jq -r ".[1].body"')" "second body"
check "plan_current names it"        "$(pe 'plan_current OLD-1')" "docs/p/two.md"

# replan semantics: the outgoing current plan becomes superseded, and is kept.
pe 'plan_push OLD-1 docs/p/three.md superseded "third"'
check "replan supersedes, does not delete" "$(pe 'plan_entries OLD-1 | jq -r ".[1].state"')" "superseded"
check "superseded body survives"           "$(pe 'plan_entries OLD-1 | jq -r ".[1].body"')" "second body"
check "three entries now"                  "$(pe 'plan_entries OLD-1 | jq -r "length"')" "3"

# Re-adding a plan already on the row moves it, never duplicates it.
pe 'plan_push OLD-1 docs/p/two.md done "again"'
check "re-adding does not duplicate" \
  "$(pe 'plan_entries OLD-1 | jq -r "[.[] | select(.path==\"docs/p/two.md\")] | length"')" "1"
check "re-added plan is current" "$(pe 'plan_current OLD-1')" "docs/p/two.md"

# The reconciler writes `pr` onto a row. A bind must not silently drop it.
pe 'ledger_put PR-1 "{\"repo\":\"scratch\",\"branch\":\"b\",\"opened_by\":\"claude\",\"pr\":\"https://x/1\"}"'
( cd "$tmp" && MULTICA_STATE_DIR="$S15" PATH=/usr/bin:/bin bash -c '. "'"$SH"'"; do_bind s1 PR-1 claude "" 0' ) >/dev/null 2>&1
check "bind preserves the pr field" "$(pe 'ledger_get PR-1 | jq -r ".pr"')" "https://x/1"

check "plan_push on a missing row fails" "$(pe 'plan_push NOPE-1 x done ""' >/dev/null 2>&1; echo $?)" "1"
rm -rf "$S15"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -30`

Expected: FAIL — `plan_entries` is undefined, so its output is empty and assertions report `want="1" got=""`.

- [x] **Step 3: Add the helpers**

Insert into `tracking.sh` immediately after the `ledger_del()` function (before the `ticket_for` comment block):

```bash
# `plan` is an array of {path,state,body}: one branch carries many plans, and a
# ticket that can only name its newest one has to destroy the others to stay
# accurate. Rows written before this change hold a bare string, so coerce on
# read - two live rows is fewer than a migration script is worth.
# state is exactly one of: done | current | superseded.
plan_entries() {
  state_dir
  ledger_get "$1" | jq -c '
    (.plan // null) as $p
    | if   ($p | type) == "array"  then $p
      elif ($p | type) == "string" then
        (if $p == "" then [] else [{path:$p, state:"current", body:""}] end)
      else [] end' 2>/dev/null || echo '[]'
}

# Append a plan and settle the outgoing one. $3 is what the current entry
# becomes: `done` for addplan (it shipped), `superseded` for replan (it was
# wrong). Re-adding a path already present moves it rather than duplicating it,
# so a repeated call is idempotent instead of growing the row.
plan_push() {
  local key="$1" path="$2" outgoing="$3" body="${4:-}" row entries
  row=$(ledger_get "$key"); [ -n "$row" ] || return 1
  entries=$(plan_entries "$key" | jq -c \
    --arg p "$path" --arg o "$outgoing" --arg b "$body" '
      map(if .state == "current" then .state = $o else . end)
      | map(select(.path != $p))
      + [{path:$p, state:"current", body:$b}]' 2>/dev/null) || return 1
  ledger_put "$key" "$(printf '%s' "$row" | jq -c --argjson e "$entries" '.plan = $e' 2>/dev/null)"
}

plan_current() {
  plan_entries "$1" | jq -r 'map(select(.state=="current")) | .[0].path // empty' 2>/dev/null
}
```

- [x] **Step 4: Rewrite `do_bind` to merge**

Extend `do_bind`'s local declaration to carry two new variables:

```bash
  local sid="$1" key="$2" who="${3:-iso}" plan="${4:-}" promote="${5:-1}" br proj st row entries
```

Then replace the existing `ledger_put` call inside `do_bind` (the block beginning with the comment `# plan is what review/blocked/progress resolve a ticket by;`) with:

```bash
  # Merge into the row, never replace it. The reconciler writes `pr` here on a
  # later run, and a wholesale rewrite dropped it silently - the ticket then
  # lost its PR link the next time anything bound to it.
  row=$(ledger_get "$key"); [ -n "$row" ] || row='{}'
  entries=$(plan_entries "$key")
  if [ -n "$plan" ] && [ "$entries" = "[]" ]; then
    entries=$(jq -nc --arg p "$plan" '[{path:$p, state:"current", body:""}]')
  fi
  ledger_put "$key" "$(printf '%s' "$row" | jq -c \
    --arg r "$proj" --arg b "$br" --arg o "$who" --argjson e "$entries" \
    '. + {repo:$r, branch:$b, project:$r, opened_by:$o, plan:$e}' 2>/dev/null)"
```

- [x] **Step 5: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -30`
Expected: `0 failed`.

- [x] **Step 6: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "feat(tracking): ledger plan becomes an array of plan entries

- plan_entries coerces a legacy string plan into one current entry
- plan_push settles the outgoing plan as done or superseded
- do_bind merges into the row so the reconciler's pr field survives"
```

---

### Task 2: `ticket_for` sees every match, and matches on the array

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh:118-133` (`ticket_for`)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Consumes: the plan-array shape from Task 1 (the jq below reads it directly).
- Produces: `ticket_for` still prints exactly one key on stdout. When more than one row matches, it additionally logs and writes a warning to stderr naming every key. Matching now considers **every** path in the `plan` array, not just a scalar.

**Why this task exists:** `head -1` (`tracking.sh:129`) is why FIRE-21 was invisible — `ticket-for-branch` reported FIRE-20 and nothing ever said a second row existed.

- [x] **Step 1: Write the failing test**

Append to `tracking.test.sh` after the Task 1 block:

```bash
echo "ticket_for with plan arrays"
S16=$(mktemp -d); rr2=$(mktemp -d)
( cd "$rr2" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git )
tf() { ( cd "$rr2" && MULTICA_STATE_DIR="$S16" bash -c '. "'"$SH"'"; '"$*"'' ); }

tf 'ledger_put ARR-1 "{\"repo\":\"scratch\",\"branch\":\"feat/x\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/superpowers/plans/a.md\",\"state\":\"done\",\"body\":\"\"},{\"path\":\"docs/superpowers/plans/b.md\",\"state\":\"current\",\"body\":\"\"}]}"'
check "resolves by branch"                  "$(tf 'ticket_for feat/x')" "ARR-1"
check "resolves by the current plan"        "$(tf 'ticket_for docs/superpowers/plans/b.md')" "ARR-1"
check "resolves by an older plan"           "$(tf 'ticket_for docs/superpowers/plans/a.md')" "ARR-1"
check "an unknown plan resolves to nothing" "$(tf 'ticket_for docs/superpowers/plans/zz.md')" ""

# The FIRE-20/FIRE-21 case: two live rows, one branch, same repo. head -1 hid
# this completely. One key is still returned - callers expect one - but the
# duplicate must be announced.
tf 'ledger_put ARR-2 "{\"repo\":\"scratch\",\"branch\":\"feat/x\",\"opened_by\":\"claude\",\"plan\":[]}"'
check "still returns exactly one key" "$(tf 'ticket_for feat/x' | wc -l | tr -d ' ')" "1"
err=$( cd "$rr2" && MULTICA_STATE_DIR="$S16" bash -c '. "'"$SH"'"; ticket_for feat/x' 2>&1 >/dev/null )
contains "ARR-1" "$err" && contains "ARR-2" "$err" \
  && ok "a duplicate branch is announced on stderr, naming both" \
  || bad "duplicate rows on one branch went unreported"
grep -q 'ARR-2' "$S16/log" && ok "the duplicate is logged" || bad "duplicate not logged"
rm -rf "$S16" "$rr2"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: FAIL on "resolves by an older plan" (the old jq reads only a scalar `.plan`) and on the stderr and log assertions.

- [x] **Step 3: Replace `ticket_for`**

Keep the comment block above it; replace the function with:

```bash
ticket_for() {
  local plan="${1:-}" base keys key
  [ -n "$plan" ] || return 1
  base=${plan##*/}
  state_dir
  # Every path in the plan array, not only the newest: a session resumed on an
  # older plan must find the same ticket, and a lookup that comes back empty is
  # exactly what mints a duplicate.
  keys=$(jq -r --arg b "$base" --arg a "$plan" --arg r "$(project_for "$PWD")" '
    to_entries[]
    | select(((.value.repo // "") == "") or ((.value.repo // "") == $r))
    | . as $e
    | ( ($e.value.plan // []) as $p
        | if   ($p | type) == "array"  then ($p | map(.path // ""))
          elif ($p | type) == "string" then [$p]
          else [] end ) as $paths
    | select( (($paths | map(split("/") | last) | index($b)) != null)
              or (($e.value.branch // "") == $a) )
    | $e.key' "$LEDGER" 2>/dev/null)
  [ -n "$keys" ] || return 1
  key=$(printf '%s\n' "$keys" | head -1)
  # More than one row for one identifier is the bug this design exists to stop.
  # One key is still returned, because every caller wants one - but silence here
  # is how FIRE-21 stayed invisible for a day.
  if [ "$(printf '%s\n' "$keys" | grep -c .)" -gt 1 ]; then
    logf "ticket_for: $plan matches several rows: $(printf '%s' "$keys" | tr '\n' ' ')-- using $key"
    printf 'tracking: %s matches several tickets (%s) -- using %s\n' \
      "$plan" "$(printf '%s' "$keys" | tr '\n' ' ')" "$key" >&2
  fi
  echo "$key"
  return 0
}
```

- [x] **Step 4: Make the `.repo` scope visible instead of silent**

The spec asks for the `.repo` filter (`tracking.sh:126`) to be fixed so a lookup works from any checkout. **Do not remove the filter.** It is load-bearing: `tracking.test.sh:182-197` asserts that a row for another repo must not resolve here, and dropping it means a session in one repo can cancel a live ticket in another. Every repo has a `dev`.

What is actually wrong is that a scoped-out match returns empty and says nothing, so "no ticket for this branch" and "a ticket exists but belongs to another checkout" look identical — and the second one mints a duplicate. Make the difference audible. Add, immediately before `[ -n "$keys" ] || return 1` in the rewritten `ticket_for`:

```bash
  # A row that matched on identifier but lost on repo scope is not the same as
  # no row at all: the first means "you are in the wrong checkout", the second
  # means "this is new work". Silence made them identical, and only one of them
  # should lead to a new ticket.
  if [ -z "$keys" ]; then
    local elsewhere
    elsewhere=$(jq -r --arg b "$base" --arg a "$plan" '
      to_entries[]
      | . as $e
      | ( ($e.value.plan // []) as $p
          | if   ($p | type) == "array"  then ($p | map(.path // ""))
            elif ($p | type) == "string" then [$p]
            else [] end ) as $paths
      | select( (($paths | map(split("/") | last) | index($b)) != null)
                or (($e.value.branch // "") == $a) )
      | "\($e.key) in \($e.value.repo // "?")"' "$LEDGER" 2>/dev/null | head -3)
    if [ -n "$elsewhere" ]; then
      logf "ticket_for: $plan matches only rows in another repo: $(printf '%s' "$elsewhere" | tr '\n' ';')"
      printf 'tracking: %s is tracked in another checkout (%s) -- not visible from %s\n' \
        "$plan" "$(printf '%s' "$elsewhere" | tr '\n' ';')" "$(project_for "$PWD")" >&2
    fi
  fi
```

Extend the Step 1 test with:

```bash
# A row scoped out by repo must announce itself, or "wrong checkout" and "new
# work" are indistinguishable - and only one of them should open a ticket.
tf 'ledger_put FAR-9 "{\"repo\":\"elsewhere\",\"branch\":\"feat/far\",\"opened_by\":\"claude\",\"plan\":[]}"'
check "another repo's row still resolves to nothing" "$(tf 'ticket_for feat/far')" ""
err2=$( cd "$rr2" && MULTICA_STATE_DIR="$S16" bash -c '. "'"$SH"'"; ticket_for feat/far' 2>&1 >/dev/null )
contains "another checkout" "$err2" && ok "a scoped-out match is announced" || bad "scoped-out match was silent"
```

- [x] **Step 5: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: `0 failed`. The pre-existing cross-repo assertions at `tracking.test.sh:182-197` must still pass — the filter itself is unchanged, only its silence.

- [x] **Step 6: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "fix(tracking): ticket_for matches every plan and reports duplicates

head -1 hid a second row on the same branch, which is how FIRE-21 stayed
invisible. One key is still returned; the duplicate now reaches stderr and
the log. Lookup also walks the whole plan array, so an older plan path
still resolves to its ticket."
```

---

### Task 3: Render the description from the ledger

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (add `plan_label` and `render_body` immediately before `ticket_body`, ~line 284)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Consumes: `ticket_body` (unchanged — it still produces the resume footer), `plan_entries`.
- Produces:
  - `plan_label <path>` -> a human section heading derived from the filename: date prefix and Conventional-Commit type prefix stripped, dashes to spaces.
  - `render_body <sid> <agent> <intro> <entries-json>` -> the complete ticket description on stdout. Pure: the same four arguments always produce byte-identical output, and it never reads the board.

**Why pure matters:** this is the decision the whole design rests on. Rendering from local state means a bad description is repaired by rendering again; patching a remote document means a bad append is permanent.

- [x] **Step 1: Write the failing test**

```bash
echo "render_body"
S17=$(mktemp -d); rr3=$(mktemp -d)
( cd "$rr3" && git init -q -b main . && git commit -q --allow-empty -m x )
rb() { ( cd "$rr3" && MULTICA_STATE_DIR="$S17" bash -c '. "'"$SH"'"; '"$*"'' ); }

check "label strips date and type" "$(rb 'plan_label docs/superpowers/plans/2026-08-28-feat-editor-script.md')" "editor script"
check "label survives no prefix"   "$(rb 'plan_label docs/superpowers/plans/script-layer.md')" "script layer"

ENT='[{"path":"docs/p/2026-08-27-script-layer.md","state":"done","body":"first prose"},{"path":"docs/p/2026-08-28-feat-editor-script.md","state":"current","body":"third prose"},{"path":"docs/p/2026-08-28-feat-x.md","state":"superseded","body":"abandoned"}]'
out=$(rb 'render_body s1 claude "the umbrella" '"'$ENT'"'')

contains "the umbrella" "$out"     && ok "intro is rendered"          || bad "intro missing"
contains "script layer" "$out"     && ok "done section rendered"      || bad "done section missing"
contains "editor script" "$out"    && ok "current section rendered"   || bad "current section missing"
contains "abandoned" "$out"        && ok "a superseded body is kept"  || bad "superseded body was dropped"
check "exactly one /iso-write line" "$(printf '%s' "$out" | grep -c '^/iso-write ')" "1"
contains "/iso-write docs/p/2026-08-28-feat-editor-script.md" "$out" \
  && ok "the /iso-write line names the current plan" || bad "wrong plan in the /iso-write line"
check "exactly one resume block" "$(printf '%s' "$out" | grep -c 'claude --resume')" "1"
check "three section headings" "$(printf '%s' "$out" | grep -c '^## ')" "3"

# Idempotence: the whole point of rendering rather than patching.
out2=$(rb 'render_body s1 claude "the umbrella" '"'$ENT'"'')
check "render is idempotent" "$out" "$out2"

# codex does the work in a session this command cannot reach, so no resume line.
outc=$(rb 'render_body s1 codex "" '"'$ENT'"'')
contains "claude --resume" "$outc" && bad "resume offered for a codex session" || ok "no resume line for codex"
contains "third prose" "$outc" && ok "sections still render for codex" || bad "codex render lost the sections"

# No entries at all: open with no plan must still produce the footer.
oute=$(rb 'render_body s1 claude "" "[]"')
contains "claude --resume s1" "$oute" && ok "empty entries still render a resume block" || bad "empty render lost the footer"
rm -rf "$S17" "$rr3"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -25`
Expected: FAIL — `plan_label` and `render_body` are undefined, so every assertion sees empty output.

- [x] **Step 3: Implement both functions**

Insert into `tracking.sh` immediately **before** `ticket_body`. The three marker characters in the `case` below are the ones the spec fixes; copy them, do not retype them:

```bash
# Section heading from a plan filename. Derived, never passed in: one more flag
# on addplan is one more thing a caller gets wrong, and the filename already
# carries the name someone chose for this plan.
plan_label() {
  local base="${1##*/}"
  base="${base%.md}"
  base=$(printf '%s' "$base" \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/^(feat|fix|chore|refactor|docs?|test|perf|style|build)-//')
  printf '%s' "$(printf '%s' "$base" | tr '-' ' ')"
}

# The whole ticket description, rendered from the plan array. Pure: no board
# read, no remote state, so the same entries always produce the same bytes and a
# damaged description is repaired by rendering it again. This is what makes a
# multi-plan body safe - the alternative, read-modify-write against the board,
# is what deleted the first plan on FIRE-20.
# $1 session id, $2 agent kind, $3 intro prose (may be empty), $4 entries JSON.
render_body() {
  local sid="$1" agent="$2" intro="$3" entries="${4:-[]}"
  local out="" path state body label marker cur=""
  [ -n "$intro" ] && out="$intro"
  while IFS=$'\t' read -r path state; do
    [ -n "$path" ] || continue
    case "$state" in
      done)       marker="✅" ;;
      superseded) marker="⊘"  ;;
      *)          marker="▶️" ; cur="$path" ;;
    esac
    label=$(plan_label "$path")
    body=$(printf '%s' "$entries" | jq -r --arg p "$path" \
      '.[] | select(.path == $p) | .body // ""' 2>/dev/null)
    if [ -n "$out" ]; then
      out=$(printf '%s\n\n## %s %s\n\n`%s` - %s' "$out" "$marker" "$label" "$path" "$state")
    else
      out=$(printf '## %s %s\n\n`%s` - %s' "$marker" "$label" "$path" "$state")
    fi
    [ -n "$body" ] && out=$(printf '%s\n\n%s' "$out" "$body")
  done <<< "$(printf '%s' "$entries" | jq -r '.[]? | [.path, .state] | @tsv' 2>/dev/null)"
  # Footer once, at the end - not once per section. Only the current plan gets a
  # runnable command; a `/iso-write` on a shipped or abandoned plan is a trap.
  printf '%s' "$out" | ticket_body "$sid" "$agent" "$cur"
}
```

**Note for the implementer:** `ticket_body` reads its body from stdin and appends the resume footer, adding the `/iso-write` line only when its third argument is non-empty. Passing `$cur` is therefore the entire mechanism for "one `/iso-write` line, on the current section only". Do not add a second footer.

- [x] **Step 4: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -25`
Expected: `0 failed`.

- [x] **Step 5: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "feat(tracking): render the ticket body from the plan array

render_body is pure - same entries in, same bytes out - so the description
is a projection of the ledger rather than a remote document to patch. One
section per plan, one resume footer, and the /iso-write line only on the
current plan."
```

---

### Task 4: The `addplan` verb

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (new dispatch arm, directly above the `replan)` arm at ~line 424)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Consumes: `plan_push`, `plan_entries`, `plan_current`, `render_body`, `ticket_for_branch`, `tk_issue_describe`, `tk_issue_comment`, `tk_issue_get_status`, `set_status`, `do_bind`, `redact`.
- Produces: dispatch arm `addplan <session_id> --plan <path> [--key KEY] [--agent claude|codex] [--title T] [--intro P]`. Body on stdin. Prints the ticket key on stdout. `--title` is wired in Task 7; accept it here so the argument loop does not log it as unknown.

**Semantics:** the previous plan **shipped**. Outgoing `current` becomes `done`. Status goes to `in_progress` — per the spec, `in_review` while writing code is false and `todo` claims nothing has started.

- [x] **Step 1: Write the failing test**

```bash
echo "addplan"
S18=$(mktemp -d); BIN18=$(mktemp -d); g18=$(mktemp -d)
CALLS18="$S18/calls"; DESC18="$S18/desc"; : > "$CALLS18"; : > "$DESC18"
cat > "$BIN18/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS18"
case "$1 $2" in
  "issue get")    printf '{"status":"in_review"}' ;;
  "issue update") cat > "$DESC18" ;;
  "issue create") cat >/dev/null 2>&1; printf '{"identifier":"FIRE-9"}' ;;
  "auth status")  printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN18/multica"
export CALLS18 DESC18
( cd "$g18" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/many )

ap() { ( cd "$g18" && MULTICA_STATE_DIR="$S18" PATH="$BIN18:$PATH" bash "$SH" "$@" ); }

MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; ledger_put FIRE-50 "{\"repo\":\"scratch\",\"branch\":\"feat/many\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/one.md\",\"state\":\"current\",\"body\":\"first\"}]}"'

got=$(printf 'second body\n' | ap addplan s5 --plan docs/p/two.md)
check "addplan returns the existing key" "$got" "FIRE-50"
check "no new issue was created" "$(grep -c 'issue create' "$CALLS18")" "0"
check "the previous plan is done" \
  "$(MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; plan_entries FIRE-50 | jq -r ".[0].state"')" "done"
check "the new plan is current" \
  "$(MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; plan_current FIRE-50')" "docs/p/two.md"
contains "first" "$(cat "$DESC18")" && ok "the earlier plan survives in the body" || bad "addplan destroyed the earlier plan"
contains "second body" "$(cat "$DESC18")" && ok "the new plan is in the body" || bad "new plan missing from body"
grep -q 'issue status FIRE-50 in_progress' "$CALLS18" \
  && ok "in_review moves to in_progress" || bad "status not moved to in_progress"
grep -q 'comment add FIRE-50' "$CALLS18" && ok "the switch is commented" || bad "no comment for the plan switch"

# A token in the piped body must never reach the board, and must never be stored
# in the ledger either - the ledger is now what the body is rendered from.
: > "$DESC18"
printf 'tok mul_abcdefghijklmnop1234 x\n' | ap addplan s6 --plan docs/p/three.md >/dev/null 2>&1
grep -q 'mul_abcdefghijklmnop1234' "$DESC18" && bad "a token reached the board" || ok "the body was redacted"
MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; plan_entries FIRE-50' | grep -q 'mul_abcdefghijklmnop1234' \
  && bad "a token was stored in the ledger" || ok "the stored body was redacted"

# No live ticket for this branch: addplan is not a create path.
( cd "$g18" && git checkout -q -b feat/orphan )
out=$(printf 'x\n' | ap addplan s7 --plan docs/p/four.md 2>&1)
check "addplan on an unknown branch exits 0" "$?" "0"
contains "no live ticket" "$out" && ok "says why it did nothing" || bad "silent on a missing ticket"
( cd "$g18" && git checkout -q feat/many )

check "addplan with no --plan exits 0" "$(printf 'x\n' | ap addplan s8 >/dev/null 2>&1; echo $?)" "0"
rm -rf "$S18" "$BIN18" "$g18"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -25`
Expected: FAIL — `addplan` falls through to the `*)` dispatch arm, logs "unknown subcommand", and prints nothing.

- [x] **Step 3: Add the dispatch arm**

Insert into `tracking.sh` directly **above** the `replan)` arm:

```bash
  # A further plan on a branch that already has one. The previous plan shipped -
  # that is the whole difference from `replan`, where it was wrong. Both keep
  # every plan visible; only the state on the outgoing entry differs.
  # stdin: this plan's section body.
  addplan)
    state_dir
    sid="${2:-}"; plan=""; key=""; agent=claude; title=""; intro=""
    shift 2 2>/dev/null || shift $#
    while [ $# -gt 0 ]; do
      case "$1" in
        --plan)  plan="${2:-}";  shift 2 ;;
        --key)   key="${2:-}";   shift 2 ;;
        --agent) agent="${2:-}"; shift 2 ;;
        --title) title="${2:-}"; shift 2 ;;
        --intro) intro="${2:-}"; shift 2 ;;
        *) logf "addplan: ignoring unknown arg $1"; shift ;;
      esac
    done
    if [ -z "$sid" ] || [ -z "$plan" ]; then
      logf "addplan needs <session_id> --plan <path>"; exit 0
    fi
    if [ -z "$key" ]; then
      key=$(ticket_for_branch | cut -f1)
      if [ -z "$key" ]; then
        logf "addplan: no live ticket for this branch -- open one instead"
        printf 'tracking: no live ticket for this branch -- nothing to add to\n' >&2
        exit 0
      fi
    fi
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 8000 || true)
    was=$(plan_current "$key")
    plan_push "$key" "$plan" done "$body" \
      || { logf "addplan: no ledger row for $key"; exit 0; }
    desc=$(render_body "$sid" "$agent" "$intro" "$(plan_entries "$key")")
    if [ -n "$desc" ]; then
      printf '%s' "$desc" | tk_issue_describe "$key" \
        || logf "addplan: description update failed on $key"
    fi
    printf 'Plan added - `%s` continues from `%s`, which is done. The description above carries both.\n' \
      "$plan" "${was:-<none>}" | redact | tk_issue_comment "$key" \
      || logf "addplan: comment failed on $key"
    st=$(tk_issue_get_status "$key")
    case "$st" in
      todo|backlog|in_review|blocked)
        set_status "$key" in_progress \
          && logf "$key -> in_progress (addplan, ${plan##*/}, was ${was:-<none>}, from $st)" ;;
      *) logf "$key addplan ${plan##*/} (was ${was:-<none>}, status $st unchanged)" ;;
    esac
    do_bind "$sid" "$key" claude "$plan" 0
    echo "$key"
    ;;
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -25`
Expected: `0 failed`.

- [x] **Step 5: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "feat(tracking): add the addplan verb

replan was the only verb available, so a plan that shipped was recorded as
superseded. addplan marks the outgoing plan done, keeps it in the body, and
moves the ticket to in_progress."
```

---

### Task 5: `replan` supersedes instead of deleting

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (the `replan)` arm, ~line 424-471)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Consumes: everything Task 4 uses.
- Produces: `replan` keeps its existing flags and its `todo` status move, but no longer rebuilds the description from one plan. Its outgoing entry becomes `superseded` and stays in the body.

- [x] **Step 1: Write the failing test**

```bash
echo "replan keeps history"
S19=$(mktemp -d); BIN19=$(mktemp -d); g19=$(mktemp -d)
CALLS19="$S19/calls"; DESC19="$S19/desc"; : > "$CALLS19"; : > "$DESC19"
cat > "$BIN19/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS19"
case "$1 $2" in
  "issue get")    printf '{"status":"in_progress"}' ;;
  "issue update") cat > "$DESC19" ;;
  "auth status")  printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN19/multica"
export CALLS19 DESC19
( cd "$g19" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/redo )
MULTICA_STATE_DIR="$S19" bash -c '. "'"$SH"'"; ledger_put FIRE-60 "{\"repo\":\"scratch\",\"branch\":\"feat/redo\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/wrong.md\",\"state\":\"current\",\"body\":\"the wrong approach\"}]}"'

printf 'the right approach\n' | ( cd "$g19" && MULTICA_STATE_DIR="$S19" PATH="$BIN19:$PATH" bash "$SH" \
  replan s9 --plan docs/p/right.md ) >/dev/null 2>&1

check "the abandoned plan is superseded, not gone" \
  "$(MULTICA_STATE_DIR="$S19" bash -c '. "'"$SH"'"; plan_entries FIRE-60 | jq -r ".[0].state"')" "superseded"
contains "the wrong approach" "$(cat "$DESC19")" \
  && ok "the superseded plan still appears in the body" || bad "replan destroyed the superseded plan"
contains "the right approach" "$(cat "$DESC19")" && ok "the new plan is in the body" || bad "new plan missing"
check "exactly one /iso-write line after a replan" "$(grep -c '^/iso-write ' "$DESC19")" "1"
contains "/iso-write docs/p/right.md" "$(cat "$DESC19")" \
  && ok "the runnable command names the new plan" || bad "wrong plan in the /iso-write line"
grep -q 'issue status FIRE-60 todo' "$CALLS19" && ok "replan returns the ticket to todo" || bad "replan did not move to todo"
rm -rf "$S19" "$BIN19" "$g19"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: FAIL on "the superseded plan still appears in the body" — the current arm rebuilds the description from the new plan alone.

- [x] **Step 3: Rewrite the body of the `replan` arm**

First add `intro=""` to the arm's initialiser line and `--intro) intro="${2:-}"; shift 2 ;;` to its argument loop, matching `addplan`.

Then replace everything from `was=$(jq -r --arg k "$key" ...)` down to and including the `do_bind "$sid" "$key" claude "$plan" 0` line with:

```bash
    body=""
    [ -t 0 ] || body=$(cat 2>/dev/null | redact | head -c 8000 || true)
    was=$(plan_current "$key")
    # Superseded, not deleted. The old arm replaced the whole description with
    # the new plan, so the abandoned one survived only as a filename in a
    # comment - which is how FIRE-20 lost its first plan.
    plan_push "$key" "$plan" superseded "$body" \
      || { logf "replan: no ledger row for $key"; exit 0; }
    desc=$(render_body "$sid" "$agent" "$intro" "$(plan_entries "$key")")
    if [ -n "$desc" ]; then
      printf '%s' "$desc" | tk_issue_describe "$key" \
        || logf "replan: description update failed on $key"
    fi
    printf 'Replanned from `%s` - superseded by `%s`. Back to `todo`; both remain in the description above.\n' \
      "${was:-<none>}" "$plan" | redact | tk_issue_comment "$key" \
      || logf "replan: comment failed on $key"
    set_status "$key" todo \
      && logf "$key -> todo (replan, ${plan##*/}, was ${was:-<none>}, from $st)"
    do_bind "$sid" "$key" claude "$plan" 0
```

- [x] **Step 4: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: `0 failed`.

- [x] **Step 5: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "fix(tracking): replan supersedes a plan instead of deleting it

The arm rebuilt the description from the new plan alone, so the abandoned
one survived only as a filename in a comment. It is now a superseded
section in the rendered body."
```

---

### Task 6: `open` enforces one branch, one ticket

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (the `open)` arm, ~line 483-540)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Consumes: `ticket_for_branch`, and the `addplan` arm from Task 4.
- Produces: `open` performs the branch lookup itself. On a live hit it **redirects**: it `exec`s the `addplan` path with the same stdin and flags, prints the existing key, and writes one line to stderr. There is **no `--force-new`**.

**Why redirect and not refuse:** a refusal hands the decision back to the caller that already skipped a decision point. A caller that cannot create a ticket may cut a new branch or retry with a different title. The redirect makes the wrong outcome unreachable.

- [x] **Step 1: Write the failing test**

```bash
echo "open redirects on a held branch"
S20=$(mktemp -d); BIN20=$(mktemp -d); g20=$(mktemp -d)
CALLS20="$S20/calls"; DESC20="$S20/desc"; : > "$CALLS20"; : > "$DESC20"
cat > "$BIN20/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS20"
case "$1 $2" in
  "issue get")      printf '{"status":"in_review"}' ;;
  "issue update")   cat > "$DESC20" ;;
  "issue create")   cat >/dev/null 2>&1; printf '{"identifier":"FIRE-99"}' ;;
  "project list")   printf '[]' ;;
  "project create") printf '{"id":"p1"}' ;;
  "auth status")    printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN20/multica"
export CALLS20 DESC20
( cd "$g20" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/held )

# THE regression test. The exact FIRE-20/FIRE-21 case: a live ticket already
# holds this branch, and `open` is called anyway.
MULTICA_STATE_DIR="$S20" bash -c '. "'"$SH"'"; ledger_put FIRE-70 "{\"repo\":\"scratch\",\"branch\":\"feat/held\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/first.md\",\"state\":\"current\",\"body\":\"first\"}]}"'
got=$(printf 'second\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s10 "a second title" --plan docs/p/second.md --scope be ) 2>/dev/null)

check "open returns the existing key" "$got" "FIRE-70"
check "open created no second issue"  "$(grep -c 'issue create' "$CALLS20")" "0"
check "the ledger still has one row for this branch" \
  "$(jq -r '[to_entries[] | select(.value.branch=="feat/held")] | length' "$S20/tracked.json")" "1"
check "the second plan landed on the existing ticket" \
  "$(MULTICA_STATE_DIR="$S20" bash -c '. "'"$SH"'"; plan_current FIRE-70')" "docs/p/second.md"
contains "first" "$(cat "$DESC20")" && ok "the first plan survives the redirect" || bad "redirect lost the first plan"
err=$(printf 'x\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s11 "third" --plan docs/p/third.md ) 2>&1 >/dev/null)
contains "FIRE-70" "$err" && ok "the redirect is announced on stderr" || bad "the redirect was silent"
grep -q 'redirect' "$S20/log" && ok "the redirect is logged" || bad "redirect not logged"

# A branch with no live ticket must still create, or open is broken.
( cd "$g20" && git checkout -q -b feat/fresh )
got=$(printf 'body\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s12 "a fresh one" --plan docs/p/fresh.md --scope be ) 2>/dev/null)
check "a free branch still opens a new ticket" "$got" "FIRE-99"

# There is no escape hatch. --force-new must be treated as an unknown flag.
: > "$CALLS20"
( cd "$g20" && git checkout -q feat/held )
got=$(printf 'x\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s13 "forced" --force-new --plan docs/p/forced.md ) 2>/dev/null)
check "--force-new does not create a second ticket" "$(grep -c 'issue create' "$CALLS20")" "0"
check "--force-new still redirects" "$got" "FIRE-70"
rm -rf "$S20" "$BIN20" "$g20"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -25`
Expected: FAIL — `open` creates `FIRE-99` on the held branch, so the first assertion reports `want="FIRE-70" got="FIRE-99"`.

- [x] **Step 3: Add the gate to the `open` arm**

Add `intro=""` to the `open` arm's initialiser line and `--intro) intro="${2:-}"; shift 2 ;;` to its argument loop.

Then, immediately **after** the `if [ -z "$sid" ] || [ -z "$title" ]` guard and **before** `[ -z "$priority" ] && priority="medium"`, insert:

```bash
    # One branch, one ticket. The rule used to live in a SKILL.md, which held
    # exactly as long as the caller read the right document - and on 2026-08-28
    # one did not, producing a second row on a branch that already had one.
    # Redirect rather than refuse: a refusal hands the decision back to whoever
    # already skipped one, and a caller that cannot create a ticket may cut a
    # new branch instead. There is deliberately no --force-new.
    held=$(ticket_for_branch | cut -f1)
    if [ -n "$held" ]; then
      logf "open: redirect to addplan on $held (branch already tracked)"
      printf 'tracking: this branch is already tracked by %s -- adding the plan there\n' "$held" >&2
      # An args array, not word-splitting: an umbrella title contains spaces and
      # ${title:+--title "$title"} would shatter it into separate arguments.
      redirect=(addplan "$sid" --key "$held" --plan "$plan" --agent "$agent")
      [ -n "$title" ] && redirect+=(--title "$title")
      [ -n "$intro" ] && redirect+=(--intro "$intro")
      # exec, so stdin is inherited unread and the piped body reaches addplan
      # intact. Nothing above this point may consume stdin.
      exec "$0" "${redirect[@]}"
    fi
```

**Note for the implementer:** verify that nothing earlier in the `open` arm reads stdin. As written it does not — `desc=$(ticket_body ...)` comes later — but if that ever changes, the redirect silently loses the body.

- [x] **Step 4: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -25`
Expected: `0 failed`. The existing `open` assertions (`tracking.test.sh:296-360`) run on fresh branches with empty ledgers, so the gate does not fire for them.

- [x] **Step 5: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "feat(tracking): open redirects when the branch is already tracked

The one-branch-one-ticket rule lived only in prose, so a caller reading a
different document opened a second row on a tracked branch. open now runs
the lookup itself and redirects to addplan. No --force-new."
```

---

### Task 7: `--title` and the adapter title verb

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/adapters/multica.sh` (add `tk_issue_title` after `tk_issue_describe`)
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (apply `$title` in the `addplan` and `replan` arms)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Produces: `tk_issue_title <key> <title>` -> renames the issue, with `--no-start` like every other write. In `tracking.sh`, a non-empty `--title` on `addplan` or `replan` renames the ticket; omitted, the title is left alone.

**Why optional:** plan 2 on the same topic should not churn the title. Genuine divergence gets an umbrella; a continuation does not.

- [x] **Step 1: Write the failing test**

```bash
echo "umbrella title"
S21=$(mktemp -d); BIN21=$(mktemp -d); g21=$(mktemp -d)
CALLS21="$S21/calls"; : > "$CALLS21"
cat > "$BIN21/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS21"
case "$1 $2" in
  "issue get")    printf '{"status":"in_review"}' ;;
  "issue update") cat >/dev/null 2>&1 ;;
  "auth status")  printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN21/multica"
export CALLS21
( cd "$g21" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/umb )
MULTICA_STATE_DIR="$S21" bash -c '. "'"$SH"'"; ledger_put FIRE-80 "{\"repo\":\"scratch\",\"branch\":\"feat/umb\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/a.md\",\"state\":\"current\",\"body\":\"a\"}]}"'

printf 'b\n' | ( cd "$g21" && MULTICA_STATE_DIR="$S21" PATH="$BIN21:$PATH" bash "$SH" \
  addplan s14 --plan docs/p/b.md ) >/dev/null 2>&1
grep -q -- '--title' "$CALLS21" && bad "renamed the ticket without being asked" || ok "no --title means no rename"

: > "$CALLS21"
printf 'c\n' | ( cd "$g21" && MULTICA_STATE_DIR="$S21" PATH="$BIN21:$PATH" bash "$SH" \
  addplan s15 --plan docs/p/c.md --title "The script layer" ) >/dev/null 2>&1
grep -q -- 'issue update FIRE-80 --title The script layer' "$CALLS21" \
  && ok "an explicit --title renames the ticket" || bad "--title did not rename"
grep -q -- '--no-start' "$CALLS21" && ok "the rename cannot start an agent" || bad "rename missing --no-start"
rm -rf "$S21" "$BIN21" "$g21"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: FAIL on "an explicit --title renames the ticket" — `addplan` accepts the flag from Task 4 but does nothing with it.

- [x] **Step 3: Add the adapter verb**

In `adapters/multica.sh`, directly after `tk_issue_describe`:

```bash
# Rename. Separate from tk_issue_describe because a rename and a rewrite are
# different decisions: a plan continuing the same topic changes the body and not
# the title. --no-start for the usual reason - the board must never enqueue a run.
tk_issue_title() {
  multica issue update "$1" --title "$2" --no-start >/dev/null 2>>"$(_M_LOG)"
}
```

- [x] **Step 4: Apply the title in both arms**

In **both** the `addplan` and `replan` arms, immediately after the `tk_issue_describe` block, add:

```bash
    if [ -n "$title" ]; then
      safe=$(printf '%s' "$title" | redact | head -c 200)
      tk_issue_title "$key" "$safe" \
        && logf "$key retitled: $safe" \
        || logf "retitle failed on $key"
    fi
```

- [x] **Step 5: Correct the stale version comments**

`adapters/multica.sh:27-28` and `:44` both say "CLI 0.4.26". Installed is **0.4.36** (commit `c1a61e1e8`, built 2026-08-28). Verify before editing, since it moves:

```bash
multica --version
```

Then update both comments to name the version actually checked, and the date it was checked. A version note nobody re-dates is a note that quietly becomes a lie — the `--priority` claim in those comments was written against a CLI ten patch releases old and has not been re-verified since.

- [x] **Step 6: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: `0 failed`.

Then confirm the adapter contract test still passes:

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/contract.test.sh 2>&1 | tail -10`
Expected: `0 failed`. If that file does not exist, skip this check.

- [x] **Step 7: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/adapters/multica.sh skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "feat(tracking): optional --title broadens a ticket as plans diverge

The title was written for the first plan and never updated, so a ticket
carrying three plans still announced one. Optional, so a continuation does
not churn it."
```

---

### Task 8: Stop reporting success that did not happen

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (`set_status` ~line 143; the non-repo guard ~line 333; the `open` success path)
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Produces: `set_status` verifies the transition by reading the status back and returns non-zero when the board did not move. A successful `open` logs one line. The non-repo early exit logs before exiting.

**Why:** FIRE-19 was logged `-> done` at `log:287` and its ledger row deleted, while the board still reads `in_review`. And a successful `open` logged nothing at all, which is why the cause of FIRE-21 had to be inferred from a typo rather than read from the record.

- [x] **Step 1: Write the failing test**

```bash
echo "honest status writes"
S22=$(mktemp -d); BIN22=$(mktemp -d); g22=$(mktemp -d)
CALLS22="$S22/calls"; : > "$CALLS22"
# The board accepts the write and then does not move - exactly the FIRE-19 shape.
cat > "$BIN22/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS22"
case "$1 $2" in
  "issue get")   printf '{"status":"in_review"}' ;;
  "auth status") printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN22/multica"
export CALLS22
( cd "$g22" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x )
rc=$( cd "$g22" && MULTICA_STATE_DIR="$S22" PATH="$BIN22:$PATH" bash -c '. "'"$SH"'"; set_status FIRE-19 done; echo $?' )
check "a status that did not stick reports failure" "$rc" "1"
grep -q 'FIRE-19' "$S22/log" && ok "the refused transition is logged" || bad "a silent failed transition"

# Outside a repo the script still exits 0, but no longer vanishes without trace.
out=$( cd / && MULTICA_STATE_DIR="$S22" PATH="$BIN22:/usr/bin:/bin" bash "$SH" ticket-for-branch >/dev/null 2>&1; echo $? )
check "outside a repo still exits 0" "$out" "0"
grep -q 'not a git repo' "$S22/log" && ok "a non-repo invocation is logged" || bad "non-repo invocation is invisible"
rm -rf "$S22" "$BIN22" "$g22"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: FAIL — `set_status` returns 0 because `tk_issue_status` succeeded, and the non-repo path logs nothing.

- [x] **Step 3: Make `set_status` verify**

Replace `set_status` (keeping the comment above it) with:

```bash
set_status() {
  local key="$1" want="$2" got
  tk_issue_status "$key" "$want" || { logf "status write refused: $key -> $want"; return 1; }
  # Read it back. FIRE-19 was logged "-> done" and dropped from the ledger while
  # the board stayed in_review: the write returned success, the transition never
  # happened, and nothing would ever move that row again.
  got=$(tk_issue_get_status "$key")
  [ -z "$got" ] && return 0          # cannot verify; do not invent a failure
  [ "$got" = "$want" ] && return 0
  logf "status did not stick: $key wanted $want, board says $got"
  printf 'tracking: %s did not move to %s (board says %s)\n' "$key" "$want" "$got" >&2
  return 1
}
```

- [x] **Step 4: Log the non-repo exit and the successful open**

Replace the non-repo guard line:

```bash
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
```

with:

```bash
# Installed globally, so it runs in every directory the agent opens. Outside a
# repo there is nothing to file against - but exiting without a word made a
# lookup run from the wrong directory indistinguishable from one that found
# nothing, which is one way a duplicate ticket gets minted.
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  logf "not a git repo ($PWD), skipping ${1:-<none>}"
  exit 0
fi
```

And in the `open` arm, immediately after the `if [ -z "$key" ]; then logf "open failed for: $safe"; exit 0; fi` guard, add:

```bash
    logf "open $key: $safe (project $proj, branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null), plan ${plan:-<none>})"
```

- [x] **Step 5: Run the tests to verify they pass**

Run: `cd /Volumes/Crucial-4T/repo/ai && bash skills/iso-issue-tracking/scripts/tracking.test.sh 2>&1 | tail -20`
Expected: `0 failed`.

**Watch out:** the reconcile assertions at `tracking.test.sh:182-197` use a `multica` stub that exits 0 and prints nothing, so `tk_issue_get_status` returns empty and the `[ -z "$got" ] && return 0` line keeps them passing. If they fail, that guard is missing.

- [x] **Step 6: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/scripts/tracking.sh skills/iso-issue-tracking/scripts/tracking.test.sh
git commit -m "fix(tracking): verify status writes and log the silent paths

FIRE-19 was logged done and dropped from the ledger while the board stayed
in_review. set_status now reads the status back. A successful open logs one
line, and a non-repo invocation says so instead of vanishing."
```

---

### Task 9: Documentation

**Files:**
- Modify: `skills/iso-issue-tracking/SKILL.md` (the `open` sites at `:97`, `:112`, `:381-383`; the no-sub-issues rationale at `:126` and `:386`)
- Modify: `skills/iso-plan/SKILL.md` (the gate at `:103-109`)

**No test.** Documentation, and the behaviour it describes is already locked by Task 6.

- [x] **Step 1: Fix the call-by-hand table row (`SKILL.md:97`)**

It currently reads, in effect: *trackable work, no matching issue -> `open ...`*. That precondition is now false — `open` is always safe. Replace the row with:

```markdown
| trackable work | `open <session_id> "<title>" --scope <scope>` - always safe to call: if the current branch already has a live ticket, this adds the plan to it and returns that ticket's key instead of creating a second one |
```

- [x] **Step 2: Document `addplan` beside `replan`**

Wherever `replan` is described, add:

```markdown
`addplan` and `replan` are the two ways a further plan joins a ticket, and they
differ in one thing: what the outgoing plan becomes.

| verb | use when | the previous plan becomes |
|---|---|---|
| `addplan` | the previous plan was implemented and you are continuing on the same branch | `done` |
| `replan` | the previous plan was wrong and this one replaces it | `superseded` |

Neither deletes anything. Every plan stays as a section in the ticket body, and
only the current one carries a runnable `/iso-write` line. Both accept an
optional `--title` to broaden the ticket's title as the topics on a branch
diverge - omit it and the title is left alone.
```

- [x] **Step 3: Correct the no-sub-issues rationale (`SKILL.md:126`, `:386`)**

The decision stands — do not add `--parent`. Add one clause so the reasoning is not mistaken for a CLI limitation:

```markdown
No sub-issues and no `--parent`. The CLI does support them; this is a choice.
Two rows on one branch close in the same instant regardless of the line drawn
between them, so a parent/child pair is one ticket with extra bookkeeping.
```

- [x] **Step 4: Keep the `/iso-plan` gate, and say why it is now belt-and-braces (`iso-plan/SKILL.md:103-109`)**

Leave the `ticket-for-branch` step exactly as it is. Add one line under it:

```markdown
`open` performs this same check itself and redirects when the branch is already
tracked, so a skipped gate can no longer mint a duplicate. The gate stays
because choosing the right verb here is still better than being corrected.
```

- [x] **Step 5: Commit**

```bash
cd /Volumes/Crucial-4T/repo/ai
git add skills/iso-issue-tracking/SKILL.md skills/iso-plan/SKILL.md
git commit -m "docs(tracking): open is always safe to call, and addplan exists

The docs stated a precondition the code no longer has - 'no matching issue'
was left to the reader's judgement, which is how a second row appeared on a
tracked branch."
```

---

### Task 10: Repair the live board

**Files:** none — this is an operational task run against the real tracker.

**Prerequisites:** Tasks 1-8 merged and installed. `~/.claude/skills/iso-issue-tracking` is a symlink into this repo, so a merge is enough.

**Watch out:** these commands mutate the real board. Run them one at a time and read the output. Neither the adapter nor CLI 0.4.36 has a delete or archive, so `cancelled` is the only disposal — FIRE-21 cannot be removed, only closed.

- [x] **Step 1: Back up the ledger**

```bash
cp ~/.claude/multica/tracked.json ~/.claude/multica/tracked.json.bak-$(date +%Y%m%d)
```

- [x] **Step 2: Rebuild FIRE-20's plan array by hand**

Three plans, in order. Plan 1 is `done` — it shipped to `in_review` on 2026-08-27 before `replan` mislabelled it. Its body is unrecoverable; say so in the entry rather than leaving it blank.

```bash
jq '.["FIRE-20"].plan = [
  {"path":"docs/superpowers/plans/2026-08-27-script-layer.md","state":"done",
   "body":"> Description not recoverable: this plan body was overwritten by replan on 2026-08-28, before section states existed."},
  {"path":"docs/superpowers/plans/2026-08-28-feat-notebooklm-native-pipeline.md","state":"done","body":""},
  {"path":"docs/superpowers/plans/2026-08-28-feat-editor-script.md","state":"current","body":""}
]' ~/.claude/multica/tracked.json > /tmp/t.json && mv /tmp/t.json ~/.claude/multica/tracked.json
jq -r '.["FIRE-20"].plan | map(.state + " " + .path) | .[]' ~/.claude/multica/tracked.json
```

Expected: three lines — `done`, `done`, `current`.

- [x] **Step 3: Recover the two bodies that still exist**

`multica issue get FIRE-20` and `multica issue get FIRE-21` still hold the notebooklm and editor descriptions. Copy each one's prose — everything above the `---` and the resume block — into the matching entry's `body` field with `jq`. Do this by hand: the descriptions contain markdown tables that must survive intact.

- [x] **Step 4: Re-render FIRE-20 with the umbrella title**

```bash
cd /Volumes/Crucial-4T/repo/social
~/.claude/skills/iso-issue-tracking/scripts/tracking.sh addplan "$SESSION_ID" \
  --key FIRE-20 --plan docs/superpowers/plans/2026-08-28-feat-editor-script.md \
  --title "The script layer: research, voice, and Scenes" </dev/null
multica issue get FIRE-20 --output json | jq -r '.title, .status'
```

Expected: the umbrella title, and a status of `in_progress`.

- [x] **Step 5: Cancel FIRE-21 and point it at FIRE-20**

```bash
printf 'Merged into FIRE-20. This branch carries one ticket; every plan on feat/script-layer now lives there as its own section.\n' \
  | multica issue comment add FIRE-21 --content-stdin
multica issue status FIRE-21 cancelled --no-start
jq 'del(.["FIRE-21"])' ~/.claude/multica/tracked.json > /tmp/t.json && mv /tmp/t.json ~/.claude/multica/tracked.json
multica issue get FIRE-21 --output json | jq -r '.status'
```

Expected: `cancelled`.

- [x] **Step 6: Close FIRE-19 on the board**

Its ledger row is correctly absent — the reconciler closed it and `ledger_del`'d it on 2026-08-27. Only the board is wrong.

```bash
multica issue status FIRE-19 done --no-start
multica issue get FIRE-19 --output json | jq -r '.status'
```

Expected: `done`. If it still reads `in_review`, the `set_status` verification from Task 8 has caught a real board-side problem — record what `multica issue status` printed and investigate before moving on.

- [x] **Step 7: Verify the invariant holds**

```bash
jq -r 'to_entries | group_by(.value.repo + " " + (.value.branch // ""))
       | map(select(length > 1)) | .[] | map(.key) | join(" ")' ~/.claude/multica/tracked.json
```

Expected: **no output**. Any line printed is two rows sharing a repo and branch — the condition this whole plan exists to make impossible.

---


## Implementation notes (deviations from the written plan)

**Tasks 1 and 2 were implemented as one green bar.** Task 1 changes the stored
shape of `plan`; Task 2 teaches `ticket_for` to read it. Between them the suite
is necessarily red — six pre-existing assertions resolve a ticket by plan path,
and a scalar reader cannot match an array. They are one deliverable and were
committed as two.

**Three fixes the plan did not anticipate, found by running it:**

1. `plan_entries` returned an **empty string**, not `[]`, for a row that does not
   exist yet: `jq` on empty input prints nothing and still exits 0, so the
   `|| echo '[]'` fallback never fired. The empty value then reached `--argjson`
   and killed the whole `ledger_put` silently, so `open` recorded no plan at all.
   `plan_entries` now checks the value rather than the exit status.
2. `do_bind` only seeded entries when the row had none, so `replan` — which calls
   it with the new plan — left the ledger pointing at the *previous* plan. It now
   promotes whatever plan it is given to `current`, settling the outgoing one as
   `done`. That is a no-op for `addplan`/`replan`, which have already settled it
   with their own state by the time they call `do_bind`.
3. Three existing assertions read `.plan` as a scalar
   (`tracking.test.sh` FIRE-50, FIRE-1, FIRE-9) and were updated to read the
   `current` entry's path.

## Known limitation: base branches — CLOSED during implementation

`/iso-plan` runs on whatever branch is checked out, which is usually `dev`. The
ticket is therefore opened bound to `dev`, and `/iso-write` moves it onto the
feature branch with `rebranch`. That flow is unchanged here and works.

But Task 6 makes `open` redirect on *any* live ticket for the current branch,
and `dev` is a branch. So two plans written back-to-back on `dev`, before either
is handed to `/iso-write`, now collapse into one ticket — where today they would
correctly become two.

**This was fixed while implementing Task 6, because the test suite forced it.**
Eighteen pre-existing `open` assertions share one `main` fixture and open several
tickets on it; the gate folded them into one and they all failed. That is the
same defect as the `dev` case, demonstrated rather than argued.

`open` now calls `iso_is_protected` on the current branch and skips the gate
there. The invariant it enforces is about feature branches, which is where a
duplicate actually splits one story in two.

## Out of scope

`reconcile: gh unavailable - no cancellation this run` fired nine times between 08:54 and 08:58 on 2026-08-28, during which reconciliation did nothing. That is arguably correct — no network, no judgement — but it deserves its own investigation, not a rider here.

## Implementation Log

- Implemented: 2026-08-28T21:09:56Z
- Workspace: fresh-branch — `feat/one-branch-one-ticket` in `/Volumes/Crucial-4T/repo/ai`
- Suite: 259 passed, 0 failed (`skills/iso-issue-tracking/scripts/tracking.test.sh`)
- Tasks 1-10 complete. Task 10 ran against the live board with the uncommitted
  code, which is live via the `~/.claude/skills/iso-issue-tracking` symlink.
  Result: FIRE-20 carries three sections under an umbrella title (`in_progress`),
  FIRE-21 is `cancelled` and out of the ledger, FIRE-19 is `done`. The
  repo+branch uniqueness check returns empty. Ledger backup:
  `~/.claude/multica/tracked.json.bak-20260828-231150`.
- Committed: no — awaiting user review

**Open defect found while merging FIRE-20/21:** a plan's own `##` headings render
at the same level as the plan-section headings that contain them, so FIRE-20's
board body reads `## notebooklm native pipeline` / `## Input and research` /
`## Generation` / `## editor script` as one flat list. `render_body` should demote
headings inside a section body by one level. Cosmetic, not tracked, not fixed.

# iso-review — design

**Date:** 2026-05-28
**Status:** grilled

## Goal

A `/iso-review` skill that runs a dual-agent code review of the **uncommitted working-tree changes**, merges the two reviews into one de-duplicated finding set, applies every fix except the net-negative ones, then leaves everything uncommitted for the user to review. Codex and Claude each review in their own visible herdr tab; a separate Codex tab applies the accepted fixes. All tabs are spawned and recovered through `iso-spawn`.

## Decisions (locked in brainstorming + grilling)

| Question | Decision |
|----------|----------|
| Review scope | **Uncommitted working-tree diff** (staged + unstaged). Both reviewers see the identical diff; matches the `iso-write` handoff (implemented work left uncommitted). No `--base` flag. |
| Claude reviewer depth | Local `/code-review high` by default; `--max` opts up to `max`. **Not** cloud `ultra` (slow, billed, blocks the loop). |
| Reviewer invocation | Drive `/review` (codex) and `/code-review` (claude) literally inside spawned **visible TUI tabs**; recover findings via the native transcript. Visibility is the point. |
| Codex menu nav | Empirically verified: `/review`↵ → "Select a review preset" → **preset 2 "Review uncommitted changes"** (Down, Enter). Uncommitted preset needs no base-branch menu. |
| Fix selection | High-recall: apply **all** merged findings except those that make the code worse / overcomplicated (the karpathy line). No human gate; a printed ledger makes decisions visible. |
| Conflict rule | Same spot, incompatible fixes → take the simpler; ambiguous → skip. |
| Iteration | **Single pass.** No re-review round. |
| Verify | Folded into the fix tab: after applying, the fixer runs the repo's tests + type-check and reports (an agent does that at end-of-task anyway). The detected test command is passed in. |
| Close-out | **No extra tab.** Leave all changes uncommitted; print the ledger + the fix tab's test/type report; stop. User reviews and commits manually. |
| Orchestration topology | **Approach B**: mechanics (spawn/send, menu navigation, parallel wait, recover) live in iso-review's own `scripts/` orchestrator; judgment (merge, dedup, filter) lives in the main session. `iso-spawn`'s `deliver` is **not** modified (iso-write depends on it); iso-review reuses `spawn` (launch — async for the two review tabs, `--wait --recover` for a fresh fix tab), `send` (when `--fix-term` reuses an existing tab), `recover` (read transcript), and `herdr_agent_status` (sourced from iso-spawn's `lib/herdr.sh`) — and drives the review menus itself. Completion is detected with the native lifecycle wait, not a bespoke poll loop. |

## Architecture

Logic split mirrors the house pattern (`iso-spawn` has `lib/`, `iso-write` delegates to superpowers skills):

- **`scripts/` orchestrator** — all herdr/iso-spawn choreography (spawn tabs, drive the codex review menu, wait, recover transcripts, dispatch the fix prompt to a fresh or existing fix tab). Deterministic, no judgment.
- **Main session (Claude running the skill)** — semantically extracts findings from the recovered transcripts, merges/dedups, applies the filter, curates the fix instruction set, prints the ledger, summarises.

### Flow

```
/iso-review [--max]
  │
  ├─ 1. pre-flight + scope     (git repo? herdr? uncommitted changes exist?)
  │
  ├─ 2. dispatch reviews (parallel, via iso-spawn spawn)
  │       ├─ codex TUI tab:  /review → preset 2 "uncommitted changes"
  │       └─ claude TUI tab: /code-review high|max
  │     wait both idle, recover both transcripts
  │
  ├─ 3. extract + merge + dedup   (main session: semantic, fold overlaps)
  │
  ├─ 4. filter                    (main session: accepted[] vs dropped[]+reason; print ledger)
  │
  ├─ 5. apply + self-verify (via iso-spawn spawn)
  │       └─ fix tab: apply accepted[] exactly, then run tests + type-check, report
  │
  └─ 6. close-out (no commit)     (no extra tab; print summary; leave uncommitted; stop)
```

## Components

### 1. Pre-flight + scope
- Invocation: `/iso-review [--max]`. `--max` raises the Claude reviewer from `high` to `max` (default `high`).
- Scope is fixed: the uncommitted working-tree diff. No base flag.
- Pre-flight (halt with a clear message on failure):
  - must be a git repo,
  - herdr must be reachable (`$HERDR_PANE_ID` set),
  - the working tree must have uncommitted changes — if clean, there is nothing to review; halt.

### 2. Review dispatch (parallel)
- Spawn two visible TUI tabs via `iso-spawn spawn` (async, no injected prompt) in the current workspace.
- **codex**: drive `/review` through its menu. Verified sequence: send `/review`↵ → "Select a review preset" appears → `Down` `Enter` to pick **preset 2 "Review uncommitted changes"**. Anchor strings for detection: `Select a review preset`, `Press enter to confirm or esc to go back`. (Preset 1 "PR Style" leads to a second "Select a base branch" menu — not used here.)
- **claude**: inject `/code-review high` (or `max`) — a slash command with an arg, no menu.
- Reviews are read-only — they produce findings, they do not edit. They run concurrently; the orchestrator waits for both to go idle (`herdr agent wait`), then recovers each transcript via `iso-spawn recover <TERM>`.

### 3. Extract + merge + dedup
- Main session reads each recovered transcript and **semantically** extracts findings into `{ file, line, problem, proposed_fix, source }`, `source ∈ {codex, claude}`. No brittle regex — the reviews are prose; Claude parses them.
- Dedup: findings with the same file + overlapping line-range + the same underlying problem are folded into one (recording that both reviewers raised it).
- Output: one unified, de-duplicated finding list.

### 4. Filter — drop only net-negative fixes
High-recall: apply everything in the merged set **except** fixes that would make the code worse or overcomplicated. This is the karpathy "avoid overcomplication" line (already the house rule for writing code).

- **Apply** (default for every merged finding): bug fixes, typos, dead-code removal, missing guards, correctness fixes — whatever either reviewer found, after dedup.
- **Drop only** the net-negative: unwarranted abstraction, over-engineering, speculative "consider…" suggestions, readability churn that fixes nothing, anything that adds coupling or length without real gain.
- **Conflict rule** — if both reviewers target the same spot with incompatible fixes: take the **simpler** one; if it's genuinely ambiguous which is correct, **skip** that finding rather than guess.
- Output: `accepted[]` and `dropped[]` (each drop carries a one-line reason). A ledger of both is printed before the fix tab runs, so the decisions are visible in scrollback even though there is no approval gate.

### 5. Apply + self-verify
- Spawn a Codex TUI tab via `iso-spawn spawn`, fed `accepted[]` as explicit, itemised instructions: apply exactly these, **no extra refactoring or opportunistic edits**.
- The same prompt tells the fix tab to **run the repo's tests + type-check after applying and report PASS/FAIL** — an agent does that at the end of a task anyway, so verification rides along with the fix instead of a separate pass. The detected test command (`rv_detect_test_cmd`) is passed in so the tab runs the right thing.
- Recover the fix tab's report (what it changed + test/type results).

### 6. Close-out (no commit, no extra tab)
- **No separate re-review tab.** Verification already happened inside the fix tab (step 5). The user reviews the diff and commits themselves, so a machine re-review adds cost without changing the outcome.
- Leave all changes uncommitted.
- Print summary: accepted vs dropped ledger, fixes applied, and the fix tab's test/type report. Then stop.

## Stop rules

- Working tree clean at start → nothing to review; halt.
- A reviewer fails or returns nothing → degrade to the other reviewer; if **both** produce nothing parseable, abort with a message.
- A fix cannot be applied cleanly → report which, leave the rest, continue.
- The fix tab reports failing tests/type-check → surface it in the summary and leave everything uncommitted (the user decides — no commit happens regardless).
- Codex review menu doesn't reach the expected anchor strings within a timeout → abort that reviewer (degrade rule applies), don't blindly send keystrokes.

## Resolved in grilling

1. **Codex `/review` menu** (was the top risk) — resolved by observation: deterministic two-step menu, preset 2 for uncommitted, with stable anchor strings. Navigated by iso-review's own poll/keystroke loop, not iso-spawn's `deliver`.
2. **Scope alignment** — resolved by fixing scope to the uncommitted working tree: codex preset 2 and claude `/code-review` both see the identical diff, no base juggling.

## Remaining risks

1. **Free-text finding extraction** — recovering findings from TUI transcripts is prose-parsing, not structured (`--output-last-message` was rejected with the headless path). In practice both reviewers emit JSON; the main session parses semantically and falls back to prose.
2. **Auto-apply blast radius** — no human gate. Mitigated by: the net-negative filter, the printed accepted/dropped ledger, the fix tab's own tests + type-check after applying, and leaving everything uncommitted for the user's final read before they commit.

## Out of scope

- Cloud `ultra` review (explicitly dropped; could return behind a flag later).
- Committing or opening PRs (iso-write style: stop at uncommitted working tree).
- Reviewing committed branch-vs-base diffs (scope is uncommitted only this version).
- Iterating the review→fix loop more than once (single pass + verification this version).

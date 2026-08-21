# Multica tracking: skill-boundary transitions

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Make the Multica board record work at the boundaries the `iso-*` chain already crosses,
instead of guessing from prompts and pull requests. `/iso-plan` opens the card, `/iso-write` moves
it, `/iso-push` closes it and writes the retro. The board answers "what is being worked on and
where is it", not "what happened step by step".

**Status:** implemented (uncommitted) @ 2026-08-21T08:40:42Z

**Supersedes** `ai-agent/docs/superpowers/plans/2026-08-06-multica-work-tracker.md`, whose goal
line — *"prompts accumulate as comments, and the row moves `in_progress → in_review → done` off git
and GitHub facts"* — describes a design that has been replaced in both halves.

---

## Why this changes

The shipped tracker has a creation path that does not exist. `SessionStart → reconcile` and
`SessionEnd → end` only move rows already in the ledger; the `UserPromptSubmit` hook was the sole
thing that ever opened one, and it was removed for asking on every prompt including pure questions.
Two plans written by `/iso-plan` on 2026-08-19 produced no cards. The ledger is `{}`.

Three decisions drive the rewrite:

1. **Skill boundaries own the transitions.** Every status change corresponds to a point the chain
   already reaches and already announces. Nothing infers intent from a prompt.
2. **`in_review` does not depend on a PR.** It means "Iso should look at this", which is a claim
   about attention, not about GitHub.
3. **A card is not a work log.** Two lines of orientation on the parent; the plan file holds the
   detail; one retro comment at the merge.

## The state machine

| transition | fact that drives it | who writes it |
|---|---|---|
| → `todo` | `/iso-plan` finished writing the plan | `iso-plan` |
| → `in_progress` | `/iso-write` resolved its workspace (Step 2) | `iso-write` |
| → `blocked` | `/iso-write` halted, wrote `.iso/logs/write/<plan>.blocked.md` | `iso-write` |
| → `in_review` | `/iso-write` stamped the plan `implemented (uncommitted)` (Step 5) | `iso-write` |
| → `done` + retro | `/iso-push` landed the PR | `iso-push` |
| → `done`, no retro | merge happened outside a session | reconciler |
| → `cancelled` | branch gone, `gh` reachable, `opened_by=claude` | reconciler |

Sub-issues carry the same status as their parent and move with it. They exist to show which parts
of the app a plan touches, not to be ticked off individually.

## Card shape

Parent, two lines. It orients; it does not document.

```markdown
🌱 The wiki moves to explicit ingest and a scheduled push.

**Ambiti:** `be` · `ci` · `doc`
```

Sub-issues exist only when a plan has **≥8 tasks and ≥3 distinct scopes**. One per scope, never one
per task — a 12-task plan across 3 scopes is 1 card and 3 sub-issues. Each sub-issue carries the
`Working on:` detail for its scope, which is what you see when you open one.

Across the 26 plans on disk (min 3 tasks, median 7, max 12), the task gate alone selects 9; the
scope gate cuts that further. The scope vocabulary is closed at 14 entries, so the sub-issue count
is bounded by construction rather than by discipline.

## Scope of this plan

Touches `be` (the script), `doc` (SKILL.md and three `iso-*` skills) and `test` (the self-check) —
10 tasks, 3 scopes. By its own rule it earns sub-issues.

---

### Task 1: Delete the dead `prompt` subcommand

The nag hook is gone and nothing calls `prompt`. Its 6 assertions still pass, which is worse than
useless: they assert the behaviour of a code path no hook can reach.

- [x] **Step 1: Confirm nothing calls it**
      `grep -rn "tracking.sh prompt" ~/.claude/settings.json .claude/ 2>/dev/null` — expect
      no output.
- [x] **Step 2: Remove the `prompt)` arm** from `scripts/tracking.sh`, from `case "${1:-}"`
      through its `;;`.
- [x] **Step 3: Remove its assertions** from `scripts/multica-session.test.sh` — the `prompt / end`
      block, keeping every `end` assertion.
- [x] **Step 4: Run the suite.** Expect a lower count, 0 failed.

### Task 2: Stop the reconciler closing rows that never shipped

A branch with no commits points at the same commit as its integration branch, so
`git merge-base --is-ancestor` is trivially true and the row is marked `done` on the next session
start. Observed live: `2026-08-18T12:58:03Z reconcile FIRE-3 -> done (branch feat/multica-tracker
merged)` on a branch that had never been committed to. `done` is the status that stops anyone
looking.

- [x] **Step 1: Write the failing assertion.** A ledger row whose branch tip equals the integration
      tip must not be closed. Expect red.
- [x] **Step 2: Require a real difference** before ancestry counts as merged:
      ```bash
      if [ "$(git -C "$repo_dir" rev-parse "$br")" != "$(git -C "$repo_dir" rev-parse "$ib")" ]; then
        git -C "$repo_dir" merge-base --is-ancestor "$br" "$ib" 2>/dev/null && merged=1
        git -C "$repo_dir" merge-base --is-ancestor "$br" "origin/$ib" 2>/dev/null && merged=1
      fi
      ```
      A merged PR (`pr_state = MERGED`) is unaffected — it is checked before this and stays
      authoritative.
- [x] **Step 3: Run the suite.** Green.

### Task 3: Remove the PR-open → `in_review` rule

`in_review` now means `/iso-write` finished, which can happen with no PR at all, and a PR can be
open on work still in progress. The old rule contradicts both.

- [x] **Step 1: Delete the `pr_state = OPEN` branch** from the reconcile loop, keeping the `PR` url
      property write above it — click-through from card to PR is still wanted.
- [x] **Step 2: Remove the assertion** that covered it.
- [x] **Step 3: Run the suite.** Green.

### Task 4: Add `review`, `blocked` and `progress` subcommands

Three writes the chain needs and the script cannot currently make. Each takes a plan path, resolves
its card from the ledger, and moves the parent plus every sub-issue.

- [x] **Step 1: Write assertions first** for all three: each resolves parent + children, each is a
      no-op with an unknown plan path, each passes `--no-start`.
- [x] **Step 2: Add a `cards_for_plan()` helper** returning the parent key and, via
      `multica issue children <key> --output json`, its sub-issue keys.
- [x] **Step 3: Implement `review <plan_path>`** — set every resolved card to `in_review`.
- [x] **Step 4: Implement `blocked <plan_path>`** — set every resolved card to `blocked`.
- [x] **Step 5: Implement `progress <plan_path>`** — set every resolved card to `in_progress`.
      This is what un-blocks a row when `/iso-write` resumes.
- [x] **Step 6: Run the suite.** Green.

### Task 5: Reshape `open` for the two-line card and scope sub-issues

- [x] **Step 1: Write the assertions** — a `--plan` path is recorded in the ledger row; `--sub`
      creates one child per scope with `--parent`; no `--sub` creates none.
- [x] **Step 2: Add `--plan <path>`** to `open`, stored in the ledger row so `review`/`blocked`/
      `progress` can resolve a card from a plan path.
- [x] **Step 3: Add `--sub <scope>`** (repeatable) creating one sub-issue per scope under the new
      parent, each labelled with that scope, description read from stdin per child.
- [x] **Step 4: Keep `--stage` unused here.** Sub-issues are unordered — they are areas, not phases.
- [x] **Step 5: Run the suite.** Green.

### Task 6: Wire `/iso-plan` to open the card

The only step that can judge scopes is one where a model is live and has just read the plan. A
`SessionEnd` file scan can count `### Task N:` headings but cannot tell `be` from `ci`.

- [x] **Step 1: Add a final step to `skills/iso-plan/SKILL.md`** — after the plan file is written,
      inside a git repo, call `open` with a two-line description and the scope labels.
- [x] **Step 2: Document the sub-issue gate there** — count `### Task N:` headings and distinct
      scopes; pass `--sub` once per scope only when tasks ≥8 and scopes ≥3.
- [x] **Step 3: State the card-brevity rule** — one line of context plus the `**Ambiti:**` line.
      The plan file holds everything else.
- [x] **Step 4: Guard it.** Outside a repo, or with the script absent, `/iso-plan` proceeds
      unchanged. Tracking must never be able to fail a planning run.

### Task 7: Wire `/iso-write` to the three transitions

- [x] **Step 1: Step 2 of `iso-write`** — after the workspace is resolved, call
      `progress <plan_path>`.
- [x] **Step 2: Step 4 halt** — alongside writing the blocked marker, call `blocked <plan_path>`.
- [x] **Step 3: Step 4 resume** — where the marker is `rm -f`'d, call `progress <plan_path>`.
- [x] **Step 4: Step 5** — after the plan is stamped `implemented (uncommitted)`, call
      `review <plan_path>`.
- [x] **Step 5: Guard all four** the same way as Task 6.

### Task 8: Wire `/iso-push` to write the merge retro

Only the session that did the work holds the story: what was tried and abandoned, what changed
direction. Commits carry decisions; the transcript carries the problems, and it is gone by the time
a reconciler runs. `/iso-push` lands the PR in-session, which is the one point where "merged" and
"remembers why" overlap.

- [x] **Step 1: Add a retro step to `skills/iso-push/SKILL.md`** after step 6 integrates the feature
      PR: post one comment on the parent and one on each sub-issue, then set `done`.
- [x] **Step 2: Specify the format.** Lines only for things that happened; a clean run is two lines
      and no list. Cap ~6 lines / 60 words. Emoji marks kind: 🔀 direction change, 🐛 problem,
      ⚠️ known gap, 💡 discovery.
      ```markdown
      🏁 **Landed** · PR [#42](url)

      Swapped the polling loop for a webhook receiver.

      - 🔀 started with cron every 30s, dropped events under load, moved to webhook
      - 🐛 signature check failed on replays — clock skew, widened tolerance to 5m
      - ⚠️ retry backoff still fixed, not exponential
      ```
- [x] **Step 3: Scope each sub-issue's comment to its own area.** The parent's is about the whole.
- [x] **Step 4: Leave the reconciler's `done` in place** as the fallback for merges made outside a
      session. It posts no retro — it genuinely does not know.

### Task 9: Rewrite SKILL.md

- [x] **Step 1: Replace the situation table** with the transition table above.
- [x] **Step 2: Replace the card-writing section.** The current one prescribes a context paragraph
      plus a `Working on:` list for every card; that is now the sub-issue format. The parent is two
      lines.
- [x] **Step 3: Document the sub-issue gate** — ≥8 tasks and ≥3 scopes, one per scope.
- [x] **Step 4: Delete the `prompt` documentation.**
- [x] **Step 5: Keep** the scope vocabulary, the emoji-as-type table, the priority table and the
      `--agent` resume rule unchanged.

### Task 10: Verification against the live board

Not runnable in CI — it writes to the real board.

- [ ] **Step 1: Run `/iso-plan`** on a small seed inside a repo. Expect one card, `todo`, two-line
      description, scope labels, no sub-issues.
- [ ] **Step 2: Run `/iso-write`** on that plan. Expect `in_progress` at Step 2, `in_review` after
      Step 5, and no card created for the branch.
- [ ] **Step 3: Force a halt** and confirm `blocked`, then resume and confirm `in_progress`.
- [ ] **Step 4: Run `/iso-push --pr`.** Expect `done`, a retro comment on the parent, and the ledger
      row deleted.
- [ ] **Step 5: Confirm a commitless branch is not closed** — bind a row, start a session, check the
      log says nothing about `-> done`.

## Implementation Log
- Implemented: 2026-08-21T08:40:42Z
- Workspace: fresh-branch — `refactor/multica-tracking-shape`
- Committed: no — awaiting user review
- Tasks 1–9 complete, suite green at 142 passed / 0 failed (was 99 at baseline).
- Task 10 **not run**: it writes to the live Multica board and lands a real PR.
  Steps 1–4 need a live end-to-end chain run; Step 5 (a commitless branch must
  not be closed) is already covered by an automated assertion added in Task 2.
- Beyond the task list, three things the plan implied but did not spell out:
  `open` no longer promotes `todo → in_progress` (Task 10 Step 1 requires the
  card to stay at `todo`); a `retro` subcommand was added because Task 8 is a
  doc step with no way to reach `cards_for_plan()`; and the card resolver
  matches a branch as well as a plan path, because `/iso-push` only holds a
  branch.

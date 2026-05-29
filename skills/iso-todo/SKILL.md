---
name: iso-todo
description: Run a full development cycle — plan, then implement, then review — as one hands-off chain. Invoked as /iso-todo [--codex-only] [seed]. The parent session plans with iso-plan, spawns a codex implementation tab to run iso-write on a fresh feat/<slug> branch, keeps that tab alive, runs iso-review over the resulting uncommitted diff with reviewer tabs killed after recovery, and reuses the implementation tab for accepted fixes. With --codex-only, review skips Claude. Commits nothing. Use when the user runs /iso-todo, or asks to take an idea all the way from plan to implemented-and-reviewed without committing.
---

# iso-todo

The umbrella development-cycle orchestrator: `iso-plan` → `iso-write` → `iso-review`, chained into one run.

Invocation: `/iso-todo [--codex-only] [seed]`. With a seed, it brainstorms from that idea; bare, it brainstorms from the conversation so far. `--codex-only` is passed to the review phase so no Claude reviewer is spawned. It **always** runs all three phases — there is no plan-path entry, no phase-skip, no resume.

Helpers:
- `skills/iso-todo/scripts/todo.sh` — executable write/review mechanics after a plan exists.
- `skills/iso-todo/scripts/classify-impl.sh` — classifies the Implementation tab outcome.

**Never commit.** The whole feature (plan + implementation + review-fixes) is left as one uncommitted diff on `feat/<slug>` for the user to review and commit.

## Flow

```
/iso-todo [seed]
  1. PLAN   parent, interactive  → iso-plan → plan file P   (no plan → stop)
  2. WRITE  spawned codex tab    → /iso-write P (fresh branch); wait; classify
  3. REVIEW parent, black box    → iso-review (kills reviewer tabs; fixes in impl tab if accepted)
  4. CLOSE  parent               → no commit; summary card; leave impl/fix tab alive, offer cleanup
```

## Phase 1 — Plan (parent session)

Invoke the **`iso-plan`** skill. Pass the seed argument through if `/iso-todo` was given one; otherwise iso-plan works from the conversation. Capture the resulting plan path `P` (iso-plan prints the newest file under `docs/superpowers/plans/`).

If iso-plan produces no new plan (the user abandoned planning), stop here cleanly — spawn nothing, print `iso-todo: no plan produced — stopped.`

## Phase 2+3 — Write and Review (scripted)

After Phase 1 produces plan path `P`, delegate the executable Development cycle mechanics to:

```bash
skills/iso-todo/scripts/todo.sh run-plan "$P" [--codex-only]
```

Run it with its absolute path. It launches the Implementation tab through `iso-spawn --json`, sends `/iso-write "$P"`, waits and classifies the result, then runs `review.sh run --kill-review-tabs --fix-term "$TERM_IMPL"` plus `--codex-only` when requested, so the full iso-review path creates accepted fixes before applying them in the Implementation tab.

## Phase 2 — Write (spawned codex implementation tab)

The implementation is offloaded to a codex tab so the parent's context stays clean and you can watch the build. The tab shares the parent's checkout (same cwd → same `.git`), so its edits are exactly what Phase 3 reviews. **Wait for it to finish before reviewing — never review a moving tree.**

```bash
SPAWN=skills/iso-spawn/scripts/spawn.sh   # run with its absolute path

# 1. Launch the impl tab async (keep the tab alive — capture the bare TERM from stdout)
TERM_IMPL=$("$SPAWN" spawn codex --label iso-todo-impl --name itodoimpl)

# 2. Send the implementation command (fresh-branch mode → feat/<slug> derived from P)
"$SPAWN" send "$TERM_IMPL" "/iso-write $P"

# 3. Block until the turn finishes through the shared Spawn lifecycle seam.
wait_done "$TERM_IMPL" --timeout 3600

# 4. Classify the outcome — lifecycle completion alone does NOT mean success. Pass the plan path so the
#    classifier checks THIS plan's marker (.iso/logs/write/<plan-basename>.blocked.md).
OUTCOME=$("$SPAWN" recover "$TERM_IMPL" | skills/iso-todo/scripts/classify-impl.sh "$P")
```

Act on `$OUTCOME`:

- **`complete`** → proceed to Phase 3. **Leave the impl tab alive** so accepted review fixes can be applied in that same tab (see ADR 0001).
- **`blocked`** → iso-write halted. **Stop the pipeline.** Print the contents of `.iso/logs/write/$(basename "$P" .md).blocked.md` and the live impl `TERM`. Tell the user they can `send` guidance to that tab or take over manually. Do **not** run review.
- **`unknown`** → the tab timed out, died, or produced no recognizable signal. Treat as a halt: stop, print `recover "$TERM_IMPL" --what chat | tail -40` for context and the live `TERM`, hand off. Do **not** run review.

Record the branch for the summary: `git branch --show-current`.

## Phase 3 — Review (parent session, iso-review as a black box)

Invoke the **`iso-review`** skill (it reviews the uncommitted working tree — exactly the impl tab's output) with reviewer teardown and implementation-tab reuse:

```bash
/iso-review --kill-review-tabs --fix-term "$TERM_IMPL"
# Codex-only:
/iso-review --codex-only --kill-review-tabs --fix-term "$TERM_IMPL"
```

Pass `--max` only if the user asked for it. By default, iso-review spawns two ephemeral reviewer tabs; with `--codex-only`, it spawns only the Codex reviewer. It saves transcripts/findings, then kills those reviewer tabs. If accepted fixes are non-empty, it sends the fix prompt to the original implementation tab via `--fix-term "$TERM_IMPL"` and waits for that tab's test/type report. If nothing is accepted, iso-review spawns nothing and reports "no fixes."

Do **not** let iso-review spawn a separate fix tab during iso-todo; the implementation tab is the fix tab by design (ADR 0001). Read iso-review's summary (accepted/dropped ledger + the implementation tab's test/type report) for the card.

## Phase 4 — Close-out (parent session)

**Never commit, never open a PR.** Everything stays uncommitted on `feat/<slug>`.

Print the compact phase-checklist card (left-rule, no box frame; fill the real values):

```
  /iso-todo — <branch>              no commit
  ──────────────────────────────────────────
  ✓ Plan     <P>
  ✓ Write    <N files, +a/−b>    tab <TERM_IMPL> (alive)
  ✓ Review   <x fixed, y dropped>   tab <TERM_IMPL> (reused)
             tests <pass|fail> · types <pass|fail>

  Review the diff → commit yourself.
  Tab: <TERM_IMPL>
  → cleanup: skills/iso-spawn/scripts/spawn.sh cleanup <TERM> --kill
```

- Use `git diff --stat` for the Write line's file/line counts.
- If review accepted nothing, collapse the Review line to `✓ Review   0 findings` and omit the test detail.
- Leave the impl/fix tab **alive**. Then **offer** to tear it down — ask the user whether to run the cleanup, or `skills/iso-spawn/scripts/spawn.sh cleanup --orphaned`. Do not auto-kill.

## Stop rules

- iso-plan produced no plan → stop; spawn nothing.
- Phase 2 `blocked` or `unknown` → stop before review; surface + hand off; impl tab left alive.
- iso-review accepts no fixes → it spawns nothing; report "0 findings" and close normally.
- Not a git repo / herdr unreachable → the sub-skills' own preflight fails; surface its message and stop.

# iso-todo — design

**Date:** 2026-05-28
**Status:** grilled

## Goal

A `/iso-todo [seed]` skill: the umbrella development-cycle orchestrator. It chains the three existing IsaiaScope verbs — `iso-plan` → `iso-write` → `iso-review` — into one hands-off run. The parent session plans interactively, spawns a **codex implementation tab** to execute the plan via `iso-write`, keeps that tab alive, then runs `iso-review` over the resulting uncommitted diff. Nothing is ever committed; the whole feature (plan + implementation + review-fixes) lands as a single uncommitted diff on a fresh `feat/<slug>` branch for the user to review and commit.

iso-todo adds **no new editing capability** — it is orchestration glue. Its only genuinely new logic is the done-vs-blocked disambiguation of the implementation tab and the keep-the-impl-tab-alive lifecycle.

## Decisions (locked in grilling)

| Question | Decision |
|----------|----------|
| Name / trigger | `/iso-todo [seed]`. Fits the verb family (plan/write/review/todo). |
| Entry contract | **Seed-only, always all 3 phases.** Bare → brainstorm from conversation context. With text → seed idea. No plan-path reuse, no phase-skip, no resume flags. |
| Phase 1 — Plan | Parent session runs `iso-plan` (interactive: brainstorm + grill need the user). Output: plan file `P`. No plan produced → stop. |
| Phase 2 — Write | Parent spawns a **codex impl tab** (`iso-spawn spawn`, full-perm, caller's cwd), sends `/iso-write P`. **Fresh-branch mode** (default) → `feat/<slug>` derived from the plan filename. |
| Impl agent kind | **codex, fixed** for v1. A `--claude` impl option is a trivial future add. |
| Impl tab lifecycle | **Kept alive** for the whole run — never killed mid-pipeline, and reused for accepted review fixes. Async `spawn` (not `deliver --kill`) so the `TERM` survives. |
| Wait + disambiguation | `herdr agent wait <TERM_impl> --status idle` (generous timeout). Idle status alone is ambiguous (a halted agent looks identical to a finished one), so verify: this plan's blocked marker `.iso/logs/write/<plan-basename>.blocked.md` / dead tab → halt path; "✓ Implementation complete" banner / stamped plan → proceed. |
| Blocked marker | iso-write writes its halt marker to **`.iso/logs/write/<plan-basename>.blocked.md`** (not repo-root `BLOCKED.md`). Keyed per plan → multiple blocked plans never collide; lives under git-ignored `.iso/logs` (matches `spawn`/`review`) so it stays out of the review scope; iso-write clears its own at start so a post-run marker is always *this* run's. A global iso-write contract change (all callers), not an iso-todo shim. |
| Halt handling | **Stop, surface, hand off.** Do not review a half-done implementation. Print `.iso/logs/write/<plan-basename>.blocked.md` + the live impl `TERM`; the user takes over via that tab. |
| Phase 3 — Review | Parent runs `iso-review` **as a black box** with `--kill-review-tabs --fix-term <TERM_IMPL>`. It spawns 2 ephemeral reviewer tabs (codex `/review`, claude `/code-review`), saves their transcripts, kills them, then reuses the implementation tab for accepted fixes. |
| Fix-tab gating | iso-review spawns its fix tab **only if the *accepted* list is non-empty.** No accepted fixes → stop, spawn nothing, implement nothing. (Requires a small iso-review hardening — see below.) |
| Commit policy | **No commit, ever.** Consistent with both sub-skills. Plan + impl + fixes = one uncommitted diff on `feat/<slug>`. |
| End-of-run tabs | **Leave the implementation/fix tab alive, offer cleanup.** Reviewer tabs are killed after transcript recovery. iso-todo prints the implementation `TERM` + the cleanup command and offers to tear it down. |
| Final summary | **Compact phase-checklist card** (left-rule, no box frame) — one line per phase + tabs + "review the diff → commit yourself." |

## Architecture

iso-todo is a thin orchestrator. It owns no `scripts/` mechanics of its own beyond invoking the three sub-skills and managing one long-lived `iso-spawn` tab; all heavy lifting lives in the skills it sequences.

- **Phase 1 + 3 run in the parent session** — the judgment/interactive parts. `iso-plan` needs the user (brainstorm, grill); `iso-review` is itself an orchestrator the parent drives.
- **Phase 2 runs in a spawned codex tab** — the implementation is offloaded so the parent's context stays clean and the user can watch the build happen in a visible tab.
- **One working tree.** `iso-spawn` defaults the spawned agent's cwd to the parent's cwd → same `.git`, same checkout. So the codex tab's `iso-write` edits and the parent's later `iso-review` see the *identical* uncommitted diff with zero handoff artifact — **provided the parent waits for the impl tab to finish before reviewing** (strictly sequential; never concurrent edits to the shared tree).

### Flow

```
/iso-todo [seed]
  │
  ├─ 1. PLAN  (parent, interactive)
  │       └─ invoke iso-plan  →  plan file P  (no plan → stop)
  │
  ├─ 2. WRITE (spawned codex impl tab)
  │       ├─ TERM_impl = iso-spawn spawn codex            (async, full-perm, caller cwd)
  │       ├─ iso-spawn send TERM_impl "/iso-write P"      (fresh-branch → feat/<slug>)
  │       ├─ herdr agent wait TERM_impl --status idle
  │       └─ disambiguate:
  │            .iso/logs/write/<slug>.blocked.md / dead → STOP, surface, hand off (impl tab alive)
  │            "✓ complete"        → proceed   (impl tab KEPT ALIVE)
  │
  ├─ 3. REVIEW (parent, black-box iso-review)
  │       └─ invoke iso-review
  │            ├─ spawns 2 reviewer tabs → merge + filter
  │            ├─ accepted non-empty → sends fixes to impl tab → apply + test + report
  │            └─ accepted empty     → stop, implement nothing
  │
  └─ 4. CLOSE (parent)
          ├─ no commit
          ├─ print compact phase-checklist card
          └─ leave impl/fix tab alive; print TERM; offer cleanup
```

## Components

### 1. Plan (parent, interactive)
- Invoke `iso-plan`. If a seed was passed to `/iso-todo`, hand it to iso-plan; otherwise iso-plan brainstorms from the conversation.
- Capture the plan path `P` from iso-plan's output (newest file under `docs/superpowers/plans/`).
- iso-plan produced no new plan (user abandoned) → stop iso-todo cleanly; spawn nothing.

### 2. Write (spawned codex impl tab)
- `TERM_impl = iso-spawn spawn codex` — async (so the tab outlives the call), full permissions (default), caller's cwd (same checkout). Capture the bare `TERM` from stdout.
- Send `/iso-write P` with no workspace flag → iso-write derives `feat/<slug>` from `P`'s filename, stash-carries the uncommitted plan file onto it, and implements there via TDD.
- Wait: `herdr agent wait <TERM_impl> --status idle --timeout <generous>`.
- **Disambiguate** once idle (status alone is unreliable — see Insight):
  - this plan's marker `.iso/logs/write/<plan-basename>.blocked.md` exists, or the tab is dead/errored → **halt path** (component below). The classifier derives `<plan-basename>` from `P` so a stale marker from a *different* plan is ignored.
  - iso-write's "✓ Implementation complete" banner recovered / plan stamped `**Status:** implemented (uncommitted)` → success; proceed.
- The impl tab is **kept alive** and reused as the fix tab.

### 3. Review (parent, black-box iso-review)
- Invoke `iso-review` (no `--max` by default; pass it through if the user asked).
- iso-review owns review mechanics: two ephemeral reviewer tabs, merge/dedup/filter in the parent, then — **only when the accepted list is non-empty** — a fix prompt sent to `TERM_IMPL` via `--fix-term`.
- iso-todo reads iso-review's summary (accepted/dropped ledger + implementation tab's test/type report) for the final card.

### 4. Close-out (parent, no commit)
- Never commit, never open a PR.
- Print the **compact phase-checklist card**:

```
  /iso-todo — feat/<slug>            no commit
  ──────────────────────────────────────────
  ✓ Plan     docs/superpowers/plans/<...>.md
  ✓ Write    <N> files, +<a>/−<b>    tab <TERM_impl> (alive)
  ✓ Review   <x> fixed, <y> dropped  tab <TERM_fix> (alive)
             tests <pass|fail> · types <pass|fail>

  Review the diff → commit yourself.
  Tabs: <TERM_impl> <TERM_fix>
  → cleanup: scripts/spawn.sh cleanup <TERM> --kill
```

- Leave the impl/fix tab alive; offer to tear it down (or run `cleanup --orphaned`).
- Omit the Review line's fix-tab/test detail if no fixes were applied (just "0 findings").

## Required changes to sub-skills

Two small, independently-useful edits to the skills iso-todo sequences. Both keep the sub-skill fully usable standalone.

### iso-review — gate the fix tab on the *accepted* list

Gate the fix-tab spawn on a **non-empty *accepted*** list, not merely on non-empty raw reviewer output. Today iso-review stops only when *both reviewer files* are empty (SKILL.md step 3); the "reviewers raised findings but the filter (step 5) dropped them all" case must also spawn nothing and stop. Verify the current `review.sh apply` guard during the build and add the check if missing. Default behavior is unchanged.

### iso-write — relocate + per-plan-key the blocked marker

Move iso-write's halt marker from repo-root `BLOCKED.md` to **`.iso/logs/write/<plan-basename>.blocked.md`**, where `<plan-basename>` is `<plan_path>` minus its `.md`. Three reasons:

- **Multi-plan safety** — keying by plan means two plans that both halt land in distinct files; no collision, no overwrite.
- **Out of review scope** — `.iso/` is git-ignored, so the marker no longer shows in `git status` / the iso-review diff. Matches the existing `.iso/logs/spawn` and `.iso/logs/review` convention.
- **No stale false-positives** — iso-write clears *this plan's* marker at the start of execution (mirroring iso-review's wipe of `.iso/logs/review`), so any marker present after the run is definitively from this run.

This is a global iso-write contract change: the halt banner becomes `Halted at task <N>. See .iso/logs/write/<plan-basename>.blocked.md.`, and the README is updated. iso-todo's `classify-impl.sh` takes `P` as an argument and checks the keyed path, so it never trips over another plan's marker.

## Stop rules

- `iso-plan` produces no plan → stop; spawn nothing.
- Impl tab halts (`.iso/logs/write/<plan-basename>.blocked.md`) or dies → **stop before review**; surface the blocker + the live impl `TERM`; hand off.
- `iso-review` finds no accepted fixes → it stops itself; iso-todo reports "0 findings" and closes.
- Not a git repo / herdr unreachable → fail pre-flight with a clear message (inherited from the sub-skills' own pre-flight).

## Resolved in grilling

1. **Reuse vs fresh fix tab** (the wrinkle) — settled on **reuse** for `iso-todo`: the impl tab becomes the fix tab via `iso-review --fix-term <TERM_IMPL>`. Reasoning: the implementer has the feature context and this avoids leaving an extra fix tab alive. Standalone `iso-review` still uses a fresh fix tab by default.
2. **Shared-checkout constraint** — fresh-branch (not worktree) chosen so the parent's `iso-review` sees the codex tab's edits in the same directory. `--worktree` would put edits in `.worktrees/<slug>/` where the parent's review would see a clean tree.
3. **Done-vs-blocked** — herdr `idle` can't distinguish a finished agent from a halted one; resolved by verifying iso-write's success banner / the per-plan blocked marker after the wait.
4. **Blocked-marker location & collisions** — repo-root `BLOCKED.md` was a single fixed path (two halted plans collide) and polluted the review scope. Relocated to git-ignored `.iso/logs/write/<plan-basename>.blocked.md`, keyed per plan, cleared by iso-write at start. Chosen as a global iso-write change (one contract) over an iso-todo-only shim (two mechanisms). Trade-off accepted: the marker is less in-your-face than a root file, but the halt banner prints its exact path.

## Remaining risks

1. **Long-implementation wait** — `iso-write` can run for a long time; the parent blocks on `herdr agent wait` with a generous timeout. If it times out, treat as the halt path (surface + hand off) rather than proceeding to review.
2. **Branch already exists** — iso-write halts if `feat/<slug>` already exists. iso-todo surfaces that as the halt path; the user renames the plan or cleans the branch and re-runs.

## Out of scope

- Committing or opening PRs (sub-skill style: stop at uncommitted working tree).
- Plan-path entry / phase-skip / resume (seed-only this version).
- `--worktree` implementation mode (breaks the shared-checkout review assumption).
- `claude` as the implementation agent (codex-only this version; future flag).
- Spawning a separate fix tab during `iso-todo` (standalone `iso-review` still may).

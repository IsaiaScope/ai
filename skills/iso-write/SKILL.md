---
name: iso-write
description: Implement a written plan using TDD, without committing. Use when invoked as /iso-write <plan_path> [--no-branch | --branch=<name> | --worktree] or handed an implementation plan to build. By default it cuts a fresh branch from the plan filename only when the current branch is a base branch (dev, develop, test, prod, main, master) or detached, and otherwise stays on the feature branch already checked out; --no-branch always implements on the current branch; --branch=<name> uses a named branch; --worktree runs in an isolated worktree. Delegates execution to superpowers executing-plans (red-green-refactor per task), stamps the plan done, and stops so the user reviews all changes before any commit. Agent-independent (Claude Code or Codex).
---

# iso-write

Execute a Claude/Codex-authored plan using TDD in the workspace mode the user picks. **Never commit.** Leave every change in the working tree so the user reviews the full diff at the end of the writing session and commits manually.

## Input

Invoked as `/iso-write <plan_path> [workspace-flag]` — `<plan_path>` is the path to the plan markdown file (e.g. `docs/superpowers/plans/2026-05-26-feat-thing.md`).

An optional **workspace flag** selects where the implementation happens. The flags are mutually exclusive:

| Flag | Workspace |
|------|-----------|
| *(none)* | **Reuse or cut** — on a base branch (`dev`, `develop`, `test`, `prod`, `main`, `master`) or detached HEAD, derive `<type>/<slug>` from the plan filename and create it. Already on a feature branch: stay on it, create nothing. |
| `--no-branch` | **In place** — stay on the current branch, no checkout. |
| `--branch=<name>` | **Named branch** — checkout `<name>`, creating it if missing. |
| `--worktree` | **Worktree** — isolated worktree on a fresh `<type>/<slug>` branch via the `using-git-worktrees` skill. |

If `<plan_path>` is missing or the file does not exist, halt:
`iso-write: plan not found: <plan_path>`.

If more than one workspace flag is given, halt:
`iso-write: pick one workspace mode`.

## Pre-flight

```bash
# scripts/write.sh resolve refuses on all three: no git, no repo, no plan.
eval "$(scripts/write.sh resolve "$plan_path" $workspace_flag)"
# $mode and $branch are now set
```

A dirty working tree (staged or unstaged) is **not** refused. How Step 2 handles it depends on the mode: the default and `--branch=<name>` modes stash the changes and carry them onto the target branch; `--no-branch` leaves them in place; `--worktree` leaves them in the main checkout (the worktree starts clean).


## Tracking

Each transition below runs through one guarded call. It is a no-op when the
script is absent or the working directory is not a repo — tracking must never be
able to fail a write run:

```bash
scripts/write.sh track <progress|review|blocked> "$plan_path"
```

The card is resolved from `<plan_path>` alone — the same path `/iso-plan` recorded
with `--plan` when it opened the card. A plan written by hand was never carded, so
the call resolves nothing and does nothing, which is correct. One plan is one
card, so each transition is a single status write.
## Step 1: Read the full plan

Read `<plan_path>` end-to-end before touching anything. Understand all tasks, file layout, and architectural decisions.

## Step 2: Resolve the workspace mode

Derive the branch name from the plan filename `YYYY-MM-DD-<type>-<slug>.md` — needed by the default and `--worktree` modes:

- Strip the `YYYY-MM-DD-` date prefix.
- Take the next token as `<type>` if it is one of `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`; `<slug>` is the remainder.
- If that token is not a known type, default `<type>=feat` and `<slug>` is the full remainder after the date prefix.
- Empty slug → halt: `iso-write: empty slug after type prefix`.

Derived branch name: `<type>/<slug>`. The branch name always follows the plan's type, so a `fix` plan lands on `fix/<slug>`, a `feat` plan on `feat/<slug>`, and so on.

Then prepare the workspace according to the flag.

**Stash-carry** (shared by the default and `--branch=<name>` modes): before switching branches, carry any uncommitted work across via a named stash, then pop exactly that stash.

The carry is `scripts/write.sh`'s job — it stashes under a label naming the
target branch and pops exactly that stash, so a concurrent stash cannot be
popped by mistake.

### Default — fresh branch, but only from a base branch

**A branch is cut only when there is nowhere else to be.** If the current branch is already a feature branch, the plan is implemented on it and nothing is created.

```bash
# handled by: scripts/write.sh resolve "$plan_path"
```

Why the gate: the default used to cut `<type>/<slug>` unconditionally, and since this skill **never commits**, every run left a branch pointing at the base's tip with nothing on it. Four accumulated in `ai-agent` inside two days, all at the same SHA. They isolated nothing either — one working tree, one index, so `checkout -b` only relabelled the same uncommitted pile. Isolation comes from committing, or from `--worktree`; a branch with no commits buys the bookkeeping and none of the separation.

`test`, `prod`, `main` and `master` sit in the create list beside `dev`/`develop` for the reason `iso-push` refuses them — they are places work is promoted **to**, never worked **on**. A detached HEAD (`""`) also cuts a branch, so the work gets a ref to live on.

All edits and tests happen on the resulting branch in the current working directory. Pre-existing uncommitted work is carried onto a newly created branch, and simply stays put when the current branch is reused — appearing either way in the final review diff alongside the plan's changes.

### `--no-branch` — implement in place

No checkout, no stash. The plan is implemented on whatever branch is currently checked out. Pre-existing uncommitted work stays put and lands in the final review diff alongside the plan's changes. Record the current branch (`git branch --show-current`) for the Step 6 summary.

### `--branch=<name>` — named branch

```bash
# handled by: scripts/write.sh resolve "$plan_path" --branch=<name>
```

### `--worktree` — isolated worktree

Invoke the **superpowers `using-git-worktrees` skill** to create the isolated workspace, requesting the derived `<type>/<slug>` branch name. That skill prefers a native worktree tool, falls back to `git worktree`, picks the directory (`.worktrees/` convention), and verifies the directory is git-ignored. All subsequent edits and tests run **inside the worktree**.

Uncommitted work in the main checkout is **not** carried — the worktree is isolated by design and starts clean from the current HEAD. Tell the user their uncommitted changes remain in the original checkout. Record the worktree path for the Step 6 summary.

### Mark the card in progress

The workspace is now resolved, which is the moment work actually starts. Move the
card:

```bash
scripts/write.sh track progress "$plan_path"
```

This is the only place `in_progress` is written. Nothing infers it from a prompt,
and nothing infers it from a branch existing — a branch can sit unused for days.

## Step 3: Execute the plan with TDD (no commits)

Before the first task, clear any stale marker for *this* plan, so a leftover from an earlier run cannot be mistaken for this run's halt (`<plan-basename>` is `<plan_path>`'s filename minus `.md`). Do **not** create the directory here — `rm -f` is a no-op when it does not exist, and `docs/iso/logs/write/` should only appear if a halt actually writes a marker:

    rm -f "docs/iso/logs/write/<plan-basename>.blocked.md"

Invoke the **superpowers `executing-plans` skill** to drive execution, and the **`test-driven-development` skill** for each task's red-green-refactor loop.

Hard constraints that override any commit guidance inside those skills:

- **Do NOT commit.** Skip every "commit after task" / "commit at checkpoint" step. Changes accumulate in the working tree only.
- Follow the plan's task ordering exactly.
- For each task with a specified test: write the failing test → run it, confirm it fails as expected → write the minimal implementation → run it, confirm it passes.
- Tasks without a test (config, docs, build edits) are implemented directly.
- After finishing a task, tick its checkbox in `<plan_path>`: replace `- [ ]` with `- [x]` for that task's lines, in the original plan file.

## Step 4: Stop rules

Halt immediately if:

- A test fails repeatedly (>3 attempts) and the plan does not document the expected failure.
- A file path in the plan does not exist and cannot be unambiguously inferred.
- A referenced dependency is missing and not listed as something to install.
- A plan instruction is ambiguous or self-contradictory.

On halt: write the blocked marker `docs/iso/logs/write/<plan-basename>.blocked.md` (create `docs/iso/logs/write/` if needed; `<plan-basename>` is `<plan_path>`'s filename minus `.md`) with the failed task number/title, the exact error or ambiguity, what you tried, and the suggested next action. Then print `Halted at task <N>. See docs/iso/logs/write/<plan-basename>.blocked.md.` and wait for user input. Do not commit, do not exit.

Mark the card blocked at the same time, so the board shows where the run stopped:

```bash
scripts/write.sh track blocked "$plan_path"
```

**On resume**, once the ambiguity is settled and the marker is removed
(`rm -f "docs/iso/logs/write/<plan-basename>.blocked.md"`), move it back before
continuing:

```bash
scripts/write.sh track progress "$plan_path"
```

## Step 5: Finalize (still no commit)

After the last task's checkbox is ticked, stamp the plan file in-place. Insert immediately after the `**Goal:**` line:

```
**Status:** implemented (uncommitted) @ <iso-timestamp>
```

Append a footer:

```
## Implementation Log
- Implemented: <iso-timestamp>
- Workspace: <mode> — <branch> (worktree mode also records the worktree path)
- Committed: no — awaiting user review
```

Then move the card to review — the plan is implemented and Iso should look at it:

```bash
scripts/write.sh track review "$plan_path"
```

`in_review` is a claim about attention, not about GitHub. It is set here whether
or not a PR exists; `/iso-push` is what later closes the card.

## Step 6: Print review summary and stop

```
✓ Implementation complete — nothing committed.
  Mode:    <fresh-branch | current-branch | no-branch | named-branch | worktree>
  Branch:  <branch>          (the current branch for --no-branch)
  Worktree: <path>           (only printed in --worktree mode)
  Plan:    <plan_path> (stamped)
  Files changed:
<output of `git diff --stat`>

Review the full diff, then commit yourself when satisfied.
```

For `--worktree`, remind the user the changes live in the worktree directory, not the main checkout.

Then halt all autonomous action. Treat further messages as in-branch refinement requests. **Do not commit. Do not open a PR.** The user reviews everything and commits manually.

---
name: iso-write
description: Implement a written plan on a fresh feature branch using TDD, without committing. Use when invoked as /iso-write <plan_path> or handed an implementation plan to build. Creates the branch, delegates execution to superpowers executing-plans (red-green-refactor per task), stamps the plan done, and stops so the user reviews all changes before any commit. Agent-independent (Claude Code or Codex).
---

# iso-write

Execute a Claude/Codex-authored plan on a new feature branch using TDD. **Never commit.** Leave every change in the working tree so the user reviews the full diff at the end of the writing session and commits manually.

## Input

Invoked as `/iso-write <plan_path>` — `<plan_path>` is the path to the plan markdown file (e.g. `docs/superpowers/plans/2026-05-26-feat-thing.md`).

If `<plan_path>` is missing or the file does not exist, halt:
`iso-write: plan not found: <plan_path>`.

## Pre-flight

```bash
command -v git &>/dev/null || { echo "✗ git not found"; exit 1; }
git rev-parse --is-inside-work-tree &>/dev/null || { echo "✗ not a git repo"; exit 1; }
[ -f "$plan_path" ] || { echo "✗ plan not found: $plan_path"; exit 1; }
```

A dirty working tree (staged or unstaged) is **not** refused — Step 2 stashes the changes and carries them onto the new branch.

## Step 1: Read the full plan

Read `<plan_path>` end-to-end before touching anything. Understand all tasks, file layout, and architectural decisions.

## Step 2: Derive and create the branch

Parse the plan filename `YYYY-MM-DD-<type>-<slug>.md`:

- Strip the `YYYY-MM-DD-` date prefix.
- Take the next token as `<type>` if it is one of `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`; `<slug>` is the remainder.
- If that token is not a known type, default `<type>=feat` and `<slug>` is the full remainder after the date prefix.
- Empty slug → halt: `iso-write: empty slug after type prefix`.

Branch name: `<type>/<slug>`.

```bash
if git rev-parse --verify "$branch" &>/dev/null; then
  echo "✗ branch $branch already exists. Delete it or rename the plan."
  exit 1
fi
# Carry any uncommitted work onto the new branch via a named stash.
stash_name="iso-write/$branch"
carried=0
if [ -n "$(git status --porcelain)" ]; then
  git stash push -u -m "$stash_name"
  carried=1
fi
git checkout -b "$branch"
if [ "$carried" = "1" ]; then
  # Pop the specific stash we made, not whatever happens to be on top.
  ref=$(git stash list --format='%gd %s' | grep -F "$stash_name" | head -1 | cut -d' ' -f1)
  ref="${ref:-stash@{0}}"
  git stash pop "$ref" || { echo "✗ stash pop conflict on $branch. Resolve, then re-run."; exit 1; }
fi
```

All edits and tests happen on this branch in the current working directory. No worktree. Any pre-existing uncommitted work is carried onto the branch and will appear in the final review diff alongside the plan's changes.

## Step 3: Execute the plan with TDD (no commits)

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

On halt: write `BLOCKED.md` at the repo root with the failed task number/title, the exact error or ambiguity, what you tried, and the suggested next action. Then print `Halted at task <N>. See BLOCKED.md.` and wait for user input. Do not commit, do not exit.

## Step 5: Finalize (still no commit)

After the last task's checkbox is ticked, stamp the plan file in-place. Insert immediately after the `**Goal:**` line:

```
**Status:** implemented (uncommitted) @ <iso-timestamp>
```

Append a footer:

```
## Implementation Log
- Implemented: <iso-timestamp>
- Branch: <branch>
- Committed: no — awaiting user review
```

## Step 6: Print review summary and stop

```
✓ Implementation complete — nothing committed.
  Branch:  <branch>
  Plan:    <plan_path> (stamped)
  Files changed:
<output of `git diff --stat`>

Review the full diff, then commit yourself when satisfied.
```

Then halt all autonomous action. Treat further messages as in-branch refinement requests. **Do not commit. Do not open a PR.** The user reviews everything and commits manually.

---
name: iso-write
description: Implement a written plan using TDD, without committing. Use when invoked as /iso-write <plan_path> [--no-branch | --branch=<name> | --worktree] or handed an implementation plan to build. Default creates a fresh branch from the plan filename; --no-branch implements on the current branch; --branch=<name> uses a named branch; --worktree runs in an isolated worktree. Delegates execution to superpowers executing-plans (red-green-refactor per task), stamps the plan done, and stops so the user reviews all changes before any commit. Agent-independent (Claude Code or Codex).
---

# iso-write

Execute a Claude/Codex-authored plan using TDD in the workspace mode the user picks. **Never commit.** Leave every change in the working tree so the user reviews the full diff at the end of the writing session and commits manually.

## Input

Invoked as `/iso-write <plan_path> [workspace-flag]` — `<plan_path>` is the path to the plan markdown file (e.g. `docs/superpowers/plans/2026-05-26-feat-thing.md`).

An optional **workspace flag** selects where the implementation happens. The flags are mutually exclusive:

| Flag | Workspace |
|------|-----------|
| *(none)* | **Fresh branch** — derive `<type>/<slug>` from the plan filename and create it (default, unchanged). |
| `--no-branch` | **In place** — stay on the current branch, no checkout. |
| `--branch=<name>` | **Named branch** — checkout `<name>`, creating it if missing. |
| `--worktree` | **Worktree** — isolated worktree on a fresh `<type>/<slug>` branch via the `using-git-worktrees` skill. |

If `<plan_path>` is missing or the file does not exist, halt:
`iso-write: plan not found: <plan_path>`.

If more than one workspace flag is given, halt:
`iso-write: pick one workspace mode`.

## Pre-flight

```bash
command -v git &>/dev/null || { echo "✗ git not found"; exit 1; }
git rev-parse --is-inside-work-tree &>/dev/null || { echo "✗ not a git repo"; exit 1; }
[ -f "$plan_path" ] || { echo "✗ plan not found: $plan_path"; exit 1; }
```

A dirty working tree (staged or unstaged) is **not** refused. How Step 2 handles it depends on the mode: the default and `--branch=<name>` modes stash the changes and carry them onto the target branch; `--no-branch` leaves them in place; `--worktree` leaves them in the main checkout (the worktree starts clean).

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

```bash
stash_carry() {  # arg: target branch name, used to label the stash
  local stash_name="iso-write/$1"
  if [ -n "$(git status --porcelain)" ]; then
    git stash push -u -m "$stash_name" >&2 || { echo "✗ stash failed" >&2; exit 1; }
    echo "$stash_name"   # echo the label (only this) so the caller can pop it after checkout
  fi
}
stash_pop() {  # arg: the stash label returned by stash_carry (empty = nothing to pop)
  [ -z "$1" ] && return 0
  local ref
  ref=$(git stash list --format='%gd %s' | grep -F "$1" | head -1 | cut -d' ' -f1)
  ref="${ref:-stash@{0}}"
  git stash pop "$ref" || { echo "✗ stash pop conflict. Resolve, then re-run."; exit 1; }
}
```

### Default — fresh branch

```bash
if git rev-parse --verify "$branch" &>/dev/null; then
  echo "✗ branch $branch already exists. Delete it, rename the plan, or pass --branch=$branch."
  exit 1
fi
label=$(stash_carry "$branch")
git checkout -b "$branch"
stash_pop "$label"
```

All edits and tests happen on this branch in the current working directory. Any pre-existing uncommitted work is carried onto the branch and appears in the final review diff alongside the plan's changes.

### `--no-branch` — implement in place

No checkout, no stash. The plan is implemented on whatever branch is currently checked out. Pre-existing uncommitted work stays put and lands in the final review diff alongside the plan's changes. Record the current branch (`git branch --show-current`) for the Step 6 summary.

### `--branch=<name>` — named branch

```bash
label=$(stash_carry "$name")
if git rev-parse --verify "$name" &>/dev/null; then
  git checkout "$name"          # existing branch — reuse it, no halt (named on purpose)
else
  git checkout -b "$name"       # create it
fi
stash_pop "$label"
branch="$name"
```

### `--worktree` — isolated worktree

Invoke the **superpowers `using-git-worktrees` skill** to create the isolated workspace, requesting the derived `<type>/<slug>` branch name. That skill prefers a native worktree tool, falls back to `git worktree`, picks the directory (`.worktrees/` convention), and verifies the directory is git-ignored. All subsequent edits and tests run **inside the worktree**.

Uncommitted work in the main checkout is **not** carried — the worktree is isolated by design and starts clean from the current HEAD. Tell the user their uncommitted changes remain in the original checkout. Record the worktree path for the Step 6 summary.

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
- Workspace: <mode> — <branch> (worktree mode also records the worktree path)
- Committed: no — awaiting user review
```

## Step 6: Print review summary and stop

```
✓ Implementation complete — nothing committed.
  Mode:    <fresh-branch | no-branch | named-branch | worktree>
  Branch:  <branch>          (the current branch for --no-branch)
  Worktree: <path>           (only printed in --worktree mode)
  Plan:    <plan_path> (stamped)
  Files changed:
<output of `git diff --stat`>

Review the full diff, then commit yourself when satisfied.
```

For `--worktree`, remind the user the changes live in the worktree directory, not the main checkout.

Then halt all autonomous action. Treat further messages as in-branch refinement requests. **Do not commit. Do not open a PR.** The user reviews everything and commits manually.

---
name: dispatch-to-codex
description: Dispatch the latest writing-plans output to Codex CLI in a new Warp terminal tab. Reads the plan file, builds a self-contained brief with the full execution protocol embedded, and auto-launches Codex. Use immediately after writing-plans completes and the user approves the plan.
---

# Dispatch to Codex

Hand off an implementation plan to Codex CLI in a new Warp tab. The brief written to `/tmp/codex-dispatch.txt` contains the full execution protocol — Codex needs nothing else from AGENTS.md to run the plan.

## Pre-flight

Run before Step 1.

### python3 (URL encoding in Step 5)
```bash
command -v python3 &>/dev/null \
  || { echo "✗ python3 not found. Install: brew install python3"; exit 1; }
```

### codex CLI
```bash
if ! command -v codex &>/dev/null; then
  echo "⚠ codex not found — installing..."
  npm install -g @openai/codex
  command -v codex &>/dev/null \
    || { echo "✗ codex install failed. Run manually: npm install -g @openai/codex"; exit 1; }
  echo "✓ codex installed"
fi
```

Warp is optional — Step 5 already has a graceful fallback if the URL scheme fails.

All checks pass → proceed to Step 1.

## Step 1: Find the Plan

If an argument was provided (e.g. `/dispatch-to-codex docs/superpowers/plans/2026-05-07-auth.md`), use that path.

Otherwise find the most recently modified plan:

```bash
ls -t docs/superpowers/plans/*.md 2>/dev/null | head -1
```

Read the full plan file. If no plan found, tell the user to run `writing-plans` first.

## Step 2: Extract Header Fields

Parse these from the plan header (always present in `writing-plans` output):

- `**Goal:**` — one sentence
- `**Architecture:**` — 2-3 sentences
- `**Tech Stack:**` — key technologies

## Step 3: Detect Project Context

From the current working directory:

- **Test command:** `package.json` scripts (`test`, `vitest`, `jest`); or `pytest`/`cargo test`/`go test` based on stack
- **Lint command:** `package.json` `lint` script; or presence of `biome.json`, `.eslintrc`, `ruff.toml`
- **Repo name:** `basename $(git rev-parse --show-toplevel)`
- **Absolute plan path:** `realpath <plan-file>`

## Step 4: Build the Self-Contained Brief

Write to `/tmp/codex-dispatch.txt`. The brief must contain the FULL execution protocol so Codex has zero ambiguity:

```
You are implementing a plan dispatched from Claude Code. Follow this protocol exactly.

## Plan
File: <absolute-plan-path>

## Project context
Repo: <repo-name>
Working directory: <absolute-cwd>
Test command: <test-cmd>
Lint command: <lint-cmd>

## Plan summary
Goal: <goal>
Architecture: <architecture>
Tech Stack: <tech-stack>

## Execution Protocol

### 1. Read the full plan
Read the plan file completely before doing anything. Understand all tasks and the file structure.

### 2. Create a worktree
Derive the branch name from the plan filename:
- Strip the YYYY-MM-DD- date prefix and the .md suffix
- Prefix with feat/
- Example: 2026-05-07-auth-refresh.md → feat/auth-refresh

Then:
  REPO=$(basename $(git rev-parse --show-toplevel))
  BRANCH=feat/<derived-name>
  git worktree add ../${REPO}-<derived-name> ${BRANCH}
  cd ../${REPO}-<derived-name>

All edits, tests, and commits happen inside the worktree.

### 3. Execute task-by-task (TDD)
For each task in the plan:
  1. Write the failing test exactly as specified
  2. Run the test — verify it fails with the expected error
  3. Write minimal implementation to make it pass
  4. Run the test — verify it passes
  5. Commit with a descriptive message
  6. Mark the task complete (- [x]) in the plan file

Follow plan steps exactly. Do not skip verifications.

### 4. Stop rules
Stop immediately and report when:
- A test fails repeatedly and the plan does not explain why
- A file path in the plan does not exist and you cannot infer the correct one
- A dependency is missing and not mentioned in the plan
- Any instruction is ambiguous

Report: which step, what error, what you tried. Do not guess through blockers.

### 5. Done
After the last task commit, announce: "Implementation complete. Worktree at ../<repo>-<branch-slug>. Review the diff, then run /commit-push-pr in Claude Code."

Do not push. Do not open PRs.
```

## Step 5: Launch Warp

```bash
ENCODED_CMD=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))" <<< 'codex "$(cat /tmp/codex-dispatch.txt)"')
open "warp://action/new_tab?command=${ENCODED_CMD}"
```

If the Warp URL scheme fails, print the manual fallback:

```
Run in a new terminal:
  codex "$(cat /tmp/codex-dispatch.txt)"
```

## Step 6: Confirm

Announce: "Codex dispatched to Warp. Switch to the new tab to monitor. When Codex stops, review the diff in the worktree at `../<repo-name>-<branch-slug>` then run `/commit-push-pr`."

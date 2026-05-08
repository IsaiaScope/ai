---
name: iso-codex-implementation
description: Implement a plan handed off from Claude Code via iso-dispatch-to-codex. Use when receiving a brief with `plan_path` and `state_path` parameters. Owns the TDD execution protocol, worktree creation, stop rules, and state writeback. Does not commit — user reviews and commits manually.
---

# iso-codex-implementation

Execute a Claude-Code-dispatched plan inside a fresh git worktree using TDD per task. Do **not** commit. Write state transitions back to the per-run JSON state file. Stamp the plan file as done. After the final task, print a summary and stay in the REPL so the user can ask for refinements inline.

## Inputs (parsed from brief)

The dispatching brief provides these parameters as `KEY: VALUE` lines:

- `plan_path` — absolute path to the plan markdown file
- `state_path` — absolute path to the run state JSON file (`<repo>/.iso/runs/<run-id>.json`)
- `repo` — repo basename (used for worktree directory naming)
- `worktree_base` — absolute parent directory for the worktree (default: parent of repo)
- `test_cmd` — command to run a single test, e.g. `pytest -xvs` or `npm test --`
- `lint_cmd` — command to run linter, e.g. `npm run lint` or `ruff check`

If any required input is missing, halt and print: `iso-codex-implementation: missing input <KEY>`.

## Pre-flight

```bash
command -v git &>/dev/null    || { echo "✗ git not found"; exit 1; }
command -v python3 &>/dev/null || { echo "✗ python3 not found"; exit 1; }
[ -f "$plan_path" ]            || { echo "✗ plan not found: $plan_path"; exit 1; }
[ -f "$state_path" ]           || { echo "✗ state not found: $state_path"; exit 1; }
```

## Step 1: Read the full plan

Read `<plan_path>` end-to-end before any action. Understand all tasks, file structure, and architectural decisions.

## Step 2: Derive branch and worktree

Parse the plan filename: `YYYY-MM-DD-<type>-<slug>.md`.

- Strip the date prefix (`YYYY-MM-DD-`).
- Extract `<type>` from the next token; must be one of `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`. If unknown, halt with: `iso-codex-implementation: unknown type prefix in plan filename`.
- The remainder is `<slug>`. Empty slug → halt: `iso-codex-implementation: empty slug after type prefix`.
- Branch: `<type>/<slug>`
- Worktree path: `<worktree_base>/<repo>-<slug>`

If `<type>` field is missing entirely (e.g. `2026-05-08-something.md`), default `<type>=feat`, `<slug>=something`.

## Step 3: Check collisions and create worktree

```bash
if git rev-parse --verify "$branch" &>/dev/null; then
  echo "✗ branch $branch already exists. Delete it or rename the plan."
  exit 1
fi
if [ -d "$worktree_path" ]; then
  echo "✗ worktree $worktree_path already exists. Remove it or rename the plan."
  exit 1
fi
git worktree add "$worktree_path" -b "$branch"
cd "$worktree_path"
```

All edits, tests, and state mutations now happen inside the worktree.

## Step 4: Execute task-by-task (TDD, no commits)

For each task in the plan, in order:

1. If the task specifies a failing test, write the test exactly as written in the plan.
2. If a test was written, run it via `<test_cmd>`. Verify it fails with the expected error.
3. Write the minimal implementation specified in the plan.
4. If a test was written, run it again. Verify it passes.
5. Tick the task's checkbox in the plan file: replace `- [ ]` with `- [x]` for the lines belonging to that task. Do this in the original `<plan_path>`, not a copy.
6. **Do NOT commit.** All changes accumulate in the working tree.

Tasks that do not specify a test (config edits, doc tweaks, build-system changes per the plan author's choice) are implemented directly in step 3, without steps 1-2-4.

Follow the plan's task ordering exactly. Do not skip verifications when tests are specified.

## Step 5: Stop rules

Halt immediately if any of these occur:

- A test fails repeatedly (>3 attempts) and the plan does not document the expected failure mode.
- A file path mentioned in the plan does not exist and cannot be unambiguously inferred.
- A dependency referenced in the plan is missing from the project and not listed as something to install.
- Any plan instruction is ambiguous or self-contradictory.

On halt:

1. Write `BLOCKED.md` at the worktree root containing:
   - Failed task number and title
   - The exact error or ambiguity encountered
   - What you tried before halting
   - Suggested next action for the human
2. Mutate the state file via inline python3:

```bash
python3 - <<EOF
import json, datetime
p = "$state_path"
d = json.load(open(p))
now = datetime.datetime.utcnow().isoformat() + "Z"
d["stage"] = "aborted"
d["stages"].setdefault("dispatched", {})["completed"] = now
d["updated_at"] = now
json.dump(d, open(p, "w"), indent=2)
EOF
```

3. Print: `Halted at task <N>. See BLOCKED.md in worktree. State file: <state_path>.`
4. Stay in REPL — wait for user input. Do not exit.

## Step 6: Finalize on success

After the last task's checkbox is ticked:

1. Mutate state file: stage → `done`, write `dispatched.completed`:

```bash
python3 - <<EOF
import json, datetime
p = "$state_path"
d = json.load(open(p))
now = datetime.datetime.utcnow().isoformat() + "Z"
d["stage"] = "done"
d["stages"].setdefault("dispatched", {})["completed"] = now
d["updated_at"] = now
json.dump(d, open(p, "w"), indent=2)
EOF
```

2. Stamp the plan file. Insert this line into the header block immediately after the `**Goal:**` line:

```
**Status:** done @ <iso-timestamp>
```

3. Append the implementation log footer to the plan file:

```
## Implementation Log
- Dispatched: <dispatched.started ISO timestamp from state>
- Codex done: <ISO timestamp now>
- Worktree: <absolute worktree path>
- Branch: <branch>
```

Use python3 to do these edits in-place rather than shell heredocs, to avoid quoting hazards:

```bash
python3 - <<'EOF'
import re, datetime, json, sys
plan_path = "$plan_path"
state_path = "$state_path"
state = json.load(open(state_path))
now = datetime.datetime.utcnow().isoformat() + "Z"
dispatched_started = state["stages"]["dispatched"]["started"]
worktree = "$worktree_path"
branch = "$branch"

content = open(plan_path).read()

status_line = f"**Status:** done @ {now}\n"
content = re.sub(r"(\*\*Goal:\*\*[^\n]*\n)", r"\1" + status_line, content, count=1)

footer = (
    "\n## Implementation Log\n"
    f"- Dispatched: {dispatched_started}\n"
    f"- Codex done: {now}\n"
    f"- Worktree: {worktree}\n"
    f"- Branch: {branch}\n"
)
content = content.rstrip() + "\n" + footer

open(plan_path, "w").write(content)
EOF
```

## Step 7: Print summary and stay open

Print:

```
✓ Implementation complete.
  Tasks: <N> done
  Files changed:
<output of `git diff --stat`>
  Worktree: <worktree_path>
  Branch:   <branch>
  Plan:     <plan_path> (stamped done)
  State:    <state_path>

REPL stays open. Ask for refinements as needed. The user will commit manually.
```

Then halt all autonomous action. Wait for user input. Do **not** announce session-complete. Do **not** exit. Treat further user messages as in-worktree refinement requests.

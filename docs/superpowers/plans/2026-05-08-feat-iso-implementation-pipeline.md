# iso-implementation Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the existing `dispatch-to-codex` skill into a three-skill pipeline (`iso-implementation` orchestrator on Claude side, `iso-dispatch-to-codex` thin brief builder on Claude side, `iso-codex-implementation` protocol-owning skill on Codex side) with stateful per-run tracking under `.iso/runs/`, enforced planning chain (`brainstorming → grill-with-docs → writing-plans`), and non-committing TDD execution.

**Architecture:** Stateful orchestrator skill writes per-run JSON state files at `.iso/runs/<YYYY-MM-DD-slug>.json`, auto-advances through planning sub-stages by chaining mattpocock skills via the Skill tool, then auto-dispatches to Codex via the existing Warp URL scheme. Codex side gains a dedicated skill that owns the TDD + worktree + state writeback protocol so the brief shrinks from ~80 lines to ~10 lines of parameters. Codex executes TDD without committing so the user reviews the entire diff before deciding commit cadence.

**Tech Stack:** Bash (skill scripts), Python 3 (inline JSON state mutation, URL encoding), Node.js (existing `scripts/install.js`), Codex CLI, Warp terminal URL scheme, Claude Code Skill tool, git worktrees.

---

## File Structure

**New files:**
- `skills/iso-implementation/SKILL.md` — Claude-side orchestrator skill with full pipeline state machine
- `skills/iso-dispatch-to-codex/SKILL.md` — Claude-side thin brief builder (renamed from `dispatch-to-codex`)
- `skills/iso-codex-implementation/SKILL.md` — Codex-side protocol skill (TDD, worktree, state writeback)

**Modified files:**
- `.claude-plugin/plugin.json` — register new skills, retire old `dispatch-to-codex` entry
- `CLAUDE.md` — update Architecture section to reflect new skill set
- `config/AGENTS.md` — no change (Q26 decision)

**Deleted files:**
- `skills/dispatch-to-codex/SKILL.md` — replaced by `iso-dispatch-to-codex/SKILL.md`
- `skills/dispatch-to-codex/` — directory removed entirely

**Runtime files (created by skills, not in repo):**
- `<consumer-repo>/.iso/runs/<run-id>.json` — per-run state file
- `<consumer-repo>/.gitignore` — auto-amended to ignore `.iso/`
- `<worktree>/BLOCKED.md` — written only on stop-rule abort

---

## Task 1: Create skills/iso-codex-implementation/SKILL.md (Codex-side protocol)

**Files:**
- Create: `skills/iso-codex-implementation/SKILL.md`

This skill is the protocol owner. It runs inside Codex when `iso-dispatch-to-codex` hands off a brief. Self-contained — no external skill references. Writes its own state transitions back to the state file via inline python3.

- [ ] **Step 1: Create the skill file with full frontmatter and protocol body**

Write the complete file contents:

````markdown
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
````

- [ ] **Step 2: Verify file exists and frontmatter is valid**

Run:
```bash
head -5 skills/iso-codex-implementation/SKILL.md
```
Expected: shows `---`, `name: iso-codex-implementation`, `description: ...`, `---`, blank line.

- [ ] **Step 3: Commit**

```bash
git add skills/iso-codex-implementation/SKILL.md
git commit -m "feat: add iso-codex-implementation skill (Codex-side TDD protocol)"
```

---

## Task 2: Create skills/iso-dispatch-to-codex/SKILL.md (Claude-side thin brief)

**Files:**
- Create: `skills/iso-dispatch-to-codex/SKILL.md`

Replaces the existing `dispatch-to-codex` skill with a thin builder. Brief shrinks to parameter passthrough; protocol lives in `iso-codex-implementation`.

- [ ] **Step 1: Write the new skill file**

Write the complete contents:

````markdown
---
name: iso-dispatch-to-codex
description: Dispatch a plan to Codex CLI in a new Warp tab. Builds a thin brief (parameters only) that triggers the iso-codex-implementation skill on the Codex side. Creates or updates the per-run state file at .iso/runs/. Use immediately after writing-plans completes, or invoke directly with a plan path to skip planning.
---

# iso-dispatch-to-codex

Hand off an implementation plan to Codex CLI. Builds a parameter-only brief written to `/tmp/codex-dispatch.txt`, then opens a new Warp terminal tab running `codex "$(cat /tmp/codex-dispatch.txt)"`. The Codex side activates `iso-codex-implementation`, which owns the protocol.

## Pre-flight

### python3 (URL encoding + state mutation)

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
    || { echo "✗ codex install failed. Run: npm install -g @openai/codex"; exit 1; }
  echo "✓ codex installed"
fi
```

Warp is optional — Step 6 has a fallback for the URL scheme.

## Step 1: Find the plan

If an argument was provided (e.g. `/iso-dispatch-to-codex docs/superpowers/plans/2026-05-08-feat-auth.md`), use that path.

Otherwise pick the newest:

```bash
ls -t docs/superpowers/plans/*.md 2>/dev/null | head -1
```

If no plan found, tell the user to run `writing-plans` first or pass a path.

Read the full plan into memory.

## Step 2: Derive run identifier

Parse the plan filename: `YYYY-MM-DD-<rest>.md`. The run ID is the filename minus `.md` extension.

If a state file already exists for this run ID at `.iso/runs/<run-id>.json` and its `stage` is non-terminal (`!=` `done`/`aborted`), do not overwrite — pick up that state and continue.

If no state file exists, create one (Step 3).

If a terminal state file exists, append `-2` (or next free `-N`) to the run ID and create a fresh state file.

## Step 3: Ensure state file + .iso/ gitignored

```bash
mkdir -p .iso/runs
state_path=".iso/runs/${run_id}.json"
state_path_abs="$(realpath "$state_path")"
```

If `.iso/` is not in `.gitignore`, append it:

```bash
if ! grep -qxF '.iso/' .gitignore 2>/dev/null; then
  echo '.iso/' >> .gitignore
fi
```

If state file does not exist, create with python3:

```bash
python3 - <<EOF
import json, datetime, os
now = datetime.datetime.utcnow().isoformat() + "Z"
state = {
  "id": "$run_id",
  "plan_path": "$plan_path_abs",
  "stage": "dispatched",
  "branch": None,
  "worktree": None,
  "created_at": now,
  "updated_at": now,
  "stages": {
    "dispatched": {"started": now, "completed": None}
  }
}
os.makedirs(os.path.dirname("$state_path"), exist_ok=True)
json.dump(state, open("$state_path", "w"), indent=2)
EOF
```

If state file exists but stage is `awaiting-dispatch`, mutate to `dispatched`:

```bash
python3 - <<EOF
import json, datetime
p = "$state_path"
d = json.load(open(p))
now = datetime.datetime.utcnow().isoformat() + "Z"
d["stage"] = "dispatched"
d["updated_at"] = now
d["stages"].setdefault("dispatched", {"started": now, "completed": None})
json.dump(d, open(p, "w"), indent=2)
EOF
```

## Step 4: Detect project context

From the current working directory:

- **Test command:** `package.json` scripts (`test`, `vitest`, `jest`); or `pytest`/`cargo test`/`go test` based on stack
- **Lint command:** `package.json` `lint` script; or `biome lint`/`ruff check`/`eslint`
- **Repo basename:** `basename $(git rev-parse --show-toplevel)`
- **Worktree base:** `dirname $(git rev-parse --show-toplevel)` (parent of repo)
- **Plan path absolute:** `realpath <plan-file>`

## Step 5: Build the thin brief

Write to `/tmp/codex-dispatch.txt`:

```
You have been dispatched a plan from Claude Code via iso-dispatch-to-codex.

Use the iso-codex-implementation skill.

plan_path: <plan_path_abs>
state_path: <state_path_abs>
repo: <repo>
worktree_base: <worktree_base>
test_cmd: <test_cmd>
lint_cmd: <lint_cmd>

Begin now. Do not commit. Stay in REPL after completion.
```

That is the entire brief. The protocol body lives in `iso-codex-implementation`.

## Step 6: Launch Warp

```bash
ENCODED_CMD=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))" <<< 'codex "$(cat /tmp/codex-dispatch.txt)"')
open "warp://action/new_tab?command=${ENCODED_CMD}"
```

If the Warp URL scheme fails, print the manual fallback:

```
Run in a new terminal:
  codex "$(cat /tmp/codex-dispatch.txt)"
```

## Step 7: Confirm

Print:

```
✓ Codex dispatched.
  Run:       <run_id>
  Plan:      <plan_path>
  State:     <state_path>
  Worktree:  <worktree_base>/<repo>-<slug>  (will be created by Codex)

Switch to the new Warp tab to monitor. The REPL stays open after Codex finishes — ask for refinements there. Commit manually when ready.
```
````

- [ ] **Step 2: Verify**

Run:
```bash
head -5 skills/iso-dispatch-to-codex/SKILL.md
```
Expected: shows `---`, `name: iso-dispatch-to-codex`, `description: ...`, `---`, blank line.

- [ ] **Step 3: Commit**

```bash
git add skills/iso-dispatch-to-codex/SKILL.md
git commit -m "feat: add iso-dispatch-to-codex skill (thin brief builder)"
```

---

## Task 3: Create skills/iso-implementation/SKILL.md (Claude-side orchestrator)

**Files:**
- Create: `skills/iso-implementation/SKILL.md`

The orchestrator. Owns the planning chain and auto-dispatch to `iso-dispatch-to-codex`. Implements stage/sub-stage tracking against `.iso/runs/<id>.json`.

- [ ] **Step 1: Write the orchestrator skill file**

Write the complete contents:

````markdown
---
name: iso-implementation
description: Full implementation pipeline. Chains brainstorming → grill-with-docs → writing-plans → iso-dispatch-to-codex. Writes per-run state to .iso/runs/. Use when the user runs /iso-implementation, with or without a plan path. No-arg starts the planning chain; plan-path skips planning and dispatches directly. Resumes an in-flight run automatically.
---

# iso-implementation

Stateful pipeline orchestrator for taking an idea from concept to a Codex-implemented worktree. State lives in `.iso/runs/<YYYY-MM-DD-slug>.json` per run.

## Stages

```
planning.brainstorming → planning.grilling → planning.writing
  → awaiting-dispatch → dispatched → done
                                        ↓ (terminal)
                                        OR
                                        aborted (terminal)
```

Within `planning`, sub-stages are tracked under `stages.planning.substages.{brainstorming,grilling,writing}`.

## State schema

```json
{
  "id": "2026-05-08-feat-auth-refresh",
  "plan_path": "<abs path or null while pre-writing-plans>",
  "stage": "planning|awaiting-dispatch|dispatched|done|aborted",
  "branch": "<set by codex>",
  "worktree": "<set by codex>",
  "created_at": "<ISO ts>",
  "updated_at": "<ISO ts>",
  "stages": {
    "planning": {
      "started": "<ts>",
      "completed": "<ts or null>",
      "substages": {
        "brainstorming": {"started": "...", "completed": "..."},
        "grilling":      {"started": "...", "completed": "..."},
        "writing":       {"started": "...", "completed": "..."}
      }
    },
    "dispatched": {"started": "...", "completed": "..."}
  }
}
```

## Pre-flight

```bash
command -v git &>/dev/null    || { echo "✗ not in a git repo"; exit 1; }
command -v python3 &>/dev/null || { echo "✗ python3 required"; exit 1; }
git rev-parse --git-dir &>/dev/null || { echo "✗ not in a git repo"; exit 1; }
```

## Step 1: Resolve active run

Determine which run state file to operate on:

1. If a `<plan-path>` argument was provided:
   - Compute `run_id` from the plan filename (minus `.md`).
   - If `.iso/runs/<run_id>.json` exists: that is the active run.
   - Else: create a new state file (Step 4) with stage `awaiting-dispatch` (planning skipped — plan already written).

2. If no argument:
   - List `.iso/runs/*.json`. Filter to non-terminal stages (`!=` `done`/`aborted`).
   - If `cwd` is inside a worktree referenced by any non-terminal run's `worktree` field, that is the active run.
   - Else: pick the newest non-terminal by `created_at`.
   - If none non-terminal exist: start a new run (Step 4) with stage `planning`.

## Step 2: Print status block

Always print before acting:

```
Run: <run_id>
Stage: <stage>[.<substage>]
Plan: <plan_path or "(not yet written)">
Worktree: <worktree or "(not yet created)">
Branch: <branch or "(not yet derived)">
Started: <created_at>
```

If stage is `done` or `aborted`, stop here. Append:

```
This run is terminal. Start a new run by running:
  /iso-implementation <new-plan-path>     (skips planning)
  /iso-implementation                     (starts planning chain on a fresh idea)
```

## Step 3: Ensure .iso/ gitignored

```bash
mkdir -p .iso/runs
if ! grep -qxF '.iso/' .gitignore 2>/dev/null; then
  echo '.iso/' >> .gitignore
fi
```

## Step 4: Create new state file (only if Step 1 determined "new run")

Generate run ID. If creating with a plan-path argument, use the plan filename minus `.md`. Otherwise, the run ID will be set later (when `writing-plans` produces a plan) — for now, use a temporary ID `pending-<ISO-ts-no-colons>`.

```bash
python3 - <<EOF
import json, datetime, os, sys
now = datetime.datetime.utcnow().isoformat() + "Z"
state = {
  "id": "$run_id",
  "plan_path": "$plan_path_or_null",
  "stage": "$initial_stage",
  "branch": None,
  "worktree": None,
  "created_at": now,
  "updated_at": now,
  "stages": {}
}
if "$initial_stage" == "planning":
  state["stages"]["planning"] = {
    "started": now,
    "completed": None,
    "substages": {
      "brainstorming": {"started": None, "completed": None},
      "grilling":      {"started": None, "completed": None},
      "writing":       {"started": None, "completed": None}
    }
  }
elif "$initial_stage" == "awaiting-dispatch":
  state["stages"]["planning"] = {"started": now, "completed": now, "substages": {}}
os.makedirs(".iso/runs", exist_ok=True)
json.dump(state, open(".iso/runs/$run_id.json", "w"), indent=2)
EOF
```

## Step 5: Advance based on current stage

State machine driver. Every invocation runs Step 5 after Step 2.

### Stage `planning`

Find the first incomplete substage in order: `brainstorming`, `grilling`, `writing`.

For the first incomplete substage:

- If `started` is null: mutate state to set `started=now`. Then invoke the corresponding skill via the Skill tool:
  - `brainstorming` → `superpowers:brainstorming`
  - `grilling` → `grill-with-docs`
  - `writing` → `superpowers:writing-plans`
- When the Skill tool returns, mark the substage `completed=now`.
- Advance to the next substage in the same orchestrator turn (recurse to Step 5).
- After `writing` completes:
  - Discover the new plan: `ls -t docs/superpowers/plans/*.md | head -1`. Parse run ID from filename. If the orchestrator's run ID is `pending-...`, rename the state file to `<new-run-id>.json` and update `state.id` and `state.plan_path` to the discovered plan.
  - Mark `stages.planning.completed=now`.
  - Set `stage=awaiting-dispatch`. Recurse to Step 5.

### Stage `awaiting-dispatch`

Auto-advance: invoke `iso-dispatch-to-codex` via the Skill tool, passing the plan path as argument. `iso-dispatch-to-codex` updates the state file to `dispatched` itself.

### Stage `dispatched`

Print: `Codex is working in a new Warp tab. State will advance to "done" when Codex finalizes. Re-invoke /iso-implementation any time to refresh status.`
Halt — do not advance. Codex side writes the next transition.

### Stage `done` or `aborted`

Already handled in Step 2 (terminal print + halt).

## Step 6: Mutate state on every transition

Every time you change `stage`, `stages.X.started`, `stages.X.completed`, or rename the file, write `updated_at = now`. Use python3 inline:

```bash
python3 - <<EOF
import json, datetime
p = "$state_path"
d = json.load(open(p))
d["updated_at"] = datetime.datetime.utcnow().isoformat() + "Z"
# ... other mutations ...
json.dump(d, open(p, "w"), indent=2)
EOF
```

## Notes on multi-run

Multiple non-terminal runs are allowed when they target distinct slugs (and therefore distinct worktrees). The cwd-aware lookup in Step 1 ensures the user lands on the run matching their current worktree.
````

- [ ] **Step 2: Verify**

Run:
```bash
head -5 skills/iso-implementation/SKILL.md
```
Expected: shows `---`, `name: iso-implementation`, `description: ...`, `---`, blank line.

- [ ] **Step 3: Commit**

```bash
git add skills/iso-implementation/SKILL.md
git commit -m "feat: add iso-implementation orchestrator skill"
```

---

## Task 4: Update .claude-plugin/plugin.json (register new skills, retire old)

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Write the new plugin.json**

Replace the entire file with:

```json
{
  "name": "isaiascope-ai",
  "skills": [
    "./skills/iso-ai-init",
    "./skills/iso-init-repo",
    "./skills/iso-implementation",
    "./skills/iso-dispatch-to-codex",
    "./skills/iso-codex-implementation"
  ]
}
```

- [ ] **Step 2: Verify JSON is valid**

Run:
```bash
python3 -c "import json; json.load(open('.claude-plugin/plugin.json'))"
```
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat: register iso-implementation, iso-dispatch-to-codex, iso-codex-implementation in plugin.json"
```

---

## Task 5: Delete old dispatch-to-codex skill

**Files:**
- Delete: `skills/dispatch-to-codex/`

- [ ] **Step 1: Remove the directory**

```bash
git rm -r skills/dispatch-to-codex
```
Expected: `rm 'skills/dispatch-to-codex/SKILL.md'`.

- [ ] **Step 2: Verify directory is gone**

```bash
test ! -d skills/dispatch-to-codex && echo "removed"
```
Expected output: `removed`.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor: remove dispatch-to-codex (superseded by iso-dispatch-to-codex)"
```

---

## Task 6: Update CLAUDE.md architecture section

**Files:**
- Modify: `CLAUDE.md`

The Architecture block currently lists `skills/iso-ai-init/SKILL.md` only. Update it to reflect the new skill set without restructuring the rest of the file.

- [ ] **Step 1: Read the current CLAUDE.md**

```bash
cat CLAUDE.md
```

- [ ] **Step 2: Replace the Architecture block**

Find the existing Architecture section (begins with `## Architecture` and the code fence below it). Replace the code fence block (the directory tree) with:

```
config/
  CLAUDE.md   — global Claude Code instructions (copied to ~/CLAUDE.md on install)
  AGENTS.md   — global Codex instructions (copied to ~/.codex/AGENTS.md on install)
skills/
  iso-ai-init/SKILL.md             — initialize a repo with IsaiaScope AI defaults
  iso-init-repo/SKILL.md           — initialize repo governance (branches, CI, hooks)
  iso-implementation/SKILL.md      — Claude-side pipeline orchestrator
  iso-dispatch-to-codex/SKILL.md   — Claude-side thin brief builder for Codex handoff
  iso-codex-implementation/SKILL.md — Codex-side TDD execution protocol
scripts/
  install.js                        — deploys config files + installs skill packs globally
.claude-plugin/
  plugin.json                       — registers this repo as a skills.sh plugin
```

Use the Edit tool to perform the replacement. The `old_string` should be the full existing code fence including the triple backticks; the `new_string` should be the full new code fence.

- [ ] **Step 3: Verify**

```bash
grep -A 2 "iso-implementation/SKILL.md" CLAUDE.md
```
Expected: shows the new line.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md architecture for iso-implementation pipeline"
```

---

## Task 7: Run install.js to deploy skills locally

**Files:**
- Modify: none (deploy step only)

This task confirms that the existing `scripts/install.js` deploys the new skills to `~/.codex/skills/` (for `iso-codex-implementation`) and to `~/.claude/plugins/` or equivalent (for `iso-implementation`, `iso-dispatch-to-codex`) without code changes.

- [ ] **Step 1: Run the installer**

```bash
node scripts/install.js
```
Expected: outputs `✓ config/CLAUDE.md → ...`, `✓ config/AGENTS.md → ...`, then five `→ Installing <pack>` blocks, then `✓ Done.`

- [ ] **Step 2: Verify codex skill landed**

```bash
test -f ~/.codex/skills/iso-codex-implementation/SKILL.md && echo "codex skill installed"
```
Expected output: `codex skill installed`.

If the file is not present, the `IsaiaScope/ai` pack on skills.sh is stale (cached). Force a refresh:

```bash
npx skills@latest update -g -y --agent codex
test -f ~/.codex/skills/iso-codex-implementation/SKILL.md && echo "codex skill installed"
```

- [ ] **Step 3: Verify Claude skills landed**

```bash
ls ~/.claude/plugins/cache/ 2>/dev/null | grep -i isaiascope || echo "(check Claude skill install path on this system)"
```
Expected: shows the IsaiaScope pack cached. If path differs on your system, list `~/.claude/plugins/` to locate.

- [ ] **Step 4: No commit**

This task does not produce file changes inside the repo. Skip the commit step.

---

## Task 8: Smoke-test the pipeline end-to-end (manual)

**Files:**
- Modify: none (manual verification)

Run a tiny dummy plan through the full pipeline to confirm wiring. This task is manual and observational — it does not produce repo changes.

- [ ] **Step 1: Create a throwaway plan in a scratch repo**

Create a temporary repo for testing:

```bash
cd /tmp
mkdir iso-pipeline-smoke && cd iso-pipeline-smoke
git init
mkdir -p docs/superpowers/plans
cat > docs/superpowers/plans/2026-05-08-feat-smoke.md <<'EOF'
# Smoke Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Verify iso-implementation pipeline wiring.

**Architecture:** Single-file echo.

**Tech Stack:** Bash.

---

### Task 1: Create hello.sh

**Files:**
- Create: `hello.sh`

- [ ] **Step 1: Implement**

Write `hello.sh`:

```
#!/bin/bash
echo hello
```

- [ ] **Step 2: Verify**

```bash
bash hello.sh
```
Expected: `hello`
EOF
git add . && git commit -m "init smoke test plan"
```

- [ ] **Step 2: Run the orchestrator with the plan path**

In Claude Code:

```
/iso-implementation /tmp/iso-pipeline-smoke/docs/superpowers/plans/2026-05-08-feat-smoke.md
```

Expected behavior:
1. Status block prints (stage = `awaiting-dispatch`).
2. `iso-dispatch-to-codex` is invoked automatically.
3. State file created at `/tmp/iso-pipeline-smoke/.iso/runs/2026-05-08-feat-smoke.json`.
4. `.gitignore` updated to include `.iso/`.
5. Warp opens a new tab running Codex with the brief.

- [ ] **Step 3: Watch Codex tab**

Expected behavior in Codex:
1. `iso-codex-implementation` skill activates from the brief.
2. Worktree created at `/tmp/iso-pipeline-smoke-smoke` on branch `feat/smoke`.
3. `hello.sh` written.
4. Plan task ticked.
5. State file mutated to `stage=done`.
6. Plan file gets `**Status:** done @ ...` after the Goal line and an Implementation Log footer.
7. Summary printed; REPL stays open.

- [ ] **Step 4: Verify state and plan**

```bash
cat /tmp/iso-pipeline-smoke/.iso/runs/2026-05-08-feat-smoke.json
grep "Status:" /tmp/iso-pipeline-smoke/docs/superpowers/plans/2026-05-08-feat-smoke.md
grep "Implementation Log" /tmp/iso-pipeline-smoke/docs/superpowers/plans/2026-05-08-feat-smoke.md
```
Expected: state stage is `done`; plan has Status line and Implementation Log footer.

- [ ] **Step 5: Cleanup smoke fixtures**

```bash
git -C /tmp/iso-pipeline-smoke worktree remove ../iso-pipeline-smoke-smoke 2>/dev/null
rm -rf /tmp/iso-pipeline-smoke /tmp/iso-pipeline-smoke-smoke
```

- [ ] **Step 6: No commit**

Smoke test produces no repo changes. Skip commit.

---

## Self-Review Checklist (run after final task)

1. **Spec coverage:** Every grilling decision (Q2-Q44) maps to a task or design choice in this plan.
2. **Placeholder scan:** No `TBD`, no `// implement later`, no `add appropriate error handling` without specifics.
3. **Type consistency:** Skill names (`iso-implementation`, `iso-dispatch-to-codex`, `iso-codex-implementation`), state keys (`stage`, `stages`, `substages`), stage values (`planning`, `awaiting-dispatch`, `dispatched`, `done`, `aborted`), and file paths (`.iso/runs/<id>.json`, `docs/superpowers/plans/`) are used consistently across all tasks.

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

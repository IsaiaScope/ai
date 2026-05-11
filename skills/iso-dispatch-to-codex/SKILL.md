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

## Step 6: Launch Warp (automatic via osascript keystrokes)

Drive Warp via `osascript`: copy the codex command to the clipboard, activate Warp, open a new tab (Cmd-T), paste (Cmd-V), and press Enter. Fully automatic — no manual paste.

**Requires Accessibility permission** for `/usr/bin/osascript` (System Settings → Privacy & Security → Accessibility → add `/usr/bin/osascript`, toggle on). Without it, `System Events` keystrokes fail with error 1002.

```bash
printf 'codex --dangerously-bypass-approvals-and-sandbox "$(cat /tmp/codex-dispatch.txt)"' | pbcopy

osascript <<'AS' 2>/tmp/iso-dispatch-osa.err
tell application "Warp" to activate
delay 0.5
tell application "System Events"
  keystroke "t" using command down
  delay 0.6
  keystroke "v" using command down
  delay 0.2
  key code 36
end tell
AS
osa_status=$?
```

If `osa_status` is non-zero (Accessibility not granted, Warp not installed, or other error), print the manual fallback and the error:

```
⚠ osascript failed (see /tmp/iso-dispatch-osa.err). Falling back to manual paste.
✓ Codex command on clipboard. In Warp: Cmd-T (new tab) → Cmd-V (paste) → Enter.
  Brief at: /tmp/codex-dispatch.txt
```

On success, print:

```
✓ Codex dispatched to a new Warp tab automatically.
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

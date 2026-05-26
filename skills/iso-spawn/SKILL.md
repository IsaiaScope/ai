---
name: iso-spawn
description: Spawn a codex or claude agent in its own herdr tab inside the SAME workspace where the skill runs, with full permissions and an optional auto-running prompt. Use when the user wants to spawn/open/launch a codex or claude tab/agent/panel in the current herdr workspace, dispatch a task to a sub-agent beside the current session, or says "spawn codex", "open a claude tab", "/iso-spawn", "launch an agent here".
---

# iso-spawn

Launches a `codex` or `claude` agent in a fresh herdr tab, in the **current** workspace
(resolved from `$HERDR_PANE_ID`, immune to UI focus). Full permissions by default, optional
prompt injected and auto-run, delivered in the background so the caller never blocks.

## Quick start

```bash
# codex here, full perms, task auto-runs (returns immediately, prompt delivered async)
scripts/spawn.sh codex --prompt "Add a health-check endpoint"

# claude, full perms, no prompt
scripts/spawn.sh claude

# dispatch and BLOCK until it finishes, then report status
scripts/spawn.sh codex --prompt "Run the test suite and fix failures" --wait

# sandboxed (opt out of full permissions); split current tab; jump focus to it
scripts/spawn.sh codex --safe --split right --focus
```

Run with the script's absolute path. When invoked as `/iso-spawn`, map the request to flags:
agent type (codex|claude), the task → `--prompt`, "wait for it" → `--wait`, a repo path → `--cwd`.

## Defaults (the opinionated part)

- **Full permissions ON** — codex `--dangerously-bypass-approvals-and-sandbox`, claude
  `--dangerously-skip-permissions`. Pass `--safe` to disable.
- **cwd = caller's pane cwd** — the agent starts where you are working, not `~`. Override with `--cwd`.
- **Background / no focus** — spawns beside you without stealing focus; the prompt is delivered by a
  detached, **traced** worker (log at `<cwd>/.iso/logs/spawn/<date>__<codex|claude-code>__<name>__<term>.log`).
  Pass `--focus` to jump to it, `--wait` to block until the task completes.
- **One agent per call.** Fan-out = call it again.

## Options

| flag | meaning |
|------|---------|
| `<codex\|claude>` | required first arg |
| `--prompt TEXT` | inject + auto-run as soon as the agent boots (delivered async) |
| `--cwd PATH` | working dir (default: caller's pane cwd) |
| `--label TEXT` | tab label (default: agent type) |
| `--name TEXT` | name base; auto-suffixed (`codex`, `codex-2`, …) if taken |
| `--safe` | disable full permissions |
| `--split right\|down` | split the current tab instead of a new tab |
| `--focus` | switch focus to the new tab (default: stay put) |
| `--wait` | run synchronously: block until the agent finishes (status idle), print status |

## Why it's built this way

1. **Workspace = own pane, not focus.** `pane get $HERDR_PANE_ID` → `workspace_id`. Focus drifts; the
   calling pane's workspace doesn't. Same call yields the default cwd.
2. **Own tab, not a split.** `agent start --tab` splits an existing tab → the script closes the
   leftover root shell so the tab holds only the agent. (`--split` opts into a split instead.)
3. **One poll loop, accept by status OR screen — but only after injecting.** The worker resolves the
   pane once, then each tick: clears a trust modal, injects when the input box is ready, and confirms
   the prompt landed via `status ∈ {working,done,blocked}` *or* the prompt showing as committed on
   screen. The accept-check is gated behind an `injected` flag because claude emits boot-time status
   from MCP/SessionStart hooks that would otherwise look like acceptance. (Earlier `agent wait
   --status working` was abandoned: it times out on a fast `done` agent → double-inject.)
4. **Full perms need auto-mode OFF, not an allowlist.** The auto-mode safety classifier blocks
   `--dangerously-*` spawns regardless of any `settings.local.json` allowlist — turn auto-mode off
   (or use `--safe`). The script prints a note when full perms are on.

## Verify / monitor

```bash
herdr agent list                                    # all agents + status
herdr agent get <term>                              # one agent's status (idle|working|blocked|unknown)
herdr agent wait <term> --status idle --timeout MS  # block on completion
```

See [REFERENCE.md](REFERENCE.md) for the herdr object model, status semantics, and failure modes.

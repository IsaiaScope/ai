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

# spawn + wait + recover the output in one call (deliver verb)
scripts/spawn.sh deliver codex --prompt "Summarise the repo" --kill

# sandboxed (opt out of full permissions); split current tab; jump focus to it
scripts/spawn.sh codex --safe --split right --focus
```

Run with the script's absolute path. When invoked as `/iso-spawn`, map the request to flags:
agent type (codex|claude), the task → `--prompt`, "wait for it" → `--wait`, a repo path → `--cwd`.

## Verb surface

| verb | synopsis | modules used |
|------|----------|-------------|
| `spawn` | launch agent, write sidecar, deliver prompt async or sync (`--wait`) | herdr, transcript, deliver |
| `deliver` | spawn + wait + recover; requires `--prompt`; opt-in `--kill` | deliver (composes spawn + recover) |
| `send` | type text into a live agent's pane (one-shot) | herdr |
| `recover` | read `output\|chat` from the agent's transcript | transcript, recover.py |
| `status` | print `idle\|working\|blocked\|unknown` | herdr |
| `cleanup` | remove a sidecar and/or kill a tab; `--orphaned` reaps stale sidecars | cleanup, herdr |

`spawn.sh <codex|claude> …` is a bare alias for `spawn.sh spawn <codex|claude> …` — kept for
back-compat with docs and callers like `iso-write`.

## Defaults (the opinionated part)

- **Full permissions ON** — codex `--dangerously-bypass-approvals-and-sandbox`, claude
  `--dangerously-skip-permissions`. Pass `--safe` to disable.
- **cwd = caller's pane cwd** — the agent starts where you are working, not `~`. Override with `--cwd`.
- **Background / no focus** — spawns beside you without stealing focus; the prompt is delivered by a
  detached, **traced** worker (sidecar at `<cwd>/.iso/logs/spawn/<date>__<codex|claude-code>__<name>__<term>.spawn`
  — meta + trace).
  Pass `--focus` to jump to it, `--wait` to block until the task completes.
- **One agent per call.** Fan-out = call it again.

## Options

| flag | meaning |
|------|---------|
| `<codex\|claude>` | required first arg of spawn/deliver |
| `--prompt TEXT` | inject + auto-run as soon as the agent boots (delivered async) |
| `--cwd PATH` | working dir (default: caller's pane cwd) |
| `--label TEXT` | tab label (default: agent type) |
| `--name TEXT` | name base; auto-suffixed (`codex`, `codex-2`, …) if taken |
| `--safe` | disable full permissions |
| `--split right\|down` | split the current tab instead of a new tab |
| `--focus` | switch focus to the new tab (default: stay put) |
| `--wait` | run synchronously: block until the agent finishes (status idle), print status |
| `--recover [output\|chat]` | with `--wait`: after the agent goes idle, print its recovered output (default `output`) |
| `--what output\|chat` | (deliver) what to recover; default `output` |
| `--kill` | after the verb's action, close the tab and delete the sidecar (opt-in; not on bare async `spawn`) |

## Recover output

After an agent finishes, pull its work from its native transcript (codex/claude JSONL),
keyed off the `term` printed at spawn:

```bash
# clean final answer
scripts/spawn.sh recover <TERM>

# full transcript for debugging
scripts/spawn.sh recover <TERM> --what chat

# block on a task then print its answer in one call
scripts/spawn.sh codex --prompt "…" --wait --recover

# deliver: spawn + wait + recover + kill the tab
scripts/spawn.sh deliver codex --prompt "…" --kill
```

`recover` reads the `.spawn` sidecar (written at spawn) to map `<TERM>` to the agent's
transcript file. If the transcript can't be mapped it falls back to herdr scrollback
(bounded; may be truncated on long runs), printing a `# source: scrollback` header.

## Interact & clean up

```bash
# send a follow-up message to a running agent
scripts/spawn.sh send <TERM> "Now write the tests"

# check what the agent is doing
scripts/spawn.sh status <TERM>

# remove a stale sidecar without killing the tab
scripts/spawn.sh cleanup <TERM>

# kill the tab AND remove the sidecar
scripts/spawn.sh cleanup <TERM> --kill

# reap all stale sidecars whose agent is gone (and older than grace window)
scripts/spawn.sh cleanup --orphaned
```

## `lib/` layout

`spawn.sh` is a thin dispatcher. Business logic lives in four sourced modules:

| module | responsibility |
|--------|---------------|
| `lib/herdr.sh` | herdr CLI wrappers (pane read/run, agent status, tab close, agent list) |
| `lib/transcript.sh` | JSONL transcript mapping: slug, candidate-set, snapshot-diff, prompt fingerprint, sidecar read/write |
| `lib/deliver.sh` | delivery poll loop (trust modals, prompt inject, acceptance) |
| `lib/cleanup.sh` | orphan detection, sidecar removal, tab kill |

## Why it's built this way

1. **Workspace = own pane, not focus.** `pane get $HERDR_PANE_ID` → `workspace_id`. Focus drifts; the
   calling pane's workspace doesn't. Same call yields the default cwd.
2. **Own tab, not a split.** `agent start --tab` splits an existing tab → the script closes the
   leftover root shell so the tab holds only the agent. (`--split` opts into a split instead.)
3. **One poll loop, accept by status OR screen — but only after injecting.** The worker resolves the
   pane once, then each tick: clears a trust modal, injects when the input box is ready, and confirms
   the prompt landed via `status ∈ {working,done,blocked}` *or* the prompt showing as committed on
   screen. The accept-check is gated behind an `injected` flag because claude emits boot-time status
   from MCP/SessionStart hooks that would otherwise look like acceptance.
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

---
name: iso-spawn
description: Spawn a codex or claude agent in its own herdr tab inside the SAME workspace where the skill runs, with full permissions and an optional auto-running prompt. Use when the user wants to spawn/open/launch a codex or claude tab/agent/panel in the current herdr workspace, dispatch a task to a sub-agent beside the current session, or says "spawn codex", "open a claude tab", "/iso-spawn", "launch an agent here".
---

# iso-spawn

Launches a `codex` or `claude` agent in a fresh herdr tab, in the **current** workspace
(resolved from `$HERDR_PANE_ID`, immune to UI focus). Full permissions by default, optional
prompt injected and auto-run, delivered in the background so the caller never blocks.

**You are the orchestrator.** A spawned agent runs independently in its own pane — it does
**not** call you back when it finishes. iso-spawn gives you the verbs; you own the lifecycle:
launch it, watch it, talk to it, collect its work, tear it down. When this skill is used
*inside another skill*, that parent skill owns the lifecycle and decides when each spawned
agent is killed. Everything below is your control surface.

## Operating a spawned agent

Every agent moves through five phases. Each phase has one verb and answers one question:

| phase | verb(s) | the question you're answering | anchor |
|-------|---------|-------------------------------|--------|
| **1. Launch** | `spawn` / `deliver` | sync or async? full-perm or `--safe`? | prints a **`TERM`** |
| **2. Monitor** | `status`, `herdr agent wait` | is it `working` / `idle` / `blocked`? | `<TERM>` |
| **3. Interact** | `send` | unblock it, course-correct, follow up | `<TERM>` |
| **4. Recover** | `recover` | pull its result (`output` \| `chat`) | `<TERM>` |
| **5. Tear down** | `cleanup` (`--kill`, `--orphaned`) | kill the tab, reap the sidecar, no leaks | `<TERM>` |

The single anchor for phases 2–5 is the **`TERM`** (herdr terminal id) printed at launch.
Capture it. Every other verb takes one `<TERM>`; N agents = N independent `TERM`s.

## Pick your launch shape

There are three launch shapes. Choose by what you want back:

| you want | use | blocks? |
|----------|-----|---------|
| **one task done, result back, tab gone** (the common case) | `deliver … --kill` | yes |
| result back, agent kept alive for follow-ups | `deliver …` (no `--kill`) | yes |
| run many agents in **parallel**, collect later | async `spawn` ×N, then poll | no |
| a long job while you keep working | async `spawn`, poll later | no |

Rule of thumb: **`deliver --kill` for a single task you need the answer to; async `spawn`
for parallelism.** `deliver` is `spawn` + wait + recover (+ optional kill) fused into one
blocking call.

### Capture the handle cleanly

stdout carries the **machine value**, stderr carries the human banner. So both idioms just work:

```bash
# async: stdout is the bare TERM — capture it to track the agent later
term=$(scripts/spawn.sh codex --prompt "Add a health-check endpoint")

# deliver: stdout is the recovered result — capture it directly
result=$(scripts/spawn.sh deliver codex --prompt "Summarise the repo" --kill)
```

```bash
# claude, full perms, no prompt
scripts/spawn.sh claude

# block until it finishes, then report status
scripts/spawn.sh codex --prompt "Run the test suite and fix failures" --wait

# sandboxed (opt out of full perms); split the current tab; jump focus to it
scripts/spawn.sh codex --safe --split right --focus
```

Run with the script's absolute path. When invoked as `/iso-spawn`, map the request to flags:
agent type (codex|claude), the task → `--prompt`, "wait for it" → `--wait`, a repo path → `--cwd`.

## You poll or you block — there is no callback

A spawned agent never notifies you. To learn it finished you either **poll** its status or
**block** on a transition:

```bash
scripts/spawn.sh status "$term"                      # idle | working | blocked | unknown
herdr agent wait "$term" --status idle --timeout MS  # block until it goes idle/done
```

- `working` — running a turn. Keep polling.
- `idle` / `done` — finished, awaiting input. Safe to recover.
- `blocked` — stalled on a permission/approval prompt. **You must act** (see below).
- `unknown` — no hook has fired yet.

Status is not a readiness signal at boot (claude emits `working`/`done` from boot hooks before
any prompt) — trust it only *after* the prompt has been delivered.

### If it stalls (`blocked`)

A `blocked` agent is waiting on a prompt and will sit there forever. Look at what it's asking,
then answer with `send`:

```bash
scripts/spawn.sh recover "$term" --what chat | tail -20   # see what it's asking
scripts/spawn.sh send "$term" "1"                         # approve / answer / redirect
```

Full-permission spawns (the default) rarely block; `--safe` and codex approval gates can.

## Reading the result

Recover only **after** the agent is `idle`. Recovering a `working` agent prints
`warning: … still working` and may return partial output.

```bash
scripts/spawn.sh recover "$term"              # clean final answer (default: output)
scripts/spawn.sh recover "$term" --what chat  # full transcript, for debugging
```

Treat these as "don't trust it yet, re-check `status`":
- an **empty** result (`deliver` also warns `got an empty result`),
- a result headed `# source: scrollback` — the transcript couldn't be mapped, so it fell back
  to herdr scrollback and may be truncated.

## Tear down

The orchestrator owns kill timing. When you (or a parent skill at the end of its task) are done
with an agent:

```bash
scripts/spawn.sh cleanup "$term" --kill   # kill the tab AND remove the sidecar
scripts/spawn.sh cleanup "$term"          # drop the sidecar only; leave the agent running
scripts/spawn.sh cleanup --orphaned       # safety net: reap sidecars whose agent is gone
```

`deliver --kill` self-cleans, so prefer it precisely so you can't forget. Use
`cleanup --orphaned` as the end-of-run safety net (reaps any sidecar whose `TERM` is gone and
older than the grace window).

> **`--kill` is destructive.** It terminates the agent even if it is still `working`, losing
> unsaved work. Check `status "$term"` is `idle` before killing an agent you didn't just
> `deliver`.

## Fan-out: many agents in parallel

Async `spawn` is the parallelism primitive — launch N, capture each `TERM`, then poll and
collect:

```bash
terms=()
for t in "Add tests for auth" "Document the API" "Fix the lint errors"; do
  terms+=("$(scripts/spawn.sh codex --prompt "$t")")
done

for term in "${terms[@]}"; do
  herdr agent wait "$term" --status idle --timeout 600000
  scripts/spawn.sh recover "$term"
  scripts/spawn.sh cleanup "$term" --kill
done
```

The skill reads no shared mutable state, so concurrent spawns never contend. See
[REFERENCE.md](REFERENCE.md#concurrency-model) for the concurrency and transcript-mapping guarantees.

## Defaults (the opinionated part)

- **Full permissions ON** — codex `--dangerously-bypass-approvals-and-sandbox`, claude
  `--dangerously-skip-permissions`. Pass `--safe` to disable.
- **cwd = caller's pane cwd** — the agent starts where you are working, not `~`. Override with `--cwd`.
- **Background / no focus** — spawns beside you without stealing focus; the prompt is delivered by a
  detached, **traced** worker (sidecar at `<cwd>/.iso/logs/spawn/<date>__<codex|claude-code>__<name>__<term>.spawn`
  — meta + trace). Pass `--focus` to jump to it, `--wait` to block until the task completes.
- **One agent per call.** Fan-out = call it again.

## Reference: verbs & options

| verb | synopsis | modules used |
|------|----------|-------------|
| `spawn` | launch agent, write sidecar, deliver prompt async or sync (`--wait`) | herdr, transcript, deliver |
| `deliver` | spawn + wait + recover; requires `--prompt`; opt-in `--kill` | deliver (composes spawn + recover) |
| `send` | type text into a live agent's pane (one-shot) | herdr |
| `recover` | read `output\|chat` from the agent's transcript | transcript, recover.py |
| `status` | print `idle\|working\|blocked\|unknown` | herdr |
| `cleanup` | remove a sidecar and/or kill a tab; `--orphaned` reaps stale sidecars | cleanup, herdr |

`spawn.sh <codex|claude> …` is a bare alias for `spawn.sh spawn <codex|claude> …`.

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

### Output contract

stdout is capturable; stderr is for humans:
- async `spawn` / plain `--wait` → stdout is the bare **`TERM`**.
- `deliver` / `--wait --recover` → stdout is the **recovered result**.
- the `spawned: …` banner, `status:`, `--- recovered ---` header, and progress notes → **stderr**.

### `lib/` layout

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

See [REFERENCE.md](REFERENCE.md) for the herdr object model, status semantics, and failure modes.

# herdr spawn — reference

## Object model

```
session (own server + socket; env HERDR_SESSION / HERDR_SOCKET_PATH)
└─ workspace        (wXXXXXXXXXXXXXX)        focus = UI cursor, NOT placement
   └─ tab           (wXXXX:N)                single-agent tabs are ephemeral
      └─ pane       (wXXXX-N)                $HERDR_PANE_ID may be a legacy id (pN)
         └─ agent   (codex | claude)         names are server-global & unique
```

CLI is a thin client over the session socket. Any pane can mutate shared state, so an
agent can spawn another agent beside itself.

## Targeting rules (most → least stable)

1. **Own workspace** — `herdr pane get "$HERDR_PANE_ID"` → `result.pane.workspace_id`. Used by this skill.
2. **By label** — `herdr workspace list`, match `label`. Labels mutate; resolve fresh each call.
3. **By focus** — omitting `--workspace` lands in the focused workspace. Drifts; avoid for scripts.

`--workspace <id>` is absolute: it places the tab there regardless of focus.
`--focus` / `--no-focus` only controls whether the UI jumps to the new tab.

## Why split-then-close (not just `agent start --tab`)

`tab create` always yields a tab with one **root shell pane**. `agent start --tab <T>`
then adds the agent as a *second* pane → the tab shows a **split**, not a clean agent tab.

Fix the script uses: create tab → `agent start --tab` (splits) → `pane close <root>`.
The tab survives with only the agent pane. Caveats:
- After closing the root, **pane ids renumber** — re-resolve the agent's pane from its
  stable `terminal_id` (`agent get <term>` → `pane_id`) before any `send-keys` / `pane run`.
- `agent start --workspace` *without* `--tab` does **not** make a new tab — it splits into
  the currently-focused tab (worse: it can split into your own session tab).
- `pane run <root> "codex"` (launch in the shell instead of `agent start`) keeps a single
  pane but did **not** reliably foreground codex in testing — avoid.

## Failure modes seen in practice

| symptom | cause | fix |
|---------|-------|-----|
| `agent_name_taken` | name already used by a live/idle agent | auto-suffixed (`codex`, `codex-2`, …) by the script |
| `pane_not_found` / `tab_not_found` | the tab self-closed when its only agent exited | re-list (`herdr agent list`), respawn |
| spawn denied by classifier | auto-mode safety gate on `--dangerously-*` | **turn auto-mode OFF** — allowlisting alone does NOT pass the classifier; or use `--safe` |
| first prompt swallowed | sent keys into an unrecognised trust modal | check `$CWD/.iso/logs/spawn/<date>__<agent>__<name>__<term>.log`: `injects:0` + a modal on screen = add its pattern |
| prompt never lands / worker died | a `set -e` abort or lost prompt in the detached worker | `cat` the worker log (xtrace) — the failing command is the last line before EOF |

## Delivery model (async by default)

The main invocation returns in ~1s after the structural work (resolve workspace+cwd, name, tab,
agent start, collapse root, **resolve the agent pane once**). The slow part — trust-modal clear +
prompt inject + optional idle-wait — runs in a **detached, logged background process**
(`ISO_TRACE=1 nohup "$SELF" __deliver … >LOGFILE & disown`). Verified to survive the parent
shell/tool-call ending and to ride out claude's boot.

`--wait` runs the same `__deliver` in the **foreground** (no trace log), blocking until the agent
finishes (`agent wait --status idle` — which also matches the terminal `done` state, confirmed by
timing: it returned in ~10s, far under the 600s timeout, on a `done` codex), then prints final status.

### The pane is resolved once, in the parent
After root-collapse the parent resolves the agent's `pane_id` (via `agent get`, falling back to
`pane list` by tab) and passes it to `__deliver`. The worker therefore makes **one `pane read` per
tick** and never re-lists — the pane is stable because the only renumbering event (root-collapse)
already happened.

### Delivery is one unified poll loop (≤40 ticks)
Each tick reads the screen once, then: **(1)** if a trust modal is up, send its one key and re-loop;
**(2)** else if there's no prompt, exit (modal cleared); **(3)** else inject when the input box is
painted+empty, and — *only after injecting* — confirm acceptance.

### Acceptance = status OR screen, but only AFTER injecting
The accept-signal is `status ∈ {working,done,blocked}` **or** the prompt committed on screen
(`classify` finds it above the trailing `›`/`❯` input line, not sitting in it). Two hard-won rules
(both reproduced under test):
- **Status is boot-noise until you inject.** claude emits `working`/`done` during boot from MCP-load
  and SessionStart hooks — *before any prompt*. The status check is gated behind an `injected=1`
  flag; without the gate the loop broke at boot and the prompt was never sent (observed: iters=2,
  injects=0).
- **`agent wait --status working` is the wrong confirm.** It returns rc=1 (timeout) on an already-
  `done` agent (proven: 3s wait → rc=1), so a fast agent racing working→done between polls gets
  re-injected → double prompt. status-OR-screen replaces it: a fast `done` satisfies the status
  branch, a committed prompt satisfies the screen branch. `classify` distinguishes a *pending*
  prompt (sitting unsent in the input line → resend `Enter`) from a *submitted* one.

### set -e landmines in the detached worker (do not reintroduce)
With `set -euo pipefail`, the background worker dies **silently** on any unguarded non-zero command —
and a dead worker means the prompt never lands, with no error visible to the caller. Guard rigorously:
- `grep -q … && break` returns 1 when no match → aborts. Use `if … then break; fi`.
- `agent wait … && break` returns 1 on timeout → aborts. Use `if …; then break; fi`.
- `pane send-keys … C-u` — `C-u`/`ctrl-u` are **unsupported** tokens (`invalid_key`) → aborts.
  Valid tokens seen: `Down Enter t Esc`. Append `|| true` to every herdr call in the worker.

## Agent status (monitoring)

herdr tracks every agent as `idle | working | blocked | unknown`:

```bash
herdr agent list                                   # status of all agents
herdr agent get <term>                             # one agent's status
herdr agent wait <term> --status idle --timeout MS # block until a transition
```

- `working` — actively running a turn (hook fired UserPromptSubmit/PreToolUse)
- `idle`/`done` — finished, awaiting input (Stop hook). `agent wait --status idle` matches `done`.
- `blocked` — waiting on a permission prompt / approval
- `unknown` — no hook has fired yet.

**Status is not a readiness signal — and at boot it is actively misleading.** claude emits
`working`/`done` *during boot* from MCP-load and SessionStart hooks, before any prompt exists. So
status only means "accepted the task" once you have already injected (hence the worker's `injected`
gate). Use status to confirm acceptance/completion *after* injecting, never to decide when to inject.

## Trust modal variants

- **3-option select** (`1 Review / 2 Trust all / 3 Continue`, "press enter to confirm"):
  arrow-select — `pane send-keys <pane> Down Enter`. Do **not** type `2` (mis-selects).
- **Hooks table** ("Press t to trust all"): `pane send-keys <pane> t`.
- **claude folder-trust** (`1 Yes, I trust this folder / 2 No, exit`, "Is this a project you created
  or one you trust?"): default cursor is already on *Yes* → plain `pane send-keys <pane> Enter`.
  **Only appears under `--safe`** — full-perm claude (`--dangerously-skip-permissions`) skips it,
  which is why it was invisible until `--safe` testing. The worker matches it on
  `trust this folder|project you created or one you trust`.
- **Already trusted**: codex persists trust within a session; no modal appears — skip.

## Useful commands

```bash
herdr agent list                       # all agents: status, ids, cwd, workspace
herdr agent read <term> --source visible --lines N
herdr pane run <pane> "<text>"         # text + Enter (submit a prompt)
herdr pane send-keys <pane> <key>...   # raw keys (Down, Enter, t, Esc, ...)
herdr agent wait <term> --status idle --timeout MS
herdr tab close <tab>                  # tear down
```

## Codex full-access argv

`codex --dangerously-bypass-approvals-and-sandbox` → "YOLO mode" (no approval, no sandbox).
Skip `--dangerously-bypass-hook-trust`: it printed a warning but still forced an interactive
review panel and destabilized boot in testing.

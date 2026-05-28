# iso-spawn refactor — modular verbs, lifecycle & cleanup — design

**Date:** 2026-05-27
**Skill:** `skills/iso-spawn`
**Status:** approved design, pending implementation plan
**Builds on:** the (currently uncommitted) output-recovery feature
(`docs/superpowers/specs/2026-05-27-iso-spawn-output-recovery-design.md`)

## Problem

`spawn.sh` has grown into one monolithic script doing five jobs (herdr plumbing, delivery
poll loop, transcript mapping, recovery, arg parsing) with heterogeneous entrypoints
(`spawn.sh codex …`, `--recover`, `--candidate-set`, `--write-meta`, `--diff-new`). It works
but is hard to read, hard to test in parts, and offers no first-class way to **interact with
a spawned agent after spawning** (send follow-up input, check status, recover the result) or
to **clean up** (kill a tab to free memory, remove leftover sidecars). It must also stay
**reliable under concurrency**: many agents spawned by the same skill, possibly in the same
cwd, must never conflict.

**Goal:** refactor into clean, reusable building blocks (sourced bash libs + the existing
pure python parser) exposed through a small set of subcommands, add interaction and cleanup
verbs, and make agent→artifact mapping concurrency-safe.

## Scope

**In scope**
- Restructure into a thin dispatcher + four sourced lib modules + the existing parser.
- Subcommand CLI (`spawn|deliver|send|recover|status|cleanup`), keeping the bare
  `spawn.sh <codex|claude> …` as an alias for `spawn` (back-compat with docs / iso-write).
- New verbs: `deliver` (spawn→task→wait→recover wrapper), `send` (input to a live agent),
  `status`, `cleanup`.
- `--kill` flag on every verb that targets an existing agent (`deliver`, `send`, `recover`,
  `status`, `cleanup`) — closes the tab after the action. Never default. Not on bare `spawn`.
- Concurrency-safe transcript mapping (snapshot-diff → prompt-content fingerprint →
  newest-by-mtime).
- Orphan-based cleanup with a grace window; remove a killed agent's sidecar immediately.

**Out of scope**
- Autonomous multi-turn drive loop (detect-question → reply → verify). `send` is a single
  one-shot input primitive; the parent composes any real conversation. (Own future spec.)
- Modality auto-detection (text box vs menu) for `send`. Caller picks the input.
- Time-based (TTL) sidecar pruning — replaced by orphan-based cleanup.
- Copying transcripts into `.iso` (pointer design retained, per prior decision).

## Architecture — layered building blocks

```
scripts/spawn.sh          — CLI dispatcher ONLY: parse subcommand + flags, source libs,
                            call the matching lib function, print usage. No business logic.
scripts/lib/herdr.sh      — herdr primitives (the "talk to herdr" layer):
                            resolve caller pane→workspace+cwd, agent status, pane read,
                            pane run / send-keys, tab create / close, agent list, kill tab.
scripts/lib/transcript.sh — the "where is the transcript" layer:
                            slug, candidate-set, snapshot-diff, prompt-fingerprint match,
                            .spawn sidecar read/write, resolve session_file.
scripts/lib/deliver.sh    — the delivery poll loop (trust modals, inject, classify, accept)
                            and the `deliver` wrapper orchestration.
scripts/lib/cleanup.sh    — orphan detection, sidecar removal, tab kill.
scripts/recover.py        — pure JSONL parser (UNCHANGED from the recovery feature).
```

Each lib has one responsibility and a documented function interface; `spawn.sh` holds no
logic beyond dispatch. Libs are sourced (`. "$LIBDIR/herdr.sh"`), not exec'd. This introduces
the repo's first `lib/` pattern (today every skill script is self-contained) — justified by
the explicit goal of reusable blocks.

### Sourcing & self-invocation
`spawn.sh` computes `LIBDIR="$(dirname "$0")/lib"` and sources the four libs at the top.
The detached delivery worker currently re-execs the script (`"$SELF" __deliver …`); it stays
a hidden `__deliver` subcommand that re-sources the libs — so the worker has the same
functions. All internal debug entrypoints (`__candidate_set`, `__diff_new`, `__write_meta`,
`__deliver`) move under the `__`-prefixed hidden namespace and are used only by tests/worker.

## Verbs (the public contract)

```
spawn.sh spawn   <codex|claude> [--prompt T] [--cwd P] [--label L] [--name N]
                                [--safe] [--split right|down] [--focus] [--wait]
                                [--recover [output|chat]]
spawn.sh <codex|claude> …        # bare alias for `spawn`
spawn.sh deliver <codex|claude> --prompt T [spawn opts] [--what output|chat] [--kill]
spawn.sh send    <TERM> <text> [--kill]
spawn.sh recover <TERM> [--what output|chat] [--format text|json] [--kill]
spawn.sh status  <TERM> [--kill]
spawn.sh cleanup (<TERM> [--kill] | --orphaned)
```

| verb | behaviour | modules |
|---|---|---|
| `spawn` | place agent, write sidecar, dispatch delivery (bg or `--wait`); `--recover` prints output after `--wait` idle | herdr, transcript, deliver |
| `deliver` | wrapper: `spawn --wait` + recover the result; verifies a non-empty result came back; `--kill` closes the tab after capture | deliver (composes spawn + recover) |
| `send` | resolve the agent's live pane from its `TERM`, type `<text>` (one-shot input). Errors if the agent is gone | herdr |
| `recover` | read output/chat from the transcript (sidecar→jsonl→scrollback fallback) | transcript, recover.py |
| `status` | print `idle\|working\|blocked\|unknown` | herdr |
| `cleanup` | `<TERM>`: kill that agent's tab (with `--kill`) and delete its sidecar. `--orphaned`: delete sidecars whose TERM is absent from `herdr agent list` and older than the grace window | cleanup, herdr |

`--kill` semantics: after the verb's primary action, call `herdr tab close` for the agent's
tab and delete its `.spawn` sidecar (the tab is gone; scrollback recovery is dead anyway, and
the jsonl remains on disk if truly needed). Never the default.

## Reliability / concurrency model

**`TERM` (herdr terminal_id) is the single global-unique anchor.** Every verb addresses one
`<TERM>`; every sidecar is named `…__<TERM>.spawn`. N agents = N independent lanes; the skill
reads no shared mutable file, so concurrent invocations never contend.

**Agent name** collisions are already avoided by auto-suffixing (`codex`, `codex-2`, …).

**Transcript mapping — the one genuine race.** Snapshot-diff alone can mis-assign when two
same-agent, same-cwd spawns start within the same moment (each sees the other's new file).
`transcript.sh` resolves in this order:
1. **snapshot-diff** — candidate files that appeared after this spawn's pre-snapshot
   (recorded as `pre=` in the sidecar);
2. **prompt fingerprint** — if a prompt was delivered, pick the candidate whose *content*
   contains that prompt string (the agent writes the prompt into its own transcript → a
   unique fingerprint that beats any timing race);
3. **newest-by-mtime** — only when no prompt exists to fingerprint (bare promptless spawn).

So every `deliver` / `--prompt` spawn is concurrency-proof; promptless spawns fall to
best-effort newest (acceptable — no payload to disambiguate).

**Cleanup race.** A sidecar can exist microseconds before its agent registers in
`herdr agent list`. `--orphaned` therefore reaps a sidecar only when **both**: its `TERM` is
absent from the live list **and** the sidecar file mtime is older than a grace window
(`ISO_ORPHAN_GRACE`, default 60s). A killed agent's sidecar (`cleanup <TERM> --kill`) is
removed immediately — the kill is deliberate.

## Data flow (unchanged core, new seams)

```
spawn:   herdr.resolve_caller → transcript.candidate_set (pre) → herdr.start_agent
         → transcript.write_meta(pre) → deliver.dispatch(bg|wait)
deliver_worker: deliver.poll(inject+accept) → transcript.resolve_new(pre, prompt)
         → transcript.append_session_file
deliver: spawn --wait → recover → [--kill → cleanup]
recover: transcript.resolve(TERM) → recover.py | herdr.scrollback fallback
send:    herdr.pane_for(TERM) → herdr.pane_run(text)
status:  herdr.agent_status(TERM)
cleanup: herdr.agent_list → (orphaned|named) → herdr.tab_close + transcript.rm_sidecar
```

## Error handling

- `set -euo pipefail` throughout; every herdr call in any worker/loop guarded with `|| true`
  (an unguarded non-zero must never silently kill the detached worker — see recovery spec).
- `send`/`status`/`recover --kill` on a dead `TERM` → clear stderr error, non-zero exit
  (no pane to act on).
- `recover` keeps its existing fallback chain (sidecar → diff → newest → scrollback header).
- `cleanup --orphaned` is best-effort: a sidecar it can't stat or remove is skipped, not fatal.

## Testing

The bash runner (`tests/run.sh`) sources the libs and tests pure-fs / pure-logic functions
directly; herdr-touching functions are exercised via a stub or the live smoke test.

1. **transcript.sh** (env-overridable dirs `ISO_CODEX_SESS`/`ISO_CLAUDE_PROJ`):
   candidate-set, snapshot-diff, slug, write/read sidecar — port the existing recovery tests
   to the sourced functions.
2. **prompt-fingerprint disambiguation:** two new candidate files in one cwd, only one
   containing the prompt string → resolver picks the prompt-matching file (not newest).
3. **recover.py:** unchanged — existing fixtures/assertions stay green.
4. **cleanup:** with a stubbed `herdr agent list`, `--orphaned` removes a sidecar whose TERM
   is absent AND older than grace, but keeps one within grace and one whose TERM is present;
   `cleanup <TERM> --kill` removes that sidecar.
5. **dispatch:** `spawn.sh recover … --session-file …` (the test seam) and the bare-alias
   `spawn.sh codex` path both route correctly; unknown verb → usage + non-zero.
6. **Live smoke (manual):** `deliver codex --prompt "…token…"` returns the token then, with
   `--kill`, the tab is gone from `herdr agent list`; `send` delivers a second input to a
   live agent and `status` reflects `working`.

## Migration / back-compat

- `spawn.sh <codex|claude> …` keeps working (alias → `spawn`). iso-write callsites and docs
  unaffected.
- The recovery feature's files are rewritten into the module layout in place; everything
  stays **uncommitted** for one combined review at the end.
- SKILL.md / REFERENCE.md / README.md updated for the verb surface and `lib/` layout.

## Open questions

None blocking. Grace-window default (60s) and `--kill` exclusion from bare `spawn` are fixed
above; revisit only if the live smoke test surfaces timing issues.

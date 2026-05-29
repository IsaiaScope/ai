# spawn lifecycle primitives — design

**Date:** 2026-05-29
**Status:** grilled

## Goal

Move the *robust* parts of "spawn a tab, know what it's doing, survive anything that can happen to it" out of individual skills and into one tested place in **iso-spawn**, so every skill that spawns a terminal (`iso-review`, `iso-write`, future spawners) inherits the same completion-detection, liveness, and flush-lag handling for free — instead of each re-implementing (and subtly mis-implementing) it.

## Why now

iso-review hit three failure modes the native `herdr agent wait --status idle` does not handle. They were fixed inside `iso-review/scripts/lib/drive.sh`, but the **same gaps live in the shared `iso-spawn` layer** (`deliver.sh:48` uses the very same `agent wait --status idle`), so `iso-write` and every `--wait`/`deliver` consumer is still exposed:

| gap | symptom | who is exposed today |
|-----|---------|----------------------|
| **stuck `working`** | herdr status sticks on `working` after a turn ends → `agent wait --status idle` burns the whole timeout | every `deliver`/`--wait` caller |
| **flush-lag** | status/pane lead the jsonl disk write → a recover right after `idle` grabs a pre-final turn (the 105-char "Let me verify…" capture) | every recover caller |
| **no liveness / dead-detect** | a dead agent and a genuinely-slow one are indistinguishable by status alone → both blindly consume the timeout | every `deliver`/`--wait` caller |

## Core principle (locked in grilling)

**Liveness is universal; completion is domain-specific.**

- "Is the tab *alive*?" can be answered with zero knowledge of the task — from screen activity (pane content changes, or an `esc to interrupt` indicator). → belongs in iso-spawn.
- "Is the work *done*?" needs either a generic proxy (status `idle`/`done`) or a **domain artifact** (iso-review's findings JSON). → the generic proxy belongs in iso-spawn; the domain artifact is injected by the caller via a predicate hook and never leaks into iso-spawn.

This is why one shared loop can serve both the generic and the specialized case without iso-spawn ever knowing what "findings" are.

## Decisions

| Question | Decision |
|----------|----------|
| Where does the shared logic live | `iso-spawn/scripts/lib` — a new `lib/wait.sh` (sourced like `herdr.sh`/`deliver.sh`), plus one liveness helper in `herdr.sh`. |
| What moves down | (a) screen-liveness primitive, (b) settle-recover, (c) wait-with-reason poll loop. |
| What stays up in iso-review | the findings-shape regex — passed *into* the shared loop as a `--done-test`, not embedded in it. |
| How the domain "done" test is injected | `wait_done … --done-grep 'REGEX'`; the loop runs `grep -qE -- "$REGEX"` on the recovered output (no `eval`, no nested-quote escaping). Absent → generic callers fall through to the `status idle/done` + liveness path. |
| Grace length | **Conditional on `--done-grep`.** With a done-grep set, an `idle`-but-no-artifact state is suspicious (the artifact may still land) → long grace (~30s). Without one, `idle` *is* completion → return after ~2 stable polls (~4s, flush-lag guard only). Prevents a 30s regression on every generic `deliver`. |
| Back-compat | `deliver --wait` today ignores the outcome (`… \|\| true`). The enriched wait must stay non-fatal for callers that don't read the reason; the richer outcome is opt-in. |
| Ownership / sequencing | `iso-spawn/*` is another agent's working tree. This spec is the hand-off artifact; the iso-spawn owner (or a coordinated change) implements it tests-first. **No iso-spawn edits land from the iso-review work.** |

## Proposed API (iso-spawn)

```
# --- liveness (herdr.sh) -------------------------------------------------------
herdr_pane_active TERM
  # 0 if the tab is visibly doing work: the visible pane cksum changed since the
  # last call (PRIMARY) OR shows `esc to interrupt` (best-effort; observed absent
  # on claude, so decorative). Content-agnostic. Errs toward "active".
  # Blind spot: a hang that keeps the spinner animating reads as active — caught
  # by wait_done's timeout ceiling, not here.

# --- lib/wait.sh ---------------------------------------------------------------
wait_recover_settled TERM [--what output|chat]
  # recover, then re-recover until the output stops growing across N reads
  # (rides the jsonl flush-lag). Generic: no domain knowledge, just byte-stability.
  # Prints the settled output; always exits 0 (best-effort).

wait_done TERM [--timeout S] [--done-grep 'REGEX'] [--escalate S] [--dead S]
  # block until the turn is DONE, returning a reason on stderr and a code:
  #   0 done | 2 blocked | 3 dead | 4 timeout
  # KILL-AGNOSTIC: never closes the tab — disposal is the caller's (--kill / cleanup).
  # poll every 2s:
  #   status blocked                          -> return 2
  #   --done-grep matches recovered output    -> wait for byte-stability -> return 0   (domain artifact)
  #   status idle|done (no done-grep)          -> ~2 stable polls (~4s)    -> return 0   (generic: idle == done)
  #   status idle|done (done-grep set, no match) -> sustained-idle grace (~30s) -> return 0
  #   status working, no artifact:
  #       < escalate            -> keep waiting (cheap; no screen reads)
  #       >= escalate, every 10s -> herdr_pane_active? alive : dead++ ; dead>=limit -> return 3
  #   timeout cap                             -> return 4
```

`wait_done` is today's `rv_wait_finished` with the findings-grep replaced by the pluggable `--done-grep`, and the idle-grace made conditional on whether a `--done-grep` is set (generic callers return fast; specialized callers stay paranoid). Thresholds (`escalate`, `dead`, `timeout`) are flags with env fallbacks so callers and tests can tune them.

## Migration

1. **iso-spawn — add primitives + tests** (tests-first). New `lib/wait.sh`, `herdr_pane_active` in `herdr.sh`. Unit tests: each `wait_done` outcome (done via artifact, done via idle, blocked, dead via frozen screen, timeout) using the `--session-file` / fixture seams already in `tests/run.sh`.
2. **iso-spawn — `deliver.sh:48`** swaps bare `agent wait --status idle` → `wait_done "$TERM2" --timeout …`. Keep it non-fatal. → `iso-write` and all `--wait`/`deliver` callers inherit the fixes. Existing `tests/run.sh` must stay green.
3. **iso-spawn — `spawn.sh recover`** gains `--settle` (opt-in `wait_recover_settled`).
4. **iso-review — collapse `drive.sh`.** Delete `rv_wait_finished`, `rv_confirm_started`, `rv_recover_settled`, and the duplicate `herdr_agent_status` fallback; call the shared primitives, passing the findings-shape as `--done-grep`. Net: drive.sh shrinks, drift risk gone.

## Test plan

- iso-spawn `tests/run.sh`: existing assertions stay green (no behavioral regression for current `deliver`/`recover`).
- New: `wait_done` returns the right reason for each of the five outcomes (fixture transcripts + a stubbed status/pane reader).
- New: `wait_recover_settled` returns the final turn, not a pre-final one, when the fixture grows across reads.
- iso-review `drive.test.sh`: stays green after the collapse (the 7 preflight/detect-test assertions are unaffected; add a `--done-grep` wiring assertion).

## Locked decisions (grilled 2026-05-29)

1. **Thresholds.** Generic `deliver` keeps its existing `WAIT_MS` (default 600000 = 10 min) as the ceiling; screen-liveness arms *inside* it at `min(5 min, WAIT_MS/2)` so a stuck agent is caught well before the cap. iso-review keeps its own ~1h ceiling.
2. **Predicate seam.** `--done-grep 'REGEX'` (loop runs `grep -qE -- "$REGEX"` on the recovered output). No `eval`, no nested-quote escaping. `--done-fn NAME` only if a non-regex predicate ever appears (YAGNI).
3. **Kill-on-give-up.** `wait_done` is **kill-agnostic** — never closes the tab; returns a reason code and lets the caller's `--kill`/`cleanup`/`.spawned-terms` decide. Nothing leaks that wasn't already the caller's responsibility.
4. **Liveness signal.** Pane **cksum-change = primary**; `esc to interrupt` = best-effort OR (observed absent on claude this run, so decorative). Accepted blind spot: a hang that keeps the spinner animating reads as active and is caught only by the timeout ceiling. Future refinement (deferred): cksum the pane minus its volatile status line so a bare spinner isn't counted as progress.
5. **Naming.** Module-prefixed per house convention: `herdr_pane_active` (herdr.sh), `wait_done` + `wait_recover_settled` (new `lib/wait.sh`). Exact spelling of the settle fn is bikeshed; deferred.

### The two changes the grill forced
- **Grace is conditional on `--done-grep`** (decision in the Decisions table) — without it, a generic `deliver` would have paid a 30s idle-grace tax on *every* call; now it returns in ~4s.
- **`--done-grep REGEX`, not `--done-test CMD`** — kills the `eval`/quoting fragility of passing iso-review's backtick-and-quote-laden findings pattern through a shell arg.

## Constraint

`iso-spawn/*` is currently another agent's working tree. This document is the coordination artifact; it prescribes no edits to those files from the iso-review line of work. Decision recorded in [docs/adr/0002-spawn-lifecycle-primitives-in-iso-spawn.md](../../adr/0002-spawn-lifecycle-primitives-in-iso-spawn.md).

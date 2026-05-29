# Refactor: spawn lifecycle primitives into iso-spawn

**Goal:** Implement the [spawn lifecycle primitives spec](../specs/2026-05-29-spawn-lifecycle-primitives-design.md) — move the universal completion/liveness/settle-recover logic into shared `iso-spawn` helpers, migrate `deliver` and `iso-review/drive.sh` onto them, and finish the two parked iso-review items. TDD, no commits, on the current branch.

Read the spec end-to-end first — it holds the full API, the universal-vs-domain split, and the locked decisions. This plan is the executable task list; the spec is the source of truth for behavior.

## Hard constraints (override any contrary skill guidance)

- **Do NOT commit.** Leave every change uncommitted in the working tree.
- **Same branch** — no checkout, no new branch, no stash.
- **Tests-first.** `deliver` is load-bearing (`iso-write` depends on it): `skills/iso-spawn/tests/run.sh` MUST stay green at every step, and new behavior gets new assertions before the implementation.
- Follow the existing house style: bash, framework-free assertions (mirror `iso-spawn/tests/run.sh` and `iso-review/.../drive.test.sh`), module-prefixed function names.
- Keep functions **agent-agnostic** (term-only; no codex/claude branching).
- Run `bash -n` on every edited script and the full test suites after each task.

## Tasks

### Task 1 — `wait_recover_settled` (new `skills/iso-spawn/scripts/lib/wait.sh`)
- [x] **Test first:** in `iso-spawn/tests/run.sh`, drive `wait_recover_settled` against a fixture whose recovered output grows across reads (use the `--session-file` seam precedent, or a stub recover that returns a short string then a longer one) → assert it returns the final (settled) content, not the pre-final one.
- [x] **Impl:** recover, then re-recover until the output length is unchanged across N reads (flush-lag guard). No domain knowledge. Always exit 0 (best-effort). Signature per spec.

### Task 2 — `herdr_pane_active` (in `skills/iso-spawn/scripts/lib/herdr.sh`)
- [x] **Test first:** stub the pane reader so it returns changing content vs identical content across two calls → assert active=0 on change / on `esc to interrupt`, and active=1 on identical-and-no-marker. Add the minimal seam needed to make the pane reader overridable in tests (follow the `--session-file` precedent).
- [x] **Impl:** cksum the visible pane; active if the cksum changed since the prior call (primary) OR the pane shows `esc to interrupt` (best-effort). Content-agnostic; errs toward active.

### Task 3 — `wait_done` (in `lib/wait.sh`)
- [x] **Test first:** assert each outcome with stubbed status + pane readers and fixture recover output: (a) done via `--done-grep` match + byte-stability → 0; (b) generic idle, no `--done-grep` → fast 0 (~2 polls, NOT the long grace); (c) `--done-grep` set but idle with no match → long grace then 0; (d) blocked → 2; (e) working + frozen screen past escalate → 3 (dead); (f) timeout cap → 4.
- [x] **Impl:** port `iso-review`'s `rv_wait_finished` loop. Replace the hardcoded findings-grep with `--done-grep 'REGEX'` (`grep -qE -- "$REGEX"`). Make idle-grace **conditional on `--done-grep` presence** (absent → ~2 stable polls; present → ~30s sustained idle). Escalate to `herdr_pane_active` after `--escalate` (default `min(300, timeout/2)` s), give up after `--dead` frozen samples → return 3. `--timeout` is the runaway ceiling. **Kill-agnostic** — never close the tab. Reason on stderr, code 0/2/3/4. Thresholds are flags with env fallbacks.

### Task 4 — migrate `deliver.sh:48`
- [x] No new test; the gate is "existing `tests/run.sh` stays green." Swap the bare `herdr agent wait "$TERM2" --status idle --timeout "$WAIT_MS"` for `wait_done "$TERM2" --timeout "$WAIT_MS"` (no `--done-grep` → generic fast path). Keep it **non-fatal** for callers that ignore the outcome (preserve current `|| true` semantics). Source `wait.sh` wherever `herdr.sh`/`deliver.sh` are sourced.

### Task 5 — `spawn.sh recover --settle`
- [x] **Test first:** assert `recover --settle` routes through `wait_recover_settled` (reuse the Task 1 fixture).
- [x] **Impl:** add the opt-in `--settle` flag to the `recover` verb in `spawn.sh`.

### Task 6 — collapse `iso-review/scripts/lib/drive.sh`
- [x] **Test first:** add a `drive.test.sh` assertion that the review path now calls `wait_done` with a `--done-grep` carrying the findings shape (` ```json|"findings"|"summary"|"failure_scenario" `). Keep the existing 7 assertions green.
- [x] **Impl:** delete `rv_wait_finished`, `rv_confirm_started`, `rv_recover_settled`, and the duplicate `herdr_agent_status` fallback. Call the shared `wait_done` (passing the findings shape via `--done-grep`) and `wait_recover_settled`. Preserve the confirm-started-near-dispatch behavior using `wait_done`/status as appropriate. drive.sh shrinks; no logic duplicated with iso-spawn.

### Task 7 — `review.sh` executable bit
- [x] No test. Ensure `skills/iso-review/scripts/review.sh` is committed executable (`git update-index --chmod=+x skills/iso-review/scripts/review.sh`, and `chmod +x` locally) so a fresh clone run by absolute path doesn't hit `permission denied`. Do the same for any other new entrypoint scripts the skill tells users to run directly.

## Done when
- Both `skills/iso-spawn/tests/run.sh` and `skills/iso-review/scripts/lib/drive.test.sh` pass.
- `deliver`/`--wait` callers (incl. `iso-write`) inherit stuck-status + dead-detect + settle-recover with no API break.
- `drive.sh` carries no copy of the wait/recover/status logic.
- Nothing committed.

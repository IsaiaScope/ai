# Refactor architecture review sequence

**Goal:** Deepen the Spawn lifecycle, Review run, Init run, and Skill catalog modules in dependency order, without changing user-facing skill workflows.

## Decisions

- `Spawn lifecycle` is domain language. Universal lifecycle facts live in `iso-spawn`; task-specific completion facts stay with callers.
- `iso-todo` should switch from raw `herdr agent wait` to the shared `wait_done` seam, then keep its existing implementation-output classifier.
- `Review run` should use real `Reviewer adapter` files. Each adapter owns both dispatch and normalization because reviewer UI quirks and output shape vary together.
- `Init run` keeps human-readable setup detail in `iso-ai-init/SKILL.md`; the refactor should not collapse the docs into manifest-only instructions.
- `Skill catalog` covers local skill discovery, supported agent targets, and marketplace projection. Upstream skill packs stay hardcoded in `install.js` for now.

## Phase 1 — Spawn lifecycle adoption in iso-todo

- [x] Update `skills/iso-todo/scripts/todo.sh` to source or invoke the shared Spawn lifecycle wait seam instead of calling raw `herdr agent wait`.
- [x] Preserve the existing post-wait classifier in `skills/iso-todo/scripts/classify-impl.sh`.
- [x] Treat `wait_done` non-zero outcomes as the existing unknown/halt path; do not proceed to review on timeout, blocked, or dead.
- [x] Update `skills/iso-todo/scripts/todo.test.sh` so tests assert `wait_done` usage or the equivalent shared seam behavior.
- [x] Update `skills/iso-todo/SKILL.md` to document the shared Spawn lifecycle wait instead of raw `herdr agent wait`.

## Phase 2 — Reviewer adapters

- [x] Create `skills/iso-review/scripts/lib/reviewer-codex.sh`.
- [x] Move Codex reviewer dispatch from `drive.sh` into `reviewer-codex.sh`.
- [x] Move Codex raw-output-to-Finding normalization from `drive.sh` into `reviewer-codex.sh`.
- [x] Create `skills/iso-review/scripts/lib/reviewer-claude.sh`.
- [x] Move Claude reviewer dispatch from `drive.sh` into `reviewer-claude.sh`.
- [x] Move Claude raw-output-to-Finding normalization from `drive.sh` into `reviewer-claude.sh`.
- [x] Keep `drive.sh` focused on Review run lifecycle: spawn, adapter dispatch, wait, recover, demote scrollback, merge/write accepted fixes, apply, teardown.
- [x] Update `skills/iso-review/scripts/lib/drive.test.sh` to test adapter dispatch wiring and adapter normalization separately.
- [x] Update `skills/iso-review/SKILL.md` to name `Reviewer adapter` files as the reviewer-specific seams.

## Phase 3 — Init run documentation cleanup

- [x] Keep the detailed human-readable setup instructions in `skills/iso-ai-init/SKILL.md`.
- [x] Remove ambiguity that `templates/preflight-gate.sh` is still the primary interface; `scripts/init-runner.js` plus `steps.json` is the deterministic Init run interface.
- [x] Label legacy details as implementation detail and make sure they do not contradict `steps.json`.
- [x] Update `skills/iso-ai-init/README.md` only if it repeats stale gate-first language.
- [x] Run `skills/iso-ai-init/scripts/init-runner.test.js`.

## Phase 4 — Skill catalog local seam

- [x] Keep upstream packs in `scripts/install.js`.
- [x] Expand `scripts/skills-manifest.js` only around local Skill catalog behavior: local skill discovery, supported agent targets, plugin projection.
- [x] Adjust `scripts/install.js` to consume the Skill catalog for local skill linking and plugin sync, while leaving upstream pack installation in place.
- [x] Update `scripts/skills-manifest.test.js` to cover supported agent targets if that logic moves into the catalog.
- [x] Do not add upstream pack ownership to the Skill catalog in this pass.

## Verification

- [x] `bash skills/iso-spawn/tests/run.sh`
- [x] `bash skills/iso-review/scripts/lib/drive.test.sh`
- [x] `bash skills/iso-todo/scripts/todo.test.sh`
- [x] `node --test skills/iso-ai-init/scripts/init-runner.test.js`
- [x] `node --test scripts/skills-manifest.test.js`
- [x] `graphify update .`

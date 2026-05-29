# Architecture Deepening Review Implementation Plan

**Goal:** Apply the grilled architecture-deepening design: structured Spawn launch results, normalized Review findings, a real `iso-todo` script module, and manifest-driven Init steps.

**Architecture:** Keep each change behind the module that owns the behavior. `iso-spawn` owns machine-readable launch output. `iso-review` owns Reviewer normalization and applying fixes into an existing Implementation tab. `iso-todo` owns Development cycle orchestration over the existing plan/write/review modules. `iso-ai-init` owns deterministic Init orchestration through a manifest and independent Init steps.

**Constraints:** Preserve default CLI compatibility. Do not commit. Do not overwrite existing branch work. Use existing Bash 3.2 style and Node scripts.

## Phase 1 — Spawn launch result JSON

- [x] Add `--json` to `skills/iso-spawn/scripts/spawn.sh` for `spawn`, `deliver`, and `--wait --recover` flows.
- [x] JSON mode prints one machine object on stdout and suppresses normal human status banners.
- [x] Default non-JSON output stays unchanged.
- [x] Add focused tests to `skills/iso-spawn/tests/run.sh`.

## Phase 2 — Review run normalized Findings

- [x] Add normalized Finding helpers to `skills/iso-review/scripts/lib/drive.sh`.
- [x] Preserve raw reviewer outputs, but write normalized JSON files for codex and claude outputs.
- [x] Add tests for codex and claude raw-output normalization.
- [x] Keep the existing `--fix-term` direct-send behavior and test coverage.

## Phase 3 — Development cycle script module

- [x] Add `skills/iso-todo/scripts/todo.sh`.
- [x] The module should support a testable `run-plan <plan_path>` entry that launches the Implementation tab through `iso-spawn --json`, sends `/iso-write`, waits/classifies, then calls `iso-review` with `--fix-term`.
- [x] Keep the skill doc responsible for interactive plan creation, but delegate executable write/review mechanics to `todo.sh`.
- [x] Add `skills/iso-todo/scripts/todo.test.sh` with stubbed spawn/review commands.

## Phase 4 — Init manifest runner

- [x] Add `skills/iso-ai-init/steps.json`.
- [x] Add `skills/iso-ai-init/scripts/init-runner.js`.
- [x] Keep existing templates as the step implementations instead of moving files.
- [x] Runner evaluates git scope, filters disabled/repo-only steps, runs commands in manifest order, and prints a compact summary.
- [x] Add `skills/iso-ai-init/scripts/init-runner.test.js`.
- [x] Update `skills/iso-ai-init/SKILL.md` to call the runner.

## Verification

- [x] `bash skills/iso-spawn/tests/run.sh`
- [x] `bash skills/iso-review/scripts/lib/drive.test.sh`
- [x] `bash skills/iso-todo/scripts/classify-impl.test.sh`
- [x] `bash skills/iso-todo/scripts/todo.test.sh`
- [x] `node --test scripts/skills-manifest.test.js skills/iso-ai-init/scripts/init-runner.test.js`
- [x] `graphify update .`

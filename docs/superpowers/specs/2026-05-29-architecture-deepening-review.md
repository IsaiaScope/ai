# architecture deepening review — design

**Date:** 2026-05-29
**Status:** grilled

## Goal

Deepen four shallow modules without changing the public workflow shape:

1. **Spawn launch result** — machine callers stop parsing human banners.
2. **Review run** — codex and claude become fixed Reviewer adapters that normalize findings before merge.
3. **Development cycle** — `iso-todo` owns the full plan → write → review loop and reuses the Implementation tab as the Fix tab.
4. **Init run** — `iso-ai-init` becomes deterministic orchestration over independently addable/removable Init steps.

## Decisions

| Question | Decision |
|----------|----------|
| Spawn machine interface | Add `--json` across Spawn verbs where structured output saves caller parsing. In JSON mode stdout is machine-only; suppress the human banner on stderr except real errors. Existing default CLI output stays compatible. |
| Reviewers | Fixed in code for v1: codex + claude. Shape them as Reviewer adapters so adding another reviewer later adds one adapter instead of rewriting the Review run lifecycle. |
| Finding quality | Each Reviewer adapter persists raw output and normalizes it into Findings before merge. Merge/filter/apply works only against normalized Findings. Raw transcripts stay available for audit. |
| `iso-todo` scope | `iso-todo` is the main Development cycle skill. It runs plan → write → review automatically; after plan creation, the write phase dispatches without a Plan approval pause. |
| Fix tab in `iso-todo` | The Implementation tab is reused as the Fix tab. This is the current decision and is recorded in ADR-0001. |
| `iso-review --fix-term` | `iso-review` sends accepted fixes directly into the existing Implementation tab. Do not add a new generic `iso-spawn deliver-to` module for v1. |
| Fix wait/recover/report | `iso-review` owns send, wait, recover, verification, and the fix report even when using `--fix-term`. `iso-todo` consumes the Review run result for its final summary. |
| Init orchestration | Use an explicit Init manifest plus independent Init step scripts. The manifest owns ordering, scope, and enabled state; steps own implementation. |

## Candidate 1 — Spawn launch result

### Current friction

`iso-review` extracts `TERM` and `pane` by parsing `iso-spawn` human diagnostics:

- `skills/iso-review/scripts/lib/drive.sh` parses `term=` and `pane=` from spawn stderr.
- `rv_apply` parses `term=` from the fix spawn stderr.

That makes the Spawn interface shallow: callers must know the implementation format of a banner meant for humans.

### Deepened module

Add a structured Spawn launch result interface:

```bash
scripts/spawn.sh spawn codex --json [normal spawn opts]
scripts/spawn.sh deliver codex --json [normal deliver opts]
```

JSON mode prints one object on stdout and keeps stderr quiet except for real errors:

```json
{
  "term": "term_...",
  "pane": "pane_...",
  "tab": "tab_...",
  "agent": "codex",
  "name": "irvcodex",
  "cwd": "/repo",
  "spawn_file": "/repo/.iso/logs/spawn/...",
  "status": "idle",
  "result": "..."
}
```

For async `spawn`, `result` is absent. For `deliver` or `--wait --recover`, `result` carries recovered output and `status` carries the final status. Default non-JSON output stays unchanged: async `spawn` stdout remains bare `TERM`, and human banners stay on stderr.

### Leverage and locality

- **Leverage:** every machine caller gets `TERM`, `pane`, `tab`, and `spawn_file` without reverse-engineering text.
- **Locality:** launch result formatting changes inside `iso-spawn` only.
- **Test surface:** one JSON contract test replaces scattered grep assertions.

## Candidate 2 — Review run

### Current friction

`rv_reviews` owns too much at one interface: spawn reviewers, drive native UI, confirm start, wait, recover, demote scrollback, persist transcripts, kill tabs. Adding a reviewer later would duplicate lifecycle code or add more branching.

### Deepened module

Split Review run into:

- **Reviewer adapter** — dispatches one Reviewer and normalizes its raw output into Findings.
- **Review run** — fixed v1 adapter list (`codex`, `claude`), lifecycle orchestration, merge/filter, accepted/dropped ledger.
- **Fix application** — applies accepted fixes either in a fresh Fix tab or in `--fix-term <TERM>`.

Adapter shape:

```bash
reviewer_codex_dispatch REVIEW_SCOPE OUTDIR -> launch metadata
reviewer_codex_normalize RAW_FILE -> findings.json

reviewer_claude_dispatch REVIEW_SCOPE OUTDIR -> launch metadata
reviewer_claude_normalize RAW_FILE -> findings.json
```

`findings.json` is the only input to merge/filter:

```json
[
  {
    "source": "codex",
    "file": "skills/...",
    "line": 123,
    "problem": "...",
    "fix": "...",
    "severity": "medium"
  }
]
```

Raw outputs still persist under `.iso/logs/review/` for audit, but downstream code does not parse prose again.

### `--fix-term`

`review.sh apply accepted-fixes.md --fix-term <TERM>` sends the fix prompt directly to the existing Implementation tab, then uses shared wait/recover primitives to capture the fix report. `iso-review` owns the fix report; `iso-todo` reads it.

### Leverage and locality

- **Leverage:** adding a future Reviewer means one adapter plus one normalized output.
- **Locality:** reviewer-specific UI and output parsing do not leak into merge/filter/apply.
- **Test surface:** adapters test raw→Finding normalization; Review run tests lifecycle over normalized fixtures.

## Candidate 3 — Development cycle

### Current friction

`iso-todo` is the main Development cycle, but the workflow spans skill docs, specs, shell scripts, and tab state. The cycle should be executable and testable as one module.

### Deepened module

Create a real `iso-todo` script module:

```bash
skills/iso-todo/scripts/todo.sh run [seed...]
```

The module owns:

1. Run `iso-plan` in the parent session and capture plan path.
2. Spawn the Implementation tab using `iso-spawn --json`.
3. Send `/iso-write <plan>` to the Implementation tab.
4. Wait and classify completion using shared wait/recover primitives plus the per-plan blocked marker.
5. Run `iso-review reviews --kill-review-tabs`.
6. Run `iso-review apply ... --fix-term <TERM_IMPL>`.
7. Print final Development cycle summary.

No Plan approval pause. Plan success dispatches write automatically.

### Leverage and locality

- **Leverage:** one Development cycle command hides the phase choreography.
- **Locality:** tab lifecycle and halt classification live in `iso-todo`, not in user memory.
- **Test surface:** cycle tests can stub plan/write/review modules and assert phase decisions.

## Candidate 4 — Init run

### Current friction

`iso-ai-init` is mostly deterministic already, but the skill doc still owns run ordering and scope branching. That keeps the interface shallow: the agent must read prose, parse the gate, and remember which steps run.

### Deepened module

Add an Init manifest and a runner:

```text
skills/iso-ai-init/steps.json
skills/iso-ai-init/steps/00-caveman.sh
skills/iso-ai-init/steps/10-mcp-shrink.js
skills/iso-ai-init/steps/20-graphify.sh
skills/iso-ai-init/scripts/init-runner.js
```

Manifest shape:

```json
[
  { "id": "caveman", "scope": "global", "enabled": true, "command": "steps/00-caveman.sh" },
  { "id": "mcp-shrink", "scope": "global", "enabled": true, "command": "steps/10-mcp-shrink.js" },
  { "id": "graphify", "scope": "repo", "enabled": true, "command": "steps/20-graphify.sh" }
]
```

The runner owns gate evaluation, manifest order, scope filtering, execution, and summary. Each Init step remains independently addable/removable by editing the manifest and step file.

### Leverage and locality

- **Leverage:** deterministic init can be tested without an agent following prose.
- **Locality:** adding/removing setup behaviour changes one manifest entry and one step.
- **Test surface:** runner tests scope filtering and ordering; step tests stay local.

## Implementation order

1. **Spawn launch result JSON** — removes the most concrete leakage and helps `iso-todo`.
2. **Review run adapters + normalized Findings** — improves merge/apply quality before cycle orchestration depends on it.
3. **`iso-review --fix-term` direct send/wait/recover/report** — needed by `iso-todo`.
4. **`iso-todo` script module** — uses the deeper Spawn and Review seams.
5. **Init manifest + runner** — separate track; do after the Development cycle unless init is blocking.

## ADR alignment

- ADR-0001 chooses Implementation tab reuse as Fix tab inside `iso-todo`.
- ADR-0002 keeps universal liveness/completion primitives in `iso-spawn`; Review-specific Finding predicates stay in `iso-review`.

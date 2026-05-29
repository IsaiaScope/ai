# Context — IsaiaScope AI skills

Glossary of canonical terms for this repo. Definitions only — no implementation detail.

## Terms

**Skill** — a self-contained capability under `skills/<name>/`, exposed to an agent as `/<name>`. Each is agent-independent (Claude Code or Codex) unless stated.

**Spawn** — launching an agent (codex or claude) in its own herdr tab beside the current session. The primitive provided by `iso-spawn`.

**Spawn lifecycle** — the shared lifecycle of a spawned agent: launch, prompt delivery, liveness detection, completion detection, transcript recovery, and cleanup. Universal lifecycle facts belong in `iso-spawn`; task-specific completion facts stay with the caller.

**Spawn launch result** — the machine-readable handle returned by a Spawn: the Tab identity, pane identity, and sidecar path needed to monitor, recover, and clean up the spawned agent. The CLI keeps stdout/stderr compatibility, but callers should not parse the human banner.

**Agent kind** — which CLI an agent is: `codex` or `claude`. Each kind carries its own transcript layout, full-permission flag, and tab label. The facts that differ by kind belong together, not scattered across call sites.

**Tab** — a herdr pane running one agent, visible next to the caller. Visibility (watching work happen) is the reason to use a tab over a headless subprocess.

**Review scope** — the **uncommitted working-tree diff** (staged + unstaged) of the current branch. The change set `iso-review` reviews. Chosen so both reviewers see the identical diff and to match the `iso-write` handoff, which leaves implemented work uncommitted for review.

**Reviewer** — an agent running its native review command over the review scope: codex (`/review`, "uncommitted changes" preset) or claude (`/code-review`). A reviewer only reports; it does not edit.

**Review run** — one execution of `iso-review` over a review scope. It may use multiple reviewers now or later, but it owns dispatch, completion, recovery, finding merge, and optional teardown as one lifecycle.

**Reviewer adapter** — the code that knows how to dispatch one reviewer, recover its raw output, and normalize that output into findings. The default adapters are fixed in code as codex and claude.

**Finding** — a single issue raised by a reviewer: a location, a problem, and a proposed fix. Findings from both reviewers that point at the same location/issue are folded into one.

**Accepted fix** — a finding kept after the filter: applied automatically. Default for every merged finding except the net-negative ones.

**Dropped finding** — a finding excluded by the filter because applying it would make the code worse or overcomplicated (unwarranted abstraction, over-engineering, speculative refactor, churn). Carries a one-line reason.

**Fix tab** — the agent tab that applies accepted review fixes. In standalone `iso-review`, this is usually a fresh codex or claude tab. In a full `iso-todo` development cycle, the implementation tab is reused as the fix tab so review fixes land in the same agent context that wrote the implementation.

**Implementation tab** — the codex tab `iso-todo` spawns to run `iso-write`, executing the plan on a fresh `feat/<slug>` branch. It stays alive for the whole development cycle and is reused to apply accepted review fixes.

**Development cycle** — the end-to-end run `iso-todo` orchestrates: plan → write → review, each phase delegating to the matching skill (`iso-plan`, `iso-write`, `iso-review`). After the plan phase completes, the write phase starts automatically. Produces one uncommitted diff; commits nothing.

**Phase** — one stage of a development cycle: **plan**, **write**, or **review**. Plan and review run in the parent session; write runs in the implementation tab.

**Init run** — one execution of `iso-ai-init`. It is deterministic orchestration over independently addable or removable init steps.

**Init step** — one independently owned setup action within an init run, such as Caveman setup, MCP shrink, or Graphify wiring. Each step declares its scope and can be added or removed without rewriting the whole init run.

**Init manifest** — the ordered list of init steps for an init run. It makes step order and enabled state explicit while each step keeps its own implementation.

**Skill catalog** — the repository's discovered list of local skills, supported agent targets, and marketplace projection. The filesystem remains the source for local skill discovery; catalog logic owns how those facts are exposed to installers and manifests. Upstream skill packs stay installer-owned for now.

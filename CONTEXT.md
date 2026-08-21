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

**Implementation tab** — the agent tab `iso-todo` spawns to run `iso-write`, executing the plan on a fresh `feat/<slug>` branch. It stays alive for the whole development cycle and is reused to apply accepted review fixes.

**Development cycle** — the end-to-end run `iso-todo` orchestrates: plan → write → review, each phase delegating to the matching skill (`iso-plan`, `iso-write`, `iso-review`). After the plan phase completes, the write phase starts automatically. Produces one uncommitted diff; commits nothing.

**Phase** — one stage of a development cycle: **plan**, **write**, or **review**. Plan and review run in the parent session; write runs in the implementation tab.

**Init run** — one execution of `iso-ai-init`. It is deterministic orchestration over independently addable or removable init steps.

**Init step** — one independently owned setup action within an init run, such as Caveman setup, MCP shrink, or Graphify wiring. Each step declares its scope and can be added or removed without rewriting the whole init run.

**Init manifest** — the ordered list of init steps for an init run. It makes step order and enabled state explicit while each step keeps its own implementation.

**Skill catalog** — the repository's discovered list of local skills, supported agent targets, and marketplace projection. The filesystem remains the source for local skill discovery; catalog logic owns how those facts are exposed to installers and manifests. Upstream skill packs stay installer-owned for now.

**Hetzner config** — `~/.config/hetzner/hetzner.json`, the single file describing every Hetzner server and every self-hosted app pinned to one. It carries connection metadata and version pins only; no secrets. _Avoid_: fleet.json, software.json, the config files (plural).

**Fleet** — the set of Hetzner servers this machine knows how to reach, described by the `fleet` section of the Hetzner config: a default server name, inherited defaults, and one entry per server. `hetzner-create` adds entries, `hetzner-delete` prunes them, `hetzner-ssh` reads them. _Avoid_: roster, inventory.

**Software registry** — the `software` section of the Hetzner config: one entry per self-hosted app, each naming the fleet server it runs on plus the commands to read, upgrade, back up, and verify its version. Read by `hetzner-update`. _Avoid_: app registry, software.json.

**Iso config** — the merged view of the two configuration scopes that every `iso-*` skill reads. Not either file on its own: a value has no meaning until both scopes have been consulted. Carries no secrets. _Avoid_: the config file (singular), iso.json, settings.

**Config scope** — one of the two layers the Iso config is merged from: **global** (`~/.config/iso/iso.json`) describes the person and their machine; **repo** describes one repository. Repo wins per key, never per file. A repo scope may only carry `branches` and `paths` — letting it name the tracker or the identity would mean cloning a repository silently redirects where work is filed. _Avoid_: local config, user config, level.

**Overlay** — the repo config scope: a sparse document holding only the keys that differ from global, and a complete valid document at any size. An unknown or misspelled key is a hard error, never a silent fall-through to global. _Avoid_: partial config, patch, fragment.

**Prerequisite** — an external binary a skill shells out to, classified by what can be done when it is absent: **auto** (installable without asking — `jq`, `gh`, `multica`), **manual** (the steps are printed for a human to run — `codex`, `claude`), **hard-cut** (no install path exists, so the skill stops — `herdr`). The classification, not the binary, is what the code branches on. _Avoid_: dependency, requirement.

**Readiness stamp** — the record in the global config that the prerequisite sweep passed, carrying the time it ran and the prerequisite-list version it ran against. Skills trust the stamp instead of re-probing; a version bump invalidates it, so adding a prerequisite re-triggers the check without anyone remembering to. _Avoid_: ready flag, health check, cache.

**Run artifact** — per-run output written under `docs/iso/logs/`: review transcripts, spawn sidecars, blocked markers. Distinct from config in lifetime and in ownership — a run writes it, no human edits it. _Avoid_: log, output, temp file.

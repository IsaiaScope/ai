# Context — IsaiaScope AI skills

Glossary of canonical terms for this repo. Definitions only — no implementation detail.

## Terms

**Skill** — a self-contained capability under `skills/<name>/`, exposed to an agent as `/<name>`. Each is agent-independent (Claude Code or Codex) unless stated.

**Spawn** — launching an agent (codex or claude) in its own herdr tab beside the current session. The primitive provided by `iso-spawn`.

**Spawn lifecycle** — the shared lifecycle of a spawned agent: launch, prompt delivery, liveness detection, completion detection, transcript recovery, and cleanup. Universal lifecycle facts belong in `iso-spawn`; task-specific completion facts stay with the caller.

**Spawn launch result** — the machine-readable handle returned by a Spawn: the Tab identity, pane identity, and sidecar path needed to monitor, recover, and clean up the spawned agent. The CLI keeps stdout/stderr compatibility, but callers should not parse the human banner.

**Agent kind** — which CLI an agent is: `codex` or `claude`. Each kind carries its own transcript layout, full-permission flag, and tab label. The facts that differ by kind belong together, not scattered across call sites.

**Tab** — a herdr pane running one agent, visible next to the caller. Visibility (watching work happen) is the reason to use a tab over a headless subprocess.

**Review scope** — the staged diff against the branch's merge-base with the integration branch: every file the branch changed, listed once when a review run starts and fixed for its duration. The change set `iso-review` acts on. Staged rather than staged-and-unstaged because preflight is the last thing that ever stages, so a phase's own edits never enter the scope the next phase is measured against. _Avoid_: refine scope, working-tree diff, uncommitted changes.

**Review run** — one execution of `iso-review` over a review scope: three phases in fixed order, no question asked, nothing committed, nothing staged. Its whole output is readable as `git diff`, because the index holds the state the run started from. _Avoid_: refine run, pass, cycle.

**Review phase** — one of exactly three stages of a review run — **architecture**, **simplify**, **review** — each carrying its own revert boundary, recorded as a tree object before the phase starts. Architecture and simplify run in the calling session; review runs in a subagent, because the session that wrote the code is the worst reader of it. The order is fixed and review is last, so it sees on disk what the other two changed, while the scope it is handed names the same files throughout. _Avoid_: step, stage, pass.

**Phase gate** — the check deciding whether a review phase's edits survive: the configured test command runs after the phase, and a failure restores that phase from the tree object recorded before it ran — not from the index, which holds the state the whole run started from and would undo the phases that already passed. No configured command means no gate, which is reported rather than assumed. _Avoid_: test gate, verification step, guard.

**Plan entry** — one plan file recorded against a ticket, carrying its path, its state and the body it contributed. A ticket holds an ordered list of them, so the ticket describes the whole story rather than the plan that happened to open it. _Avoid_: plan, doc, attachment.

**Plan state** — what a plan entry is to the ticket now: **current** (the plan being worked), **done** (finished, kept for the record), **superseded** (replaced by a later plan that changed the approach). Exactly one entry is current. _Avoid_: status, active, archived.

**Finding** — one problem a review phase identified, at a location. Applied rather than reported, so findings are read in the diff and never collected into a ledger. _Avoid_: issue, suggestion, comment.

**Init run** — one execution of `iso-ai-init`. It is deterministic orchestration over independently addable or removable init steps.

**Init step** — one independently owned setup action within an init run, such as Caveman setup, MCP shrink, or Graphify wiring. Each step declares its scope and can be added or removed without rewriting the whole init run.

**Init manifest** — the ordered list of init steps for an init run. It makes step order and enabled state explicit while each step keeps its own implementation.

**Skill catalog** — the repository's discovered list of local skills, supported agent targets, and marketplace projection. The filesystem remains the source for local skill discovery; catalog logic owns how those facts are exposed to installers and manifests. Upstream skill packs stay installer-owned for now.

**Hetzner config** — `~/.config/hetzner/hetzner.json`, the single file describing every Hetzner server and every self-hosted app pinned to one. It carries connection metadata and version pins only; no secrets. _Avoid_: fleet.json, software.json, the config files (plural).

**Fleet** — the set of Hetzner servers this machine knows how to reach, described by the `fleet` section of the Hetzner config: a default server name, inherited defaults, and one entry per server. `hetzner-create` adds entries, `hetzner-delete` prunes them, `hetzner-ssh` reads them. _Avoid_: roster, inventory.

**Software registry** — the `software` section of the Hetzner config: one entry per self-hosted app, each naming the fleet server it runs on plus the commands to read, upgrade, back up, and verify its version. Read by `hetzner-update`. _Avoid_: app registry, software.json.

**Iso config** — the merged view of the two configuration scopes that every `iso-*` skill reads. Not either file on its own: a value has no meaning until both scopes have been consulted. Carries no secrets. _Avoid_: the config file (singular), iso.json, settings.

**Config scope** — one of the two layers the Iso config is merged from: **global** (`~/.config/iso/iso.json`) describes the person and their machine; **repo** describes one repository. Repo wins per key, never per file. A repo scope may only carry `branches`, `paths` and `test` — the three things that are genuinely properties of the repository. Letting it name the tracker or the identity would mean cloning a repository silently redirects where work is filed. _Avoid_: local config, user config, level.

**Overlay** — the repo config scope: a sparse document holding only the keys that differ from global, and a complete valid document at any size. An unknown or misspelled key is a hard error, never a silent fall-through to global. _Avoid_: partial config, patch, fragment.

**Prerequisite** — an external binary a skill shells out to, classified by what can be done when it is absent: **auto** (installable without asking — `jq`, `gh`, `multica`), **manual** (the steps are printed for a human to run — `codex`, `claude`), **hard-cut** (no install path exists, so the skill stops — `herdr`). The classification, not the binary, is what the code branches on. _Avoid_: dependency, requirement.

**Readiness stamp** — the record in the global config that the prerequisite sweep passed, carrying the time it ran and the prerequisite-list version it ran against. Skills trust the stamp instead of re-probing; a version bump invalidates it, so adding a prerequisite re-triggers the check without anyone remembering to. _Avoid_: ready flag, health check, cache.

**Run artifact** — per-run output written under `docs/iso/logs/`: spawn sidecars, blocked markers. Distinct from config in lifetime and in ownership — a run writes it, no human edits it. _Avoid_: log, output, temp file.

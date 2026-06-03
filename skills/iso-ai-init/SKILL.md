---
name: iso-ai-init
description: Initialize AI defaults. Global steps run anywhere — install/verify caveman (ultra + shrink + statusline) and shrink any allowlisted MCP server that is present and stdio-launchable. Repo-scoped steps (graphify CLI install + /graphify wiring) run only inside a git repo. A gate decides which steps apply. Use when the user runs /iso-ai-init or asks to set up AI tooling.
---

# iso-ai-init

Set up IsaiaScope AI defaults. Some steps are **global** (run anywhere, even outside a git repo); others are **repo-scoped** (run only inside a git working tree). The manifest-driven runner decides which apply — being outside a repo is not an error, it just skips the repo-scoped steps.

| Scope | Step | Runs |
|-------|------|------|
| global | Caveman (ultra + shrink + statusline) | always |
| global | MCP shrink (allowlist) | always |
| global | rtk (Rust Token Killer) install + Claude/Codex wiring | always |
| repo   | Graphify CLI install + `/graphify` wiring | only inside a git repo |

Deterministic orchestration lives in `scripts/init-runner.js`, driven by `steps.json`. Each enabled Init step points at an independently owned script in `templates/`. Resolve paths against the skill base directory (where this SKILL.md lives), referred to below as `<skill-base-dir>`.

## Step 0 — Deterministic Init run

Run the manifest-driven runner first:

```bash
node <skill-base-dir>/scripts/init-runner.js
```

The runner evaluates whether the current directory is a git repo, filters repo-scoped Init steps outside git repos, executes enabled steps in `steps.json` order, and prints the summary. Add or remove deterministic Init steps by editing `steps.json` plus the step script, not by rewriting this skill.

After the runner completes, continue to **Step 3b** only if the runner ran inside a git repo.

## Implementation detail — Gate

The old gate remains as human-readable implementation detail and dependency documentation. It does a hard **node** check (node is required by caveman install, the MCP-shrink script, and the statusline merge — fail fast here, not mid-step), then prints `IN_GIT_REPO=true|false` on its first line plus a human-readable plan. Do not use it as the primary ordering interface; `scripts/init-runner.js` and `steps.json` own deterministic ordering and scope filtering.

```bash
bash <skill-base-dir>/templates/preflight-gate.sh
```

When you add future repo-scoped Init steps, add them to `steps.json` first. Update the gate's plan only if the human-readable plan would otherwise become misleading. (`uv` is checked/auto-installed inside `graphify-init.sh`, since it's only needed for the repo-scoped graphify step.)

## Human detail — Caveman (global)

All caveman setup lives in `templates/caveman-init.sh` + `templates/caveman-config.json`.

```bash
bash <skill-base-dir>/templates/caveman-init.sh
```

The script handles two sub-steps:
- **1a** install caveman **globally** if not already set up. Detection uses an installed-artifact marker (`~/.claude/hooks/caveman-config.js`), **not** `command -v caveman` — caveman is a Claude *plugin*, not a PATH binary, so `command -v` always fails and would re-run the installer every time. Install flags: **not** `--all` (it turns on `--with-init`, which writes IDE rule files into the repo); instead `--non-interactive --skip-skills`, run from `$HOME`, so the install is global-only with **zero repo writes**. Defaults keep hooks + `caveman-shrink` (the binary our wrappers need) ON. Codex gets the caveman skill via a separate global `skills add -a codex` (also from `$HOME`).
- **1b** write `templates/caveman-config.json` → `~/.config/caveman/config.json` (sets `ultra` globally)

- **1c — Statusline** copy `templates/statusline.sh` → `~/.claude/statusline-command.sh`, then **safely merge** the `statusLine` key into `~/.claude/settings.json` (read-modify-write via node: preserves all other keys, skips if already set, backs up before writing). No hand-editing.

Wrapping MCP servers with `caveman-shrink` is **not** done here — it's owned by Step 2, which registers concrete entries from the allowlist.

Statusline shows: `…/repo/dir   branch   ctx:75%   $5.82   ULTRA`
- ctx% red at ≥ 90% usage, magenta below
- `ULTRA` → caveman mode; switches to token savings after `/caveman-stats`

## Human detail — MCP shrink (global)

Wrap allowlisted, token-heavy MCP servers with `caveman-shrink`. Runs everywhere — MCP config is global, not per-repo.

```bash
node <skill-base-dir>/templates/shrink-known-mcps.js
```

How it works (idempotent; backs up `~/.claude.json` + `~/.claude/settings.json` before any write):

- **Precondition** — verifies `caveman-shrink` is resolvable (installed by Step 1). If absent → no changes, tells you to run the caveman step first. Wrapping without the proxy would write entries that fail at MCP launch.
- **Prunes bare entries** — removes any upstream-less `caveman-shrink` MCP entry (what `caveman --with-mcp-shrink` registers: `npx -y caveman-shrink` with nothing to proxy) from top-level and per-project config. Wrapped entries (caveman-shrink + a real upstream) are kept. This is how the installer's bare registration is managed away while keeping the shrink binary.
- Carries an **allowlist of names worth shrinking** (`ALLOWLIST` array — edit to add more). It makes **no assumption about any MCP's transport**: whether a server is stdio or remote/HTTP is a per-machine fact, so it is checked at runtime, not hardcoded. The same name (e.g. `notion`) may be a local stdio server on one machine and a hosted HTTP endpoint on another.
- For each allowlisted name, based on what is actually configured on **this** machine:
  - **present as stdio in `~/.claude.json`** → wrap in place (reads its own command, so paths/env are preserved).
  - **present as stdio via an enabled plugin** → disable the plugin's copy and add a wrapped entry built from the plugin's own launch command (no duplicate server).
  - **present but remote/HTTP** → skipped — caveman-shrink spawns a local child process; there is nothing to spawn for a URL. (Not an error, just not compressible here.)
  - **already shrunk** → skipped.
  - **absent** → skipped. The script never installs an MCP you don't already have.

The allowlist is the only thing to maintain. Transport and launch command are discovered, never assumed — so the skill stays agnostic to any one machine's MCP setup.

## Human detail — rtk (global)

rtk (**Rust Token Killer**) is a CLI proxy that filters/compresses the output of common dev commands (`git status`, `ls`, `grep`, `cat`, …) **before it reaches the model** — 60-90% fewer tokens on those commands. It is a single static Rust binary (no runtime deps). Different layer from caveman, which compresses *prose*: rtk compresses *command output*, so they stack rather than overlap. All logic lives in `templates/rtk-init.sh`.

```bash
bash <skill-base-dir>/templates/rtk-init.sh
```

The script handles three sub-steps (idempotent):
- **install** the **correct** `rtk` binary globally. There is a **name collision**: a different tool, Rust *Type* Kit (`reachingforthejack/rtk`), also ships a binary called `rtk`, and both answer `command -v rtk` / `rtk --version`. So presence is gated on the official correctness probe **`rtk gain`** (Token Killer has it; Type Kit does not) — a machine with the wrong rtk pre-installed still gets the right one. Install order: official `install.sh` (prebuilt, pins dest `~/.local/bin`, unambiguous repo) → `cargo install --git <repo>` (guaranteed-correct source; never `cargo install rtk`, which may resolve to Type Kit on crates.io) → `brew install rtk` (best-effort). A **post-install gate** re-runs `rtk gain` and fails hard if the result is the wrong binary or off `PATH`. `~/.local/bin` is forced onto `PATH` so the freshly installed binary wins and the `init` calls below resolve it before any shell restart.
- **Claude Code wiring** — `rtk init -g` registers a **PreToolUse rewrite hook** that transparently rewrites `git status` → `rtk git status`, plus a `settings.json` entry. Gated on a `~/.claude/settings.json` `rtk` marker so re-runs stay quiet. Run from `$HOME` → zero repo writes.
- **Codex wiring** — `rtk init -g --codex` injects RTK instructions into the global `~/.codex/AGENTS.md` and writes `~/.codex/RTK.md` (Codex has no command-interception, so it gets instructions, not a hook). Gated on `~/.codex/RTK.md` / an `rtk` marker in `~/.codex/AGENTS.md`.

Both wirings are global (`-g`) and re-runnable; the markers only suppress repeat output. A Claude Code / Codex restart is needed to activate the rewrite hook.

## Human detail — Graphify wiring (repo-scoped — skip if not in git)

**Only run this step if the gate reported `IN_GIT_REPO=true`.** Outside a git repo, skip it entirely.

This step has two parts: **3a** deterministic wiring (`graphify-init.sh` — installs/updates the CLI, wires the skill, hooks, gitignore) and **3b** the actual **deep graph build** (an LLM step the skill drives, not the script). Like caveman, the wiring logic lives in a deterministic template script (no inline assembly):

```bash
bash <skill-base-dir>/templates/graphify-init.sh
```

`graphify-init.sh` (idempotent) does graphify's **officially recommended** repo setup:
- installs/auto-updates the graphify CLI;
- runs `graphify claude install --project` + `graphify codex install --project` — writes a `## graphify` section into repo-local `CLAUDE.md` / `AGENTS.md` telling the agent to prefer `graphify query "<q>"` over grepping. On Claude Code this also adds a PreToolUse **query-nudge hook** (`.claude/settings.json`) that fires *only* before grep/find-style Bash calls and just suggests querying the graph — read-only, no rebuild, no git: categorically unlike a commit/husky hook;
- installs **auto-update git hooks** via `graphify hook install` — native `post-commit` + `post-checkout` scripts that rebuild the graph via AST on each commit/checkout. No LLM, no husky — plain `.git/hooks`. Doc/concept (LLM) changes still need a manual `/graphify --update`; the hook refreshes the *code* graph only;
- gitignores `graphify-out/` (the graph artifacts) plus the regenerated/machine-specific wiring: the per-repo skill copies (`.claude/skills/graphify/`, `.agents/skills/graphify/` — drift between graphify versions, codex copy ships buggy) and `.codex/hooks.json` (bakes in a machine-specific absolute graphify path). The portable guidance — the `## graphify` section in `CLAUDE.md`/`AGENTS.md` and the `.claude/settings.json` query-nudge hook — stays committed.

It only drives the `graphify` CLI binary (its own interpreter — no `python` guessing). It does **not** build the graph itself — there is no CLI build verb; the full deep/semantic build is orchestrated by the `/graphify` *skill* (LLM subagents), which Step 3b runs next.

### Step 3b — Build / refresh the deep graph (repo-scoped)

After wiring, build the graph at its best quality. The build is **not** a CLI call — invoke the **`/graphify` skill** on the repo root with `--mode deep` (richest semantic + INFERRED edges; the standing default per the `## graphify` rule). This is an LLM step and may take a while on a large repo — expected, the user wants completeness over cost.

- **`graphify-out/graph.json` absent** → initial deep build: `/graphify . --mode deep`.
- **`graphify-out/graph.json` present** → refresh it: re-run `/graphify . --mode deep` (full deep re-extract — `graphify update .` is AST-only and would *not* refresh semantic edges, so it is not a substitute here).

Either way the command is the same (`/graphify . --mode deep`); only the framing differs. Skip only if the gate reported `IN_GIT_REPO=false`.

**After the build, sweep leftover root scratch:** `rm -f ./.graphify_*.json`. graphify drops pipeline intermediates as `.graphify_{detect,ast,analysis,extract,labels,semantic}.json` in the repo root and does not reliably clean them — confirmed on 0.8.18 (latest) after a normal completed deep build, so this is the common case, not a rare interruption. `graphify-init.sh` (3a) sweeps these *before* the build (clears the previous run's); run the same sweep *after* the build to clear the one this run just produced. Root-only glob — never `graphify-out/` or the committed `.graphify_version` skill files.

## Step 4 — Summary

Report only the steps that actually ran (omit graphify if it was gated out):

```
✓ [global] Caveman ultra + shrink + statusline (--all)
✓ [global] MCP shrink — allowlisted servers wrapped if present + stdio (remote/HTTP skipped)
✓ [global] rtk installed + Claude Code (PreToolUse hook) + Codex (AGENTS.md/RTK.md) wired
✓ [repo  ] Graphify CLI installed/updated + native always-on wiring (CLAUDE.md/AGENTS.md + query-nudge hook)
  · auto-update git hook installed (post-commit/post-checkout, AST rebuild)
  · graphify-out/ gitignored
  · deep graph built/refreshed via /graphify --mode deep
```

Then surface the natural follow-up (a pointer only — do **not** run it; it is an interactive skill outside this skill's deterministic scope):

- **Only if `IN_GIT_REPO=true` AND `docs/agents/` does not already exist:** the engineering workflow skills (`to-issues`, `to-prd`, `triage`, `diagnose`, `tdd`, `improve-codebase-architecture`) need per-repo config (issue tracker, triage labels, domain docs). Suggest: run `/setup-matt-pocock-skills`. Omit this line if `docs/agents/` is already present (already configured) or outside a git repo.

Remind user: restart Claude Code to activate the statusline, shrink wrappers, rtk rewrite hook, and skill wiring.

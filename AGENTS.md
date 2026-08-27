# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex) working with code
in this repository. `CLAUDE.md` is a symlink to this file — edit here.

## Install / Update

```bash
node scripts/install.js
```

Copies `config/CLAUDE.md` → `~/CLAUDE.md` and `config/AGENTS.md` → `~/.codex/AGENTS.md`, installs upstream skill packs via `npx skills@latest`, symlinks the local `IsaiaScope/ai` skills directly into both supported agents' skills dirs (Claude-side → `~/.claude/skills/`, Codex-side → `~/.codex/skills/`), and owns the tracker's two hooks in `~/.claude/settings.json` (see `scripts/agent-hooks.js`). No build step, no package.json. Tests are ad hoc: `node --test scripts/*.test.js` for the JS, `bash <skill>/scripts/*.test.sh` for the shell.

## Architecture

```
config/
  AGENTS.md   — global agent instructions (copied to ~/.codex/AGENTS.md on install)
  CLAUDE.md   — symlink to AGENTS.md (copied to ~/CLAUDE.md on install)
skills/                            — prefix routes each skill to a marketplace plugin (iso-* → eng, social-* → social)
  iso-config/SKILL.md              — the Iso config every iso-* skill reads
  iso-config/scripts/lib/branch.sh — shared branch vocabulary: protected test, name derivation, the gate
  iso-config/scripts/lib/track.sh  — the one seam to the tracker: iso_track, iso_track_path; never fatal
  iso-issue-tracking/SKILL.md      — work tracker, reached through a swappable adapter
  iso-ai-init/SKILL.md             — initialize a repo with IsaiaScope AI defaults
  iso-init-repo/SKILL.md           — initialize repo governance (branches, CI, hooks)
  iso-plan/SKILL.md                — planning pipeline orchestrator
  iso-write/SKILL.md               — TDD plan executor on a feature branch, no commits
  iso-review/SKILL.md              — review + fix the uncommitted working tree
  iso-spawn/SKILL.md               — spawn a codex/claude agent in a herdr tab
  iso-todo/SKILL.md                — full dev cycle: iso-plan → iso-write → iso-review (no commit)
  iso-readme/SKILL.md              — write/refine READMEs in house style, commit + push
  social-new-notebooklm-project/SKILL.md — research-first NotebookLM prep for a new video
scripts/
  install.js                        — deploys config files + installs skill packs globally
  agent-hooks.js                    — writes the tracker hooks into ~/.claude/settings.json (list: skills/iso-issue-tracking/scripts/hooks.json)
  dispatch-integrity.test.sh        — every verb a script dispatches must resolve to a defined function
.claude-plugin/
  marketplace.json                  — Claude marketplace catalog (2 plugins → ./plugins/<name>)
.agents/plugins/
  marketplace.json                  — Codex marketplace catalog (2 plugins → ./plugins/<name>)
plugins/                            — one subdir per marketplace plugin (routed by skill prefix)
  isaiascope-eng/                   — engineering plugin (iso-* skills)
    .claude-plugin/plugin.json      — Claude manifest (skills array, regenerated on install)
    .codex-plugin/plugin.json       — Codex manifest (skills: "./skills/", whole-dir)
    skills → ../../../skills/iso-*  — per-skill symlinks, regenerated on install
  isaiascope-social/                — social plugin (social-* skills)
    .claude-plugin/plugin.json      — Claude manifest (skills array, regenerated on install)
    .codex-plugin/plugin.json       — Codex manifest (skills: "./skills/", whole-dir)
    skills → ../../../skills/social-* — per-skill symlinks, regenerated on install
```

`scripts/install.js` installs these upstream skill packs globally for both `claude-code` and `codex`:
- `juliusbrussee/caveman` — token-compressed communication
- `safishamsi/graphify` — codebase → knowledge graph
- `forrestchang/andrej-karpathy-skills` — LLM coding guidelines
- `mattpocock/skills` — planning/debugging/TDD workflows
- `crafter-station/skills` (`--skill intent-layer`) — hierarchical AGENTS.md context engineering

The local `IsaiaScope/ai` skills are NOT installed via the marketplace pack. `scripts/install.js` scans `skills/*/SKILL.md` (via `scripts/skills-manifest.js`) and symlinks each into both supported agents — adding a new skill needs no edit here.

## Adding a Skill

1. Create `skills/<name>/SKILL.md`
2. Re-run `node scripts/install.js`

The skill set is derived from the filesystem: `scripts/install.js` scans `skills/*/SKILL.md`, symlinks each into both agents, **routes it to a plugin by name prefix** (`iso-` → `isaiascope-eng`, `social-` → `isaiascope-social`; see `PLUGINS` in `scripts/skills-manifest.js`), and regenerates that plugin's `.claude-plugin/plugin.json` + its private `skills/` symlink dir. There is no list to maintain — a directory with a `SKILL.md` is a skill, and its prefix picks the plugin.

A skill that needs configuration sources `iso-config/scripts/lib/config.sh` through
`iso_sibling`, never through an absolute `$HOME` path — `$HOME/.claude/skills/…`
resolves under exactly one of the four install topologies and is silently wrong
under the other three. Commit the regenerated `plugin.json` diffs.

Marketplace manifests need **no** edit when adding a skill: each Codex plugin declares `skills: "./skills/"` (whole-dir, auto-globbed over that plugin's private `plugins/<name>/skills/` dir), and only the Claude `plugin.json` arrays are regenerated. `install.js` rebuilds each plugin's per-skill symlinks (and prunes stale ones) on every run. A skill whose prefix matches no plugin is **not packaged** — `install.js` logs it as unrouted; add a new entry to `PLUGINS` to introduce a new prefix/plugin.

## Plugin Marketplace

This repo is a native marketplace for both agents (parallel manifests — the two CLIs diverge). The single `marketonfire` marketplace ships **two independently-installable plugins**: `isaiascope-eng` (engineering, `iso-*`) and `isaiascope-social` (social, `social-*`). Both live in subdirs — Codex rejects repo-root as a plugin source, so for symmetry the Claude plugins are subdir-sourced too.

| | Claude Code | Codex |
| --- | --- | --- |
| marketplace manifest | `.claude-plugin/marketplace.json` (2 plugins) | `.agents/plugins/marketplace.json` (2 plugins) |
| plugin location | subdir (`source: "./plugins/<name>"`) | subdir (`source: {source:"local",path:"./plugins/<name>"}`) |
| plugin manifest | `plugins/<name>/.claude-plugin/plugin.json` (`skills` array) | `plugins/<name>/.codex-plugin/plugin.json` (`skills` string dir) |
| install eng | `/plugin marketplace add IsaiaScope/ai` then `/plugin install isaiascope-eng@marketonfire` | `codex plugin marketplace add IsaiaScope/ai` then `codex plugin add isaiascope-eng@marketonfire` |
| install social | `/plugin install isaiascope-social@marketonfire` | `codex plugin add isaiascope-social@marketonfire` |

When both manifests are present, each CLI reads only its own path — no conflict. Each Codex plugin globs its own `plugins/<name>/skills/` dir, so the two plugins never see each other's skills.

## Editing Global Agent Instructions

Edit `config/AGENTS.md` — `config/CLAUDE.md` is a symlink to it. Then run
`node scripts/install.js` to deploy both destinations.

## graphify

- When building or rebuilding the full graph (`/graphify`, a bare path, or a whole-tree rebuild), always use `--mode deep` for the most complete knowledge outcome — richest semantic + INFERRED edges. The auto-update git hook and `graphify update .` are AST-only (fast, no LLM) and do NOT refresh semantic edges — so the graph drifts toward code-structure-only between full builds. Re-run `/graphify --mode deep` periodically (and after large doc/concept changes) to restore the deep semantic graph.

When the user types `/graphify`, invoke the skill tool with `skill: "graphify"`
before doing anything else.

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `IsaiaScope/ai`, driven by the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.

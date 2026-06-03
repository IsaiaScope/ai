# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Install / Update

```bash
node scripts/install.js
```

Copies `config/CLAUDE.md` → `~/CLAUDE.md` and `config/AGENTS.md` → `~/.codex/AGENTS.md`, installs upstream skill packs via `npx skills@latest`, and symlinks the local `IsaiaScope/ai` skills directly into both supported agents' skills dirs (Claude-side → `~/.claude/skills/`, Codex-side → `~/.codex/skills/`). No build step, no tests, no package.json.

## Architecture

```
config/
  CLAUDE.md   — global Claude Code instructions (copied to ~/CLAUDE.md on install)
  AGENTS.md   — global Codex instructions (copied to ~/.codex/AGENTS.md on install)
skills/
  iso-ai-init/SKILL.md             — initialize a repo with IsaiaScope AI defaults
  iso-init-repo/SKILL.md           — initialize repo governance (branches, CI, hooks)
  iso-plan/SKILL.md                — planning pipeline orchestrator
  iso-write/SKILL.md               — TDD plan executor on a feature branch, no commits
  iso-spawn/SKILL.md               — spawn a codex/claude agent in a herdr tab
  iso-todo/SKILL.md                — full dev cycle: iso-plan → iso-write → iso-review (no commit)
  iso-readme/SKILL.md              — write/refine READMEs in house style, commit + push
scripts/
  install.js                        — deploys config files + installs skill packs globally
.claude-plugin/
  plugin.json                       — Claude plugin manifest (skills array, regenerated on install)
  marketplace.json                  — Claude marketplace catalog (source "./" → repo-root plugin)
.agents/plugins/
  marketplace.json                  — Codex marketplace catalog (source → ./plugins/isaiascope-ai)
plugins/isaiascope-ai/
  .codex-plugin/plugin.json         — Codex plugin manifest (skills: "./skills/", whole-dir)
  skills → ../../skills             — symlink so the Codex plugin sees the shared skills
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

The skill set is derived from the filesystem: `scripts/install.js` scans `skills/*/SKILL.md`, symlinks each into both agents, and regenerates `.claude-plugin/plugin.json`. There is no list to maintain — a directory with a `SKILL.md` is a skill. Commit the regenerated `plugin.json` diff.

Marketplace manifests need **no** edit when adding a skill: the Codex plugin declares `skills: "./skills/"` (whole-dir, auto-globbed via the `plugins/isaiascope-ai/skills` symlink), and only the Claude `plugin.json` array is regenerated. `install.js` self-heals the Codex symlink on every run.

## Plugin Marketplace

This repo is a native marketplace for both agents (parallel manifests — the two CLIs diverge):

| | Claude Code | Codex |
| --- | --- | --- |
| marketplace manifest | `.claude-plugin/marketplace.json` | `.agents/plugins/marketplace.json` |
| plugin location | repo root (`source: "./"`) | subdir (`source: {source:"local",path:"./plugins/isaiascope-ai"}`) — root is rejected |
| plugin manifest | `.claude-plugin/plugin.json` (`skills` array) | `plugins/isaiascope-ai/.codex-plugin/plugin.json` (`skills` string dir) |
| install | `/plugin marketplace add IsaiaScope/ai` then `/plugin install isaiascope-ai@marketonfire` | `codex plugin marketplace add IsaiaScope/ai` then `codex plugin add isaiascope-ai@marketonfire` |

When both manifests are present, each CLI reads only its own path — no conflict.

## Editing Global Agent Instructions

Edit `config/CLAUDE.md` (Claude Code) or `config/AGENTS.md` (Codex), then run `node scripts/install.js` to deploy.

## graphify

- When building or rebuilding the full graph (`/graphify`, a bare path, or a whole-tree rebuild), always use `--mode deep` for the most complete knowledge outcome — richest semantic + INFERRED edges. The auto-update git hook and `graphify update .` are AST-only (fast, no LLM) and do NOT refresh semantic edges — so the graph drifts toward code-structure-only between full builds. Re-run `/graphify --mode deep` periodically (and after large doc/concept changes) to restore the deep semantic graph.

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

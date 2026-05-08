# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Install / Update

```bash
node scripts/install.js
```

Copies `config/CLAUDE.md` → `~/CLAUDE.md` and `config/AGENTS.md` → `~/.codex/AGENTS.md`, then installs/updates all skill packs via `npx skills@latest`. No build step, no tests, no package.json.

## Architecture

```
config/
  CLAUDE.md   — global Claude Code instructions (copied to ~/CLAUDE.md on install)
  AGENTS.md   — global Codex instructions (copied to ~/.codex/AGENTS.md on install)
skills/
  iso-ai-init/SKILL.md             — initialize a repo with IsaiaScope AI defaults
  iso-init-repo/SKILL.md           — initialize repo governance (branches, CI, hooks)
  iso-implementation/SKILL.md      — Claude-side pipeline orchestrator
  iso-dispatch-to-codex/SKILL.md   — Claude-side thin brief builder for Codex handoff
  iso-codex-implementation/SKILL.md — Codex-side TDD execution protocol
scripts/
  install.js                        — deploys config files + installs skill packs globally
.claude-plugin/
  plugin.json                       — registers this repo as a skills.sh plugin
```

`scripts/install.js` installs these upstream skill packs globally for both `claude-code` and `codex`:
- `juliusbrussee/caveman` — token-compressed communication
- `safishamsi/graphify` — codebase → knowledge graph
- `forrestchang/andrej-karpathy-skills` — LLM coding guidelines
- `mattpocock/skills` — planning/debugging/TDD workflows
- `IsaiaScope/ai` — this repo itself (iso-ai-init skill)

## Adding a Skill

1. Create `skills/<name>/SKILL.md`
2. Register in `.claude-plugin/plugin.json` under `"skills"`
3. Re-run `node scripts/install.js` — the `IsaiaScope/ai` pack entry picks it up automatically

## Editing Global Agent Instructions

Edit `config/CLAUDE.md` (Claude Code) or `config/AGENTS.md` (Codex), then run `node scripts/install.js` to deploy.

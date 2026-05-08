# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Install / Update

```bash
node scripts/install.js
```

Copies `config/CLAUDE.md` → `~/CLAUDE.md` and `config/AGENTS.md` → `~/.codex/AGENTS.md`, installs upstream skill packs via `npx skills@latest`, and symlinks the local `IsaiaScope/ai` skills directly into the right agent's skills dir (Claude-side → `~/.claude/skills/`, Codex-side → `~/.codex/skills/`) so each skill only appears for the agent that needs it. No build step, no tests, no package.json.

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

The local `IsaiaScope/ai` skills are NOT installed via the marketplace pack. They are listed inline in `scripts/install.js` with an explicit per-agent target so each skill is symlinked only into the agent that should see it. Update that list when adding a new skill.

## Adding a Skill

1. Create `skills/<name>/SKILL.md`
2. Register in `.claude-plugin/plugin.json` under `"skills"` (for marketplace discovery)
3. Add an entry to the `localSkills` array in `scripts/install.js` with the right `agent` (`claude-code` or `codex`)
4. Re-run `node scripts/install.js`

## Editing Global Agent Instructions

Edit `config/CLAUDE.md` (Claude Code) or `config/AGENTS.md` (Codex), then run `node scripts/install.js` to deploy.

# IsaiaScope/ai

My personal AI config layer — skills for Claude Code and Codex, agent rules, and `CLAUDE.md` in one place.

## Quickstart

```bash
git clone https://github.com/IsaiaScope/ai.git
cd ai
node install.js
```

This will:
1. Copy `CLAUDE.md` → `~/CLAUDE.md` (always overwrites — repo is source of truth)
2. Install [caveman](https://github.com/juliusbrussee/caveman) globally
3. Install [graphify](https://github.com/safishamsi/graphify) globally
4. Install [notion-notes](#notion-notes) globally
5. Update all global skills to latest versions

Re-run anytime to update.

## Skills

### notion-notes (original)

Creates well-structured Notion pages with dark mode colors, strategic emojis, and consistent hierarchy.

Install standalone:
```bash
npx skills@latest add IsaiaScope/ai
```

### caveman

Ultra-compressed communication mode. Cuts token usage ~75% by dropping filler while keeping full technical accuracy.

Source: [juliusbrussee/caveman](https://github.com/juliusbrussee/caveman)

### graphify

Any input → knowledge graph → clustered communities → HTML + JSON + audit report.

Source: [safishamsi/graphify](https://github.com/safishamsi/graphify)

## CLAUDE.md

The `CLAUDE.md` at the repo root is my personal Claude Code config — applied globally to all projects. Edit here, commit, then re-run `node install.js` to apply.

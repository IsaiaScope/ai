# IsaiaScope/ai

My personal AI config layer — skills for Claude Code and Codex, agent rules, and `CLAUDE.md` in one place.

## Quickstart

```bash
git clone https://github.com/IsaiaScope/ai.git
cd ai
node install.js
```

This will:
1. Copy `CLAUDE.md` → `~/CLAUDE.md` (Claude Code global instructions)
2. Copy `AGENTS.md` → `~/.codex/AGENTS.md` (Codex global instructions)
3. Install [caveman](https://github.com/juliusbrussee/caveman) globally
4. Install [graphify](https://github.com/safishamsi/graphify) globally
5. Install [notion-notes](#notion-notes) globally
6. Update all global skills to latest versions

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

## Config files

| File | Copied to | Agent |
|------|-----------|-------|
| `CLAUDE.md` | `~/CLAUDE.md` | Claude Code |
| `AGENTS.md` | `~/.codex/AGENTS.md` | Codex |

Repo is source of truth. Edit here, commit, re-run `node install.js` to apply.

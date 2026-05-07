<h1 align="center">🦾 IsaiaScope/ai</h1>

<p align="center">
  My personal AI config layer — skills, agent rules, and global context.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-skills-CC785C?logo=anthropic&logoColor=white" alt="Claude Code" />
  <img src="https://img.shields.io/badge/Codex-skills-412991?logo=openai&logoColor=white" alt="Codex" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT" />
</p>

---

## 🚀 Quickstart

[![skills.sh](https://skills.sh/b/IsaiaScope/ai)](https://skills.sh/IsaiaScope/ai)

```bash
git clone https://github.com/IsaiaScope/ai.git
cd ai
node scripts/install.js
```

This will:

1. Copy `CLAUDE.md` → `~/CLAUDE.md` (Claude Code global instructions)
2. Copy `AGENTS.md` → `~/.codex/AGENTS.md` (Codex global instructions)
3. Install [caveman](https://github.com/juliusbrussee/caveman) — Claude Code + Codex
4. Install [graphify](https://github.com/safishamsi/graphify) — Claude Code + Codex
5. Install [karpathy-guidelines](https://github.com/forrestchang/andrej-karpathy-skills) — Claude Code + Codex
6. Install [mattpocock/skills](https://github.com/mattpocock/skills) — Claude Code + Codex
7. Install [notion-notes](#-notion-notes) — Claude Code + Codex
8. Update all global skills to latest versions

Re-run anytime to update.

---

## 🛠️ Skills

### 🧠 notion-notes *(original)*

Creates well-structured Notion pages with dark mode colors, strategic emojis, and consistent hierarchy.

```bash
npx skills@latest add IsaiaScope/ai
```

### 🗿 caveman

Ultra-compressed communication mode. Cuts token usage ~75% by dropping filler while keeping full technical accuracy.

Source: [juliusbrussee/caveman](https://github.com/juliusbrussee/caveman)

### 🕸️ graphify

Any input → knowledge graph → clustered communities → HTML + JSON + audit report.

Source: [safishamsi/graphify](https://github.com/safishamsi/graphify)

### 🎯 karpathy-guidelines

Behavioral guidelines to reduce common LLM coding mistakes, derived from Andrej Karpathy's observations on LLM coding pitfalls.

Source: [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills)

---

## ⚙️ Config Files

| File | Copied to | Agent |
|------|-----------|-------|
| `CLAUDE.md` | `~/CLAUDE.md` | Claude Code |
| `AGENTS.md` | `~/.codex/AGENTS.md` | Codex |

Repo is source of truth. Edit here, commit, re-run `node scripts/install.js` to apply.

---

## 🙏 Credits

- [juliusbrussee](https://github.com/juliusbrussee) — caveman skill
- [safishamsi](https://github.com/safishamsi) — graphify skill
- [forrestchang](https://github.com/forrestchang) — andrej-karpathy-skills

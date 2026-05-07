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

### ⚡ iso-ai-init *(original)*

Initialize any repo with IsaiaScope AI defaults in one command:
- Caveman ultra + shrink MCP + statusline token badge
- Graphify knowledge graph (`graphify .` → `graphify-out/`)
- Husky + commitlint + auto version-bump on every commit (Node.js only, auto-detected)

```
/iso-ai-init
```

→ [Full documentation](skills/iso-ai-init/README.md)

**Dependencies:**

| Tool | Source | Latest |
|------|--------|--------|
| `caveman` | [npm](https://www.npmjs.com/package/caveman) · [GitHub](https://github.com/juliusbrussee/caveman) | `npm info caveman version` |
| `graphify` | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) · [GitHub](https://github.com/safishamsi/graphify) | `pip index versions graphifyy` |
| `husky` | [npm](https://www.npmjs.com/package/husky) · [GitHub](https://github.com/typicode/husky) | `npm info husky version` |
| `@commitlint/cli` | [npm](https://www.npmjs.com/package/@commitlint/cli) · [GitHub](https://github.com/conventional-changelog/commitlint) | `npm info @commitlint/cli version` |

---

### 🏛️ iso-init-repo *(original)*

Wire GitHub repo governance in one command:
- `dev ← test ← prod` branch structure with protection rules
- CI prod-gate workflow — only PRs from `test` merge to `prod`
- Auto version-bump post-commit hook (Node.js only)
- `/deploy-cascade` slash command for Claude Code

```
/iso-init-repo
```

→ [Full documentation](skills/iso-init-repo/README.md)

**Dependencies:**

| Tool | Source | Latest |
|------|--------|--------|
| `gh` (GitHub CLI) | [cli.github.com](https://cli.github.com) · [GitHub](https://github.com/cli/cli) | `gh --version` · [releases](https://github.com/cli/cli/releases) |
| `git` | [git-scm.com](https://git-scm.com) | `git --version` |

---

### 🗿 caveman

Ultra-compressed communication mode. Cuts token usage ~75% by dropping filler while keeping full technical accuracy.

Source: [juliusbrussee/caveman](https://github.com/juliusbrussee/caveman) · [npm](https://www.npmjs.com/package/caveman)

```bash
npm info caveman version   # check latest
npm install -g caveman --all
```

### 🕸️ graphify

Any input → knowledge graph → clustered communities → HTML + JSON + audit report.

Source: [safishamsi/graphify](https://github.com/safishamsi/graphify) · [PyPI: graphifyy](https://pypi.org/project/graphifyy/)

```bash
pip index versions graphifyy   # check latest
uv tool install graphifyy      # install (prefer uv)
# or: pipx install graphifyy
```

### 🎯 karpathy-guidelines

Behavioral guidelines to reduce common LLM coding mistakes, derived from Andrej Karpathy's observations on LLM coding pitfalls.

Source: [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills)

---

## ⚙️ Config Files

| File | Copied to | Agent |
|------|-----------|-------|
| `config/CLAUDE.md` | `~/CLAUDE.md` | Claude Code |
| `config/AGENTS.md` | `~/.codex/AGENTS.md` | Codex |

Repo is source of truth. Edit in `config/`, commit, re-run `node scripts/install.js` to apply.

---

## 🙏 Credits

- [juliusbrussee](https://github.com/juliusbrussee) — caveman skill
- [safishamsi](https://github.com/safishamsi) — graphify skill
- [forrestchang](https://github.com/forrestchang) — andrej-karpathy-skills

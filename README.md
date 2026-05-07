<h1 align="center">🦾 IsaiaScope/ai</h1>

<p align="center">
  My personal AI config layer — skills, agent rules, and global context for Claude Code and Codex.
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

`install.js` does everything in one shot:

1. 📄 Copy `config/CLAUDE.md` → `~/CLAUDE.md` — global Claude Code instructions
2. 📄 Copy `config/AGENTS.md` → `~/.codex/AGENTS.md` — global Codex instructions
3. 🗿 Install [caveman](https://github.com/juliusbrussee/caveman) — token-compressed AI responses
4. 🕸️ Install [graphify](https://github.com/safishamsi/graphify) — codebase knowledge graph
5. 🎯 Install [karpathy-guidelines](https://github.com/forrestchang/andrej-karpathy-skills) — LLM coding guidelines
6. 📦 Install [mattpocock/skills](https://github.com/mattpocock/skills) — planning, debugging, TDD workflows
7. 🔄 Update all global skills to latest versions

Re-run anytime to update.

---

## 🛠️ Skills

### ⚡ iso-ai-init *(original)*

Initialize any repo with IsaiaScope AI defaults in one command — caveman ultra mode, a living knowledge graph, and Husky wired for graphify.

- 🗿 **Caveman ultra** + shrink MCP + statusline showing tokens and cost
- 🕸️ **Graphify** knowledge graph — built on init, updated on every commit
- 🔗 **Husky** post-commit hook to keep the graph current

```
/iso-ai-init
```

→ [Full documentation](skills/iso-ai-init/README.md)

**Dependencies:**

| Tool | Source |
|------|--------|
| `caveman` | [GitHub](https://github.com/juliusbrussee/caveman) |
| `graphify` | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) · [GitHub](https://github.com/safishamsi/graphify) |
| `husky` | [GitHub](https://github.com/typicode/husky) |

---

### 🏛️ iso-init-repo *(original)*

Wire GitHub repo governance in one command — branch structure, protection, CI, conventional commits, and a deploy cascade command.

- 🌿 **`dev ← test ← prod`** branch structure with protection rules
- 🔒 **CI prod-gate** — only PRs from `test` merge to `prod`
- 📝 **Commitlint** — conventional commit enforcement with scope validation
- 📦 **Version bump** — conventional-commit-aware semver, amends same commit
- 🚀 **`/deploy-cascade`** — cascades through the pipeline from any branch except `prod`

```
/iso-init-repo
```

→ [Full documentation](skills/iso-init-repo/README.md)

**Dependencies:**

| Tool | Source |
|------|--------|
| `gh` (GitHub CLI) | [cli.github.com](https://cli.github.com) · [GitHub](https://github.com/cli/cli) |
| `git` | [git-scm.com](https://git-scm.com) |
| `husky` | [GitHub](https://github.com/typicode/husky) |
| `@commitlint/cli` | [GitHub](https://github.com/conventional-changelog/commitlint) |

---

### 🗿 caveman

Ultra-compressed communication mode. Drops filler, keeps all technical substance — cuts token usage ~75% without losing accuracy.

Source: [juliusbrussee/caveman](https://github.com/juliusbrussee/caveman)

```bash
npm install -g caveman --all
```

### 🕸️ graphify

Turns any input into a knowledge graph — clustered communities, HTML visualization, JSON, and an audit report.

Source: [safishamsi/graphify](https://github.com/safishamsi/graphify) · [PyPI: graphifyy](https://pypi.org/project/graphifyy/)

```bash
uv tool install graphifyy   # prefer uv
# or: pipx install graphifyy
```

### 🎯 karpathy-guidelines

Behavioral guidelines derived from Andrej Karpathy's observations on LLM coding pitfalls — reduces common AI coding mistakes.

Source: [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills)

---

## ⚙️ Config Files

Global agent instructions live in `config/` and are deployed by `install.js`:

| File | Deployed to | Agent |
|------|-------------|-------|
| `config/CLAUDE.md` | `~/CLAUDE.md` | Claude Code |
| `config/AGENTS.md` | `~/.codex/AGENTS.md` | Codex |

> Edit in `config/`, commit, re-run `node scripts/install.js` to apply. The repo is the source of truth.

---

## 🙏 Credits

- [juliusbrussee](https://github.com/juliusbrussee) — caveman skill
- [safishamsi](https://github.com/safishamsi) — graphify skill
- [forrestchang](https://github.com/forrestchang) — andrej-karpathy-skills

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

**Original skills** — built here, symlinked into Claude Code *and* Codex on install:

| Skill | One-liner | Trigger |
|-------|-----------|---------|
| ⚡ [iso-ai-init](skills/iso-ai-init/) | Wire a repo with AI defaults — caveman, graphify, statusline | `/iso-ai-init` |
| 🏛️ [iso-init-repo](skills/iso-init-repo/) | GitHub governance — branches, protection, CI, deploy cascade | `/iso-init-repo` |
| 🧭 [iso-plan](skills/iso-plan/) | Raw idea → written implementation plan (no code) | `/iso-plan` |
| ✍️ [iso-write](skills/iso-write/) | Build a plan on a branch with TDD, no commits | `/iso-write <plan>` |
| 🚀 [iso-spawn](skills/iso-spawn/) | Spawn a codex/claude agent in a herdr tab beside you | `/iso-spawn` |

**Upstream packs** — installed globally by `install.js`: [caveman](#-caveman) · [graphify](#-graphify) · [karpathy-guidelines](#-karpathy-guidelines) · [mattpocock/skills](https://github.com/mattpocock/skills).

A natural workflow chains them: **`iso-plan`** writes the plan → **`iso-write`** builds it on a branch → you review and commit → **`iso-init-repo`** governs how it ships.

---

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

### 🧭 iso-plan *(original)*

Turn a raw idea into a written implementation plan — chains four planning skills, then shows a visual summary. **Plans only; nothing is built or committed.**

- 💭 **Brainstorm → grill → (prototype) → write** in one continuous context
- 🎯 **Grilled against your domain model** (`CONTEXT.md` + ADRs), not just vibes
- 📄 **One plan file** under `docs/superpowers/plans/` + a scannable summary card

```
/iso-plan <seed idea>
```

→ [Full documentation](skills/iso-plan/README.md)

**Dependencies:** [`superpowers`](https://github.com/obra/superpowers) (brainstorming, writing-plans) · [`mattpocock/skills`](https://github.com/mattpocock/skills) (grill-with-docs, prototype)

---

### ✍️ iso-write *(original)*

Build a written plan on a fresh feature branch with TDD — then **stop without committing**, so you review the whole diff and commit yourself.

- 🌿 **Auto-branches** from the plan filename (`feat/…`, `fix/…`)
- 🧪 **Red-green-refactor** per task; ticks checkboxes as it goes
- 🛑 **Never commits** — leaves everything staged for your review (Claude *or* Codex)

```
/iso-write <plan_path>
```

→ [Full documentation](skills/iso-write/README.md)

**Dependencies:** `git` · [`superpowers`](https://github.com/obra/superpowers) (executing-plans, test-driven-development)

---

### 🚀 iso-spawn *(original)*

Spawn a `codex` or `claude` agent in its own [herdr](https://herdr.dev) tab — same workspace, full permissions, optional auto-running task, delivered in the background.

- 🪟 **Same workspace, own tab** — resolved from your pane, immune to focus drift
- ⚡ **Full perms + auto-run prompt** by default; `--safe` and `--wait` when you want them
- 📂 **Starts in your cwd**, not `~`

```
/iso-spawn
```

→ [Full documentation](skills/iso-spawn/README.md)

**Dependencies:** [`herdr`](https://herdr.dev) · `codex` / `claude` CLIs

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

<h1 align="center">🦾 IsaiaScope/ai</h1>

<p align="center">
  My personal AI config layer — skills, agent rules, and global context for Claude Code and Codex.
</p>

<p align="center">
  <img src="https://shieldcn.dev/badge/Claude_Code-skills-CC785C.svg?logo=anthropic&logoColor=fff&variant=default&size=xs" alt="Claude Code" />
  <img src="https://shieldcn.dev/badge/Codex-skills-412991.svg?logo=ri:SiOpenai&logoColor=fff&variant=default&size=xs" alt="Codex" />
  <img src="https://shieldcn.dev/badge/Shell-scripts-4EAA25.svg?logo=gnubash&logoColor=fff&variant=default&size=xs" alt="Shell" />
  <img src="https://shieldcn.dev/badge/JavaScript-installer-323330.svg?logo=javascript&logoColor=F7DF1E&variant=default&size=xs" alt="JavaScript" />
  <img src="https://shieldcn.dev/badge/Node-runtime-339933.svg?logo=nodedotjs&logoColor=fff&variant=default&size=xs" alt="Node" />
</p>
<p align="center">
  <img src="https://shieldcn.dev/badge/AI-tooling-7C3AED.svg?logo=ri:RiSparkling2Fill&logoColor=fff&variant=default&size=xs&gradient=aurora" alt="AI tooling" />
  <img src="https://shieldcn.dev/badge/status-stable-22C55E.svg?statusDot=true&variant=default&size=xs" alt="status: stable" />
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
7. 🎯 Install [intent-layer](https://github.com/crafter-station/skills/tree/main/context-engineering/intent-layer) — hierarchical AGENTS.md context engineering
8. 🔄 Update all global skills to latest versions

Re-run anytime to update.

### Or install as a plugin marketplace

This repo is also a native **plugin marketplace** for both agents — install just the IsaiaScope skills, no global config changes:

```bash
# Claude Code
/plugin marketplace add IsaiaScope/ai
/plugin install isaiascope-ai@marketonfire

# Codex
codex plugin marketplace add IsaiaScope/ai
codex plugin add isaiascope-ai@marketonfire
```

> The marketplace path installs the `isaiascope-ai` skills only. `install.js` is the superset path — it *also* copies `CLAUDE.md`/`AGENTS.md` and installs the upstream packs (caveman, graphify, …).

---

## ✨ Features

- **Original workflow skills** for planning, implementation, review, README polish, repo setup, and AI-tooling setup.
- **One-command installer** that keeps Claude Code and Codex global instructions plus shared skills in sync.
- **Graph-aware defaults** so codebase questions prefer the local knowledge graph before broad source search.
- **Composable cycle** from `/iso-plan` to `/iso-write` to `/iso-review`, with `/iso-todo` as the umbrella path.

---

## 🛠️ Skills

**Original skills** — built here, symlinked into Claude Code *and* Codex on install:

<table>
  <thead>
    <tr>
      <th>Skill</th>
      <th>One-liner</th>
      <th>Trigger</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td nowrap>⚡ <a href="skills/iso-ai-init/">iso‑ai‑init</a></td>
      <td>Wire a repo with AI defaults — caveman, graphify, statusline</td>
      <td nowrap><code>/iso‑ai‑init</code></td>
    </tr>
    <tr>
      <td nowrap>🏛️ <a href="skills/iso-init-repo/">iso‑init‑repo</a></td>
      <td>GitHub governance — branches, protection, CI, deploy cascade</td>
      <td nowrap><code>/iso‑init‑repo</code></td>
    </tr>
    <tr>
      <td nowrap>🧭 <a href="skills/iso-plan/">iso‑plan</a></td>
      <td>Raw idea → written implementation plan (no code)</td>
      <td nowrap><code>/iso‑plan</code></td>
    </tr>
    <tr>
      <td nowrap>✍️ <a href="skills/iso-write/">iso‑write</a></td>
      <td>Build a plan with TDD (branch/in-place/worktree), no commits</td>
      <td nowrap><code>/iso‑write</code></td>
    </tr>
    <tr>
      <td nowrap>🚀 <a href="skills/iso-spawn/">iso‑spawn</a></td>
      <td>Spawn a codex/claude agent in a herdr tab beside you</td>
      <td nowrap><code>/iso‑spawn</code></td>
    </tr>
    <tr>
      <td nowrap>🧵 <a href="skills/iso-todo/">iso‑todo</a></td>
      <td>Plan → write → review in one hands-off development cycle</td>
      <td nowrap><code>/iso‑todo</code></td>
    </tr>
    <tr>
      <td nowrap>🔍 <a href="skills/iso-review/">iso‑review</a></td>
      <td>Review your uncommitted diff — Codex-only or codex + claude, fixes applied</td>
      <td nowrap><code>/iso‑review</code></td>
    </tr>
    <tr>
      <td nowrap>📝 <a href="skills/iso-readme/">iso‑readme</a></td>
      <td>Write/refine any README in the house style, commit + push</td>
      <td nowrap><code>/iso‑readme</code></td>
    </tr>
  </tbody>
</table>

**Upstream packs** — installed globally by `install.js`: [caveman](#-caveman) · [graphify](#-graphify) · [karpathy-guidelines](#-karpathy-guidelines) · [mattpocock/skills](https://github.com/mattpocock/skills) · [intent-layer](#-intent-layer).

A natural workflow chains them: **`iso-plan`** writes the plan → **`iso-write`** builds it on a branch → **`iso-review`** double-checks the diff with Codex-only or dual-agent review → you commit → **`iso-init-repo`** governs how it ships. **`iso-todo`** runs the plan/write/review sequence as one orchestrated cycle and still commits nothing.

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

Build a written plan with TDD in the workspace mode you pick — then **stop without committing**, so you review the whole diff and commit yourself.

- 🗂️ **Four workspace modes:** fresh branch (default), current branch (`--no-branch`), named branch (`--branch=<name>`), or isolated worktree (`--worktree`)
- 🌿 **Auto-branches** from the plan filename (`feat/…`, `fix/…`) in default/worktree modes
- 🧪 **Red-green-refactor** per task; ticks checkboxes as it goes
- 🛑 **Never commits** — leaves everything staged for your review (Claude *or* Codex)

```
/iso-write <plan_path> [--no-branch | --branch=<name> | --worktree]
```

→ [Full documentation](skills/iso-write/README.md)

**Dependencies:** `git` · [`superpowers`](https://github.com/obra/superpowers) (executing-plans, test-driven-development, using-git-worktrees)

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

### 🧵 iso-todo *(original)*

Run a full development cycle — plan, implement in a spawned codex tab, review with Codex-only or dual-agent review, and apply accepted fixes back in the implementation tab. **Never commits.**

- 🧭 **Plan first** — delegates to `iso-plan` and stops if no new plan appears
- ✍️ **Write in a live tab** — runs `iso-write` on a fresh `feat/<slug>` branch
- 🔍 **Review after write** — runs `iso-review` with reviewer-tab cleanup and implementation-tab reuse

```
/iso-todo
```

→ [Full documentation](skills/iso-todo/README.md)

**Dependencies:** [`iso‑plan`](skills/iso-plan/) · [`iso‑write`](skills/iso-write/) · [`iso‑review`](skills/iso-review/) · [`iso‑spawn`](skills/iso-spawn/) · `git`

---

### 🔍 iso-review *(original)*

Review your uncommitted working tree with Codex only or with codex `/review` + claude `/code-review` — then apply every fix worth keeping and verify, all without committing.

- 👥 **Reviewer tabs** — codex on the diff, with optional claude pairing unless `--codex-only`
- 🔀 **Merged, de-duplicated, filtered** — keeps everything except net-negative fixes
- 🧪 **Applies + self-verifies** — a codex fix tab runs the repo's tests + type-check and reports
- 🛑 **Never commits** — leaves the working tree for your final read

```
/iso-review [--codex-only] [--max]
```

→ [Full documentation](skills/iso-review/README.md)

**Dependencies:** [`iso‑spawn`](skills/iso-spawn/) (spawn/drive engine) · [`herdr`](https://herdr.dev) · `codex` / `claude` CLIs · `git`

---

### 📝 iso-readme *(original)*

Write or refine any README in the house style — curated badges, context-aware layout, scannable prose — then commit just the README and push. Global, stack-agnostic.

- 🎨 **Curated badges** — shieldcn (shadcn-styled), 3–6 identity badges, no spam
- 🧱 **Layout by context** — root/app · skill · lib/pkg
- 🔍 **Stack-agnostic** — reads any manifest to derive badges

```
/iso-readme
```

→ [Full documentation](skills/iso-readme/README.md)

**Dependencies:** `git`

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

### 🎯 intent-layer

Sets up hierarchical `AGENTS.md` infrastructure — a root context file plus child `AGENTS.md` in complex subdirectories — so agents navigate a codebase like a senior engineer. Installed as a single skill from a multi-skill pack (`--skill intent-layer`).

Source: [crafter-station/skills · context-engineering/intent-layer](https://github.com/crafter-station/skills/tree/main/context-engineering/intent-layer)

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
- [crafter-station](https://github.com/crafter-station) — intent-layer skill

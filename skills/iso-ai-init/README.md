# ⚡ iso-ai-init

> Wire any repo with IsaiaScope AI defaults in one command — token-compressed responses, a living knowledge graph, and a graphify post-commit hook.

---

## 🧩 What It Does

Runs a three-step setup sequence inside any git repo:

1. **🗿 Caveman** — installs the `caveman` CLI globally, activates ultra mode (tokens ~75% cheaper), registers `caveman-shrink` as a Claude Code MCP, and writes a live statusline showing repo, branch, context %, cost, and mode (`…/repo  main  ctx:75%  $5.82  ULTRA`)

2. **🕸️ Graphify** — installs the `graphify` CLI, wires it into `CLAUDE.md` and Codex so both agents can query the graph, builds the initial knowledge graph (one LLM call), and adds a `post-commit` hook so the graph updates automatically on every commit

3. **🔗 Husky** — initializes Husky and appends a `post-commit` block that runs `graphify update .` after each commit (Node.js repos only; non-Node repos get a native git hook instead)

> 📝 **Commitlint + version bump** live in [`/iso-init-repo`](../iso-init-repo/) (Steps 5–6). Run both skills for the full stack.

---

## ▶️ Trigger

```
/iso-ai-init
```

Or ask: *"set up AI tooling"*, *"init AI defaults"*, *"add graphify and caveman"*

---

## ✅ Output

```
✓ Caveman ultra + shrink MCP + statusline
✓ Graphify skill wired — initial graph built
✓ .husky/post-commit  →  graphify update .
```

> Restart Claude Code after running to activate MCP and hooks.

---

## 🔧 Dependencies

| Tool | Purpose | Source |
|------|---------|--------|
| `caveman` | Token-compressed Claude responses | [GitHub](https://github.com/juliusbrussee/caveman) |
| `caveman-shrink` | Claude Code MCP for browser token savings | Bundled with `caveman --all` |
| `graphify` | Codebase → knowledge graph | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) · [GitHub](https://github.com/safishamsi/graphify) |
| `husky` | Git hooks manager (Node.js repos) | [GitHub](https://github.com/typicode/husky) |

### Install (reference)

```bash
# caveman — global, once per machine
npm install -g caveman --all

# graphify — global, prefer uv
uv tool install graphifyy
# or: pipx install graphifyy

# husky — per repo (pnpm example)
pnpm add -D -w husky
```

---

## 📁 Templates

All config is generated from `templates/` next to this file:

| Template | Writes to | Purpose |
|----------|-----------|---------|
| `caveman-init.sh` | runs globally | installs caveman + registers MCP |
| `caveman-config.json` | `~/.config/caveman/config.json` | sets ultra mode globally |
| `statusline.sh` | `~/.claude/statusline-command.sh` | live token/cost/mode badge |
| `post-commit.sh` | `.husky/post-commit` (appended) | runs `graphify update .` after each commit |

> Edit any template to change default behavior — no SKILL.md change needed.

---

## 🔗 Related

- [`iso-init-repo`](../iso-init-repo/) — GitHub repo governance: branches, protection, CI, commitlint, version bump, deploy cascade
- [`graphify`](../graphify/) — knowledge graph skill (manual invocation via `/graphify`)
- [`caveman`](../caveman/) — caveman mode skill (toggle via `/caveman`)

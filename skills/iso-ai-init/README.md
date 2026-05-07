# iso-ai-init

> Wire a repo with IsaiaScope AI defaults in one command — caveman ultra mode, a living knowledge graph, conventional commits, and auto-versioning.

---

## What It Does

Runs a four-step setup sequence inside any git repo:

1. **Caveman** — installs the `caveman` CLI globally, sets ultra mode, registers `caveman-shrink` as a Claude Code MCP, and writes a live statusline (`…/repo  branch  ctx:75%  $5.82  ULTRA`)
2. **Graphify** — installs the `graphify` CLI, wires it into `CLAUDE.md` and Codex, builds the initial knowledge graph (LLM call), and adds a `post-commit` hook so the graph stays current on every commit
3. **Husky + commitlint** — adds `commit-msg` (lint), `post-commit` (graphify + version bump), and `commitlint.config.js` with scope enforcement
4. **Version bump** — `post-commit-version-bump.sh` reads conventional commit type → bumps `patch`/`minor`/`major`, amends into the same commit; skips merge commits; supports npm, pnpm, yarn, bun

Repos with `package.json` get all four steps. Repos without get steps 1–2 plus a native git hook for graphify.

---

## Trigger

```
/iso-ai-init
```

Or ask: *"set up AI tooling"*, *"init AI defaults"*, *"add graphify and caveman"*

---

## Output

```
✓ Caveman ultra + shrink + statusline
✓ Graphify skill wired (+ initial graph built)
✓ .husky/commit-msg          → commitlint
✓ .husky/post-commit         → graphify update . + version bump
✓ .husky/post-commit-version-bump.sh
✓ commitlint.config.js       → scope required, emoji allowed
```

Restart Claude Code after running to activate hooks.

---

## Commit Format

```
feat(scope): ✨ add thing
fix(scope): 🐛 resolve issue
feat(scope)!: 💥 breaking change
```

Scope is required. Emoji optional but encouraged.

---

## Dependencies

| Tool | Purpose | Source | Latest |
|------|---------|--------|--------|
| `caveman` | Token-compressed Claude responses | [npm](https://www.npmjs.com/package/caveman) | `npm info caveman version` |
| `caveman-shrink` | Claude Code MCP for token savings | Bundled with `caveman --all` | — |
| `graphify` | Codebase knowledge graph | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) | `pip index versions graphifyy` |
| `husky` | Git hooks manager | [npm](https://www.npmjs.com/package/husky) · [GitHub](https://github.com/typicode/husky) | `npm info husky version` |
| `@commitlint/cli` | Commit message linter | [npm](https://www.npmjs.com/package/@commitlint/cli) | `npm info @commitlint/cli version` |
| `@commitlint/config-conventional` | Conventional commits ruleset | [npm](https://www.npmjs.com/package/@commitlint/config-conventional) | `npm info @commitlint/config-conventional version` |

### Install commands (reference)

```bash
# caveman (global, once per machine)
npm install -g caveman --all

# graphify (global, prefer uv)
uv tool install graphifyy
# or: pipx install graphifyy

# Node.js dev deps (pnpm example)
pnpm add -D -w husky @commitlint/cli @commitlint/config-conventional
```

---

## Templates

All config is generated from files in `templates/`:

| Template | Writes to |
|----------|-----------|
| `caveman-init.sh` | runs globally (no per-repo file) |
| `caveman-config.json` | `~/.config/caveman/config.json` |
| `statusline.sh` | `~/.claude/statusline-command.sh` |
| `commit-msg.sh` | `.husky/commit-msg` |
| `post-commit.sh` | `.husky/post-commit` (appended) |
| `commitlint.config.js` | `commitlint.config.js` |

To change any default behavior, edit the template — no SKILL.md change needed.

---

## Related

- [`iso-init-repo`](../iso-init-repo/) — GitHub repo governance (branches, protection, CI, deploy cascade)
- [`graphify`](../graphify/) — knowledge graph skill (manual invocation)
- [`caveman`](../caveman/) — caveman mode skill

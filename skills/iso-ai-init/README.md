# iso-ai-init

> Wire a repo with IsaiaScope AI defaults in one command — caveman ultra mode and a living knowledge graph.

---

## What It Does

Runs a three-step setup sequence inside any git repo:

1. **Caveman** — installs the `caveman` CLI globally, sets ultra mode, registers `caveman-shrink` as a Claude Code MCP, and writes a live statusline (`…/repo  branch  ctx:75%  $5.82  ULTRA`)
2. **Graphify** — installs the `graphify` CLI, wires it into `CLAUDE.md` and Codex, builds the initial knowledge graph (LLM call), and adds a `post-commit` hook so the graph stays current on every commit
3. **Husky** — initializes Husky and wires a `post-commit` hook for graphify

Repos with `package.json` get all three steps. Repos without get steps 1–2 plus a native git hook for graphify.

> Commitlint + version bump live in `/iso-init-repo` (Steps 5–6). Run both skills for the full stack.

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
✓ .husky/post-commit         → graphify update .
```

Restart Claude Code after running to activate hooks.

---

## Dependencies

| Tool | Purpose | Source | Latest |
|------|---------|--------|--------|
| `caveman` | Token-compressed Claude responses | [npm](https://www.npmjs.com/package/caveman) | `npm info caveman version` |
| `caveman-shrink` | Claude Code MCP for token savings | Bundled with `caveman --all` | — |
| `graphify` | Codebase knowledge graph | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) | `pip index versions graphifyy` |
| `husky` | Git hooks manager | [npm](https://www.npmjs.com/package/husky) · [GitHub](https://github.com/typicode/husky) | `npm info husky version` |

### Install commands (reference)

```bash
# caveman (global, once per machine)
npm install -g caveman --all

# graphify (global, prefer uv)
uv tool install graphifyy
# or: pipx install graphifyy

# husky (Node.js repos, pnpm example)
pnpm add -D -w husky
```

---

## Templates

All config is generated from files in `templates/`:

| Template | Writes to |
|----------|-----------|
| `caveman-init.sh` | runs globally (no per-repo file) |
| `caveman-config.json` | `~/.config/caveman/config.json` |
| `statusline.sh` | `~/.claude/statusline-command.sh` |
| `post-commit.sh` | `.husky/post-commit` (appended) |

To change any default behavior, edit the template — no SKILL.md change needed.

---

## Related

- [`iso-init-repo`](../iso-init-repo/) — GitHub repo governance (branches, protection, CI, commitlint, version bump, deploy cascade)
- [`graphify`](../graphify/) — knowledge graph skill (manual invocation)
- [`caveman`](../caveman/) — caveman mode skill

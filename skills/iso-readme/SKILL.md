---
name: iso-readme
description: Write or refine README files in the IsaiaScope house style — curated shields.io badges, context-aware layout (repo root/app · skill · lib/pkg), scannable prose — then commit only the README changes and push. Global, stack-agnostic (node, python, rust, go, docs-only, monorepo). Use when invoked as /iso-readme [path], or asked to write/refine/beautify a README in my style.
---

# iso-readme

Write a fresh README or refine an existing one to the house look defined in [STYLE.md](STYLE.md), then commit **only** the README file(s) and push. Runs in any repo, under Claude Code or Codex.

Read [STYLE.md](STYLE.md) before writing — it is the single source of truth for badges, layout, voice, and writing rules.

## Input

`/iso-readme [path]`

- **path given** — a README file or a directory (use its `README.md`).
- **no arg** — target the repo-root `README.md`. If the repo is a monorepo, offer to also scan subdirs that carry their own manifest (`apps/*`, `packages/*`); do not scan them unprompted.

## Step 1: Detect context

Pick the layout (see STYLE.md "Layouts by context"):

| Signal | Context | Layout |
|--------|---------|--------|
| A `SKILL.md` sits in the same dir, or path is `skills/<name>/README.md` | **skill** | skill layout |
| Repo-root README, or an application dir | **root / app** | centered + badges |
| Manifest declares a published package (name+version, library not app) | **lib / pkg** | lib layout |

Ambiguous → top-level defaults to root/app; a dir with `SKILL.md` is a skill; ask only if still unclear.

## Step 2: Detect stack (stack-agnostic)

Parse whatever manifest exists to derive badge signals:

| Manifest | Stack |
|----------|-------|
| `package.json` | node/TS/JS; frameworks from `dependencies` (next, react, express…) |
| `pyproject.toml` / `setup.py` / `requirements.txt` | python; framework from deps (django, fastapi…) |
| `Cargo.toml` | rust |
| `go.mod` | go |
| `composer.json` | php |
| `Gemfile` | ruby |
| none | docs-only → license badge only (if LICENSE exists), or no badges |

## Step 3: Write or refine

- **README missing → generate fresh** from the matching STYLE.md skeleton.
- **README exists → refine:** preserve all real content (install steps, env vars, credits, commands) — restyle layout + badges only. **Never invent** features or commands.
- Derive badges from Step 2, curate to **3–6 identity badges** (primary lang/runtime · 1–2 defining frameworks · license) using the STYLE.md hex table. Add a missing tech as a new row in STYLE.md.

## Step 4: Commit README-only + push

Stage **only** the README path(s) written this run — never `git add -A`. Unrelated working-tree changes stay untouched.

```bash
git add <each README path written>
git commit -m "docs(readme): <concise summary>"
git push
```

If not a git repo → write the file, skip stage/commit/push, tell the user. If push is denied or there is no remote → report it, leave the commit in place, do not force.

## Stop / edge rules

- Existing README with real content → preserve facts, restyle only.
- Monorepo with no arg → refine root; offer (don't force) subdir scan.
- Badge tech not in hex table → sensible color + add the row.
- Not a git repo → write only, no git.

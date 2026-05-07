---
name: iso-ai-init
description: Initialize a repo with IsaiaScope AI defaults — caveman ultra + shrink, graphify knowledge graph, and Husky + release-it + commitlint (Node.js only). Use when the user runs /iso-ai-init or asks to set up a new repo with AI tooling.
---

# iso-ai-init

Set up a repo with IsaiaScope AI defaults. Run from inside the target repo.

All config templates live in `templates/` next to this file — Read each one, then Write it to the target path.

## Step 0 — Detect package manager

```bash
if [ -f pnpm-lock.yaml ]; then echo "pnpm"
elif [ -f yarn.lock ]; then echo "yarn"
elif [ -f bun.lockb ] || [ -f bun.lock ]; then echo "bun"
else echo "npm"; fi
```

| PM | Install flags | Workspace flag |
|----|--------------|----------------|
| pnpm | `add -D` | `-w` |
| yarn | `add -D` | `-W` |
| bun | `add -d` | — |
| npm | `install --save-dev` | — |

## Step 1 — Caveman

All caveman setup lives in `templates/caveman-init.sh` + `templates/caveman-config.json`.

Read `templates/caveman-init.sh` and execute it from inside the repo:

```bash
bash ~/.claude/skills/iso-ai-init/templates/caveman-init.sh
```

The script handles all three sub-steps:
- **1a** check if `caveman` installed globally — install with `--all` only if missing (no per-repo install needed)
- **1b** write `templates/caveman-config.json` → `~/.config/caveman/config.json` (sets `ultra` globally)
- **1c** check if `caveman-shrink` already registered in `~/.claude.json`; if not, print the command to add it with an upstream — **do not register blindly without an upstream**

### 1d — Statusline

Read `templates/statusline.sh` → write to `~/.claude/statusline-command.sh`.

Wire in `~/.claude/settings.json` if not already set:
```json
"statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }
```

Check first — do not overwrite an existing `statusLine` config without confirming with the user.

Statusline shows: `…/repo/dir   branch   ctx:75%   $5.82   ULTRA`
- ctx% red at ≥ 90% usage (actual danger zone), magenta below
- `ULTRA` → caveman mode; switches to token savings after `/caveman-stats`

## Step 2 — Graphify

```bash
# check installed
command -v graphify 2>/dev/null || echo "not installed"

# install if missing (prefer uv, fall back to pipx)
uv tool install graphifyy || pipx install graphifyy

# wire skill (always run)
graphify install                      # Claude Code
graphify install --platform codex     # Codex
```

**Initial graph requires LLM — invoke via Skill tool:**
```
Skill("graphify")   # pass repo root as input
```

`graphify update .` = AST-only rebuild (no LLM) — used in hooks and scripts.

Add `graphify-out/` to `.gitignore` if missing.

## Step 3 — Node.js tooling

Skip if no `package.json`.

### 3a — Audit existing setup

```bash
[ -d .husky ] && ls .husky/ || echo "no .husky"
grep -E '"husky"|"release-it"|"@commitlint"' package.json
```

Do not overwrite existing hooks without checking content first.

### 3b — Install deps

pnpm: `pnpm add -D -w husky release-it @release-it/conventional-changelog @commitlint/cli @commitlint/config-conventional`
npm:  `npm install --save-dev husky release-it @release-it/conventional-changelog @commitlint/cli @commitlint/config-conventional`

### 3c — Init Husky (only if `.husky/` missing)

```bash
npx husky init
```

### 3d — Write hooks from templates

Read `templates/commit-msg.sh` → write to `.husky/commit-msg`, chmod +x. The hook detects the package manager at runtime — no substitution needed.
Read `templates/post-commit.sh`     → write to `.husky/post-commit` (or append graphify block if file exists), chmod +x.

### 3e — Write configs from templates

Read `templates/commitlint.config.js` → write to `commitlint.config.js`.

**Before enabling `scope-enum`**, audit all scopes already in git history — enabling it without this step will block existing commits:

```bash
git log --oneline | sed -n 's/[^(]*(\([^)]*\)).*/\1/p' | sort -u
```

Only uncomment `scope-enum` if the repo has a clean, consistent scope set. Populate it with the union of:
- all scopes found in git history above
- names from `ls apps/ packages/`
- cross-cutting: `ci`, `deps`, `docs`, `release`, `repo`

If history has free-text scopes (spaces, commas, arbitrary strings) — leave `scope-enum` commented. `scope-empty` alone is sufficient.

Read `templates/release-it.json` → write to `.release-it.json`.

### 3f — Add missing scripts to `package.json`

Only add if not already present:
- `"prepare": "husky"`
- `"release": "release-it"`
- `"graphify": "graphify update ."`

## Step 4 — Summary

```
✓ Caveman ultra + shrink + statusline (--all)
✓ Graphify skill wired — run /graphify to generate initial graph
✓ Husky + release-it + commitlint   [or: skipped — non-Node repo]
  ├── .husky/commit-msg   → auto-detects PM (pnpm/bun/yarn/npm)
  ├── .husky/post-commit  → graphify update .
  └── commitlint: scope required, emoji allowed, scope-enum: [list]
```

Commit format:
- `fix(italian): 🐛 resolve piva validation` → patch
- `feat(dashboard): ✨ add usage chart` → minor
- `feat(api-core)!: 💥 remove legacy auth` → major

Remind user: restart Claude Code to activate hooks.

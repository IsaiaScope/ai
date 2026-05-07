---
name: iso-ai-init
description: Initialize a repo with IsaiaScope AI defaults — caveman ultra + shrink, graphify knowledge graph, and Husky (graphify post-commit hook). Use when the user runs /iso-ai-init or asks to set up a new repo with AI tooling.
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

Read `templates/caveman-init.sh` and execute it from inside the repo.
Use the skill base directory (where this SKILL.md lives) to resolve the path:

```bash
bash <skill-base-dir>/templates/caveman-init.sh
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
# 2a — install CLI if missing (prefer uv, fall back to pipx)
if ! command -v graphify 2>/dev/null; then
  uv tool install graphifyy || pipx install graphifyy
else
  echo "graphify: already installed, skipping"
fi

# 2b — wire skill (graphify install is idempotent, but check first to avoid noise)
grep -q "## graphify" CLAUDE.md 2>/dev/null \
  && echo "graphify: CLAUDE.md block already present, skipping install" \
  || { graphify install; graphify install --platform codex; }

# 2c — add graphify-out/ to .gitignore if missing
grep -q "graphify-out" .gitignore 2>/dev/null \
  || echo "graphify-out/" >> .gitignore
```

**2d — Initial graph (requires LLM):** check first:
```bash
[ -f graphify-out/graph.json ] \
  && echo "graphify: graph.json exists — run graphify update . to refresh (no LLM)" \
  || echo "graphify: no graph found — need to build"
```

If graph missing → invoke via Skill tool:
```
Skill("graphify")   # pass repo root as input
```

If graph exists → skip LLM build. Optionally run `graphify update .` (AST-only, no cost).

**2e — Non-Node repos: native git post-commit hook**

Skip if `package.json` exists (Husky handles it in Step 3).

```bash
if [ ! -f package.json ]; then
  if grep -q "graphify-hook-start" .git/hooks/post-commit 2>/dev/null; then
    echo "graphify: post-commit hook already installed, skipping"
  else
    graphify hook install
  fi
fi
```

## Step 3 — Node.js tooling

Skip if no `package.json`.

### 3a — Audit existing setup

```bash
[ -d .husky ] && ls .husky/ || echo "no .husky"
grep '"husky"' package.json
```

Do not overwrite existing hooks without checking content first.

### 3b — Install husky

Only if not already in `package.json`:

```bash
pnpm add -D -w husky   # pnpm
yarn add -D -W husky   # yarn
bun add -d husky       # bun
npm install --save-dev husky  # npm
```

### 3c — Init Husky (only if `.husky/` missing)

```bash
[ -d .husky ] || npx husky init
```

### 3d — post-commit graphify block

```bash
grep -q "graphify-hook-start" .husky/post-commit 2>/dev/null \
  && echo "post-commit: graphify block already present, skipping" \
  || { cat templates/post-commit.sh >> .husky/post-commit && chmod +x .husky/post-commit; }
```

Commitlint is owned by `/iso-init-repo` (Step 5). Do not wire it here.

### 3e — Add missing scripts to `package.json`

Only add if not already present:
- `"prepare": "husky"`
- `"graphify": "graphify update ."`

## Step 4 — Summary

```
✓ Caveman ultra + shrink + statusline (--all)
✓ Graphify skill wired — run /graphify to generate initial graph (skipped if graph.json exists)
✓ Husky   [Node repo]
  └── .husky/post-commit  → graphify update .
✓ git post-commit hook   [non-Node repo — graphify hook install]
```

Commitlint + version bump: run /iso-init-repo (Steps 5–6).

Remind user: restart Claude Code to activate hooks.

---
name: iso-ai-init
description: Initialize a repo with IsaiaScope AI defaults — caveman ultra + shrink, graphify knowledge graph, and Husky + release-it + commitlint (Node.js only). Use when the user runs /iso-ai-init or asks to set up a new repo with AI tooling.
---

# iso-ai-init

Set up a repo with IsaiaScope AI defaults. Run from inside the target repo.

## Steps

### 1. Caveman — ultra + shrink + statusline + per-repo rules

Run the caveman installer with `--all` to enable ultra mode, caveman-shrink MCP middleware, statusline token badge, and per-repo auto-start rules:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh) --all
```

Confirm it completed. The installer is idempotent — safe to re-run.

### 2. Graphify — knowledge graph

**2a. Check if graphify is installed:**

```bash
which graphify 2>/dev/null || echo "not installed"
```

**2b. If not installed:**

```bash
uv tool install graphifyy && graphify install
```

If `uv` is not available, fall back to:

```bash
pipx install graphifyy && graphify install
```

**2c. If already installed, ensure skill is wired for current agent:**

For Claude Code:
```bash
graphify install
```

For Codex:
```bash
graphify install --platform codex
```

**2d. Generate the initial knowledge graph:**

```bash
graphify .
```

Output lands in `graphify-out/` — `graph.html`, `GRAPH_REPORT.md`, `graph.json`.

Add `graphify-out/` to `.gitignore` if not already present.

**2e. If `package.json` exists, add a graphify script:**

Add to `scripts` in `package.json`:
```json
"graphify": "graphify ."
```

### 3. Husky + release-it + commitlint (Node.js only)

**3a. Auto-detect: check for `package.json`**

```bash
test -f package.json && echo "node" || echo "skip"
```

If `package.json` does not exist, skip this section entirely. Inform the user versioning was skipped (non-Node repo).

**3b. Install dependencies:**

```bash
npm install --save-dev husky release-it @release-it/conventional-changelog @commitlint/cli @commitlint/config-conventional
```

**3c. Init Husky:**

```bash
npx husky init
```

**3d. Add commitlint pre-commit hook:**

Write to `.husky/commit-msg`:
```bash
#!/bin/sh
npx --no-install commitlint --edit "$1"
```

Make it executable:
```bash
chmod +x .husky/commit-msg
```

**3e. Create `commitlint.config.js`:**

```js
module.exports = { extends: ['@commitlint/config-conventional'] };
```

**3f. Create `.release-it.json`:**

```json
{
  "git": {
    "commitMessage": "chore: release v${version}",
    "tagName": "v${version}"
  },
  "github": {
    "release": false
  },
  "plugins": {
    "@release-it/conventional-changelog": {
      "preset": "angular",
      "infile": "CHANGELOG.md"
    }
  }
}
```

**3g. Add release script to `package.json`:**

Add to `scripts`:
```json
"release": "release-it"
```

**3h. Prepare husky:**

Add to `scripts` in `package.json`:
```json
"prepare": "husky"
```

### 4. Summary

Report what was set up:

```
✓ Caveman ultra + shrink + statusline (--all)
✓ Graphify knowledge graph → graphify-out/
✓ Husky + release-it + commitlint   [or: skipped — non-Node repo]
```

Remind user:
- Run `npm run release` to bump version + generate changelog
- Commit format: `fix: ...` (patch), `feat: ...` (minor), `feat!: ...` (major)
- Run `/caveman-stats` once to activate the statusline token badge

# Skill Pre-flight Checks Design

**Date:** 2026-05-07
**Skills affected:** iso-ai-init, iso-init-repo, dispatch-to-codex
**Goal:** Each skill verifies required tools are present before executing steps, auto-installing where possible, and failing fast with clear instructions when auto-install fails.

---

## Shared Pattern

Every tool check follows this structure:

```bash
if ! command -v <tool> &>/dev/null; then
  echo "⚠ <tool> not found — installing..."
  <install command>
  command -v <tool> &>/dev/null \
    || { echo "✗ <tool> install failed. Run manually: <cmd>"; exit 1; }
  echo "✓ <tool> installed"
fi
```

- Check → auto-install → re-verify → fail hard if still missing
- Failure prints exact manual install command and exits — no partial execution
- Tools already present skip silently

---

## iso-ai-init — Pre-flight Section

Add `## Pre-flight` as the first section (before Step 0).

### git
```bash
command -v git &>/dev/null \
  || { echo "✗ git not found. Install Xcode CLI tools: xcode-select --install"; exit 1; }
```
No auto-install — git is foundational; if absent the repo itself can't be trusted.

### uv (primary graphify installer)
```bash
if ! command -v uv &>/dev/null; then
  echo "⚠ uv not found — installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  source "$HOME/.cargo/env" 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"
  command -v uv &>/dev/null \
    || { echo "✗ uv install failed. Run manually: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  echo "✓ uv installed"
fi
```

### pipx (fallback — only checked if uv install fails at Step 2)
Not checked pre-flight. Step 2 already falls back: `uv tool install graphifyy || pipx install graphifyy`. If uv is present and graphify installs, pipx is never needed.

If `uv tool install` fails at runtime, Step 2 attempts `pipx install`. At that point:
```bash
if ! command -v pipx &>/dev/null; then
  brew install pipx 2>/dev/null || pip3 install pipx
  command -v pipx &>/dev/null \
    || { echo "✗ pipx install failed. Run manually: brew install pipx"; exit 1; }
fi
```

### node / npx (Node repos only)
Checked only when `package.json` is present (Step 3 entry guard):
```bash
if [ -f package.json ]; then
  if ! command -v npx &>/dev/null; then
    echo "⚠ node/npx not found — Steps 3 (Husky) will be skipped."
    echo "  Install Node.js: https://nodejs.org or via nvm/fnm"
    SKIP_NODE=1
  fi
fi
```
Warn + set flag rather than fail — non-Node steps (graphify, caveman) can still complete.

---

## iso-init-repo — Pre-flight Section

Extends the existing `## Pre-flight` section (currently only checks `gh auth status` and remote).

### git
Same as iso-ai-init — fail hard, no auto-install.

### gh (GitHub CLI)
```bash
if ! command -v gh &>/dev/null; then
  echo "⚠ gh not found — installing..."
  brew install gh
  command -v gh &>/dev/null \
    || { echo "✗ gh install failed. Run manually: brew install gh"; exit 1; }
  echo "✓ gh installed"
fi
```

### gh authentication
After install check:
```bash
if ! gh auth status &>/dev/null; then
  echo "⚠ gh not authenticated."
  echo "  Run: gh auth login"
  echo "  Then re-run /iso-init-repo"
  exit 1
fi
```
Authentication is interactive — cannot be automated. Skill stops and gives exact command.

### node / npx (Node repos only)
Same pattern as iso-ai-init: warn + `SKIP_NODE=1` flag. Steps 5–6 (commitlint, version-bump) skip if flag set.

---

## dispatch-to-codex — Pre-flight Section

Add `## Pre-flight` before Step 1.

### codex CLI
```bash
if ! command -v codex &>/dev/null; then
  echo "⚠ codex not found — installing..."
  npm install -g @openai/codex
  command -v codex &>/dev/null \
    || { echo "✗ codex install failed. Run manually: npm install -g @openai/codex"; exit 1; }
  echo "✓ codex installed"
fi
```

### python3
```bash
command -v python3 &>/dev/null \
  || { echo "✗ python3 not found. Install: brew install python3"; exit 1; }
```
No auto-install — if python3 is missing the environment is unusual enough to warrant manual fix.

### warp
No pre-flight check needed. Step 5 already has a graceful fallback (print manual command).

---

## Scope Boundaries

- No changes to skill logic, templates, or step order
- Only additions: a `## Pre-flight` section at the top of each affected SKILL.md
- `SKIP_NODE` flag is prose instruction to Claude (not a real shell var across steps) — each Node-conditional step re-checks `[ -f package.json ] && command -v npx`
- Platform assumption: macOS (brew available). Linux fallbacks not in scope.

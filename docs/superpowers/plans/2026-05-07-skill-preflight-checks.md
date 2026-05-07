# Skill Pre-flight Checks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pre-flight tool checks (with auto-install) to iso-ai-init, iso-init-repo, and dispatch-to-codex skill files so they fail fast or self-heal when required tools are missing.

**Architecture:** Each SKILL.md gets a `## Pre-flight` section as the first executable block. Pattern: check tool → auto-install if missing → re-verify → fail hard with exact manual command if still missing. Node/npx checks are conditional (only when `package.json` exists) and warn rather than fail.

**Tech Stack:** Bash (skill code blocks), markdown (SKILL.md format)

---

### Task 1: iso-ai-init — add Pre-flight section

**Files:**
- Modify: `skills/iso-ai-init/SKILL.md` — insert `## Pre-flight` before `## Step 0`

- [ ] **Step 1: Syntax-check the bash blocks**

```bash
bash -n <<'EOF'
command -v git &>/dev/null \
  || { echo "x git not found. Install: xcode-select --install"; exit 1; }
EOF

bash -n <<'EOF'
if ! command -v uv &>/dev/null; then
  echo "uv not found — installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv &>/dev/null \
    || { echo "x uv install failed. Run manually: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  echo "uv installed"
fi
EOF

bash -n <<'EOF'
if [ -f package.json ] && ! command -v npx &>/dev/null; then
  echo "node/npx not found — Husky steps (Step 3) will be skipped."
  echo "Install Node.js: https://nodejs.org or via nvm/fnm"
fi
EOF
```

Expected: no output (all syntax valid).

- [ ] **Step 2: Insert the Pre-flight section**

Open `skills/iso-ai-init/SKILL.md`. Insert the following block immediately before the `## Step 0 — Detect package manager` heading:

```markdown
## Pre-flight

Run these checks before any step. All checks are idempotent — re-running is safe.

### git
```bash
command -v git &>/dev/null \
  || { echo "✗ git not found. Install Xcode CLI tools: xcode-select --install"; exit 1; }
```

### uv (graphify installer)
```bash
if ! command -v uv &>/dev/null; then
  echo "⚠ uv not found — installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv &>/dev/null \
    || { echo "✗ uv install failed. Run manually: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  echo "✓ uv installed"
fi
```

### node / npx (Node repos — Husky)

Only relevant when `package.json` exists. Warns rather than fails — non-Node steps still run.

```bash
if [ -f package.json ] && ! command -v npx &>/dev/null; then
  echo "⚠ node/npx not found — Husky steps (Step 3) will be skipped."
  echo "  Install Node.js: https://nodejs.org or via nvm/fnm"
fi
```

All checks pass → proceed to Step 0.

```

- [ ] **Step 3: Verify section landed**

```bash
grep -n "## Pre-flight" skills/iso-ai-init/SKILL.md
grep -n "## Step 0" skills/iso-ai-init/SKILL.md
```

Expected: Pre-flight line number is lower than Step 0 line number.

- [ ] **Step 4: Commit**

```bash
git add skills/iso-ai-init/SKILL.md
git commit -m "feat(iso-ai-init): add pre-flight tool checks with auto-install"
```

---

### Task 2: iso-init-repo — expand Pre-flight section

**Files:**
- Modify: `skills/iso-init-repo/SKILL.md` — replace existing `## Pre-flight` content

- [ ] **Step 1: Syntax-check the bash blocks**

```bash
bash -n <<'EOF'
command -v git &>/dev/null \
  || { echo "x git not found. Install: xcode-select --install"; exit 1; }
EOF

bash -n <<'EOF'
if ! command -v gh &>/dev/null; then
  echo "gh not found — installing..."
  brew install gh
  command -v gh &>/dev/null \
    || { echo "x gh install failed. Run manually: brew install gh"; exit 1; }
  echo "gh installed"
fi
EOF

bash -n <<'EOF'
if ! gh auth status &>/dev/null; then
  echo "gh not authenticated."
  echo "Run: gh auth login"
  echo "Then re-run /iso-init-repo"
  exit 1
fi
EOF

bash -n <<'EOF'
if [ -f package.json ] && ! command -v npx &>/dev/null; then
  echo "node/npx not found — Steps 5-6 (commitlint, version-bump) will be skipped."
  echo "Install Node.js: https://nodejs.org or via nvm/fnm"
fi
EOF
```

Expected: no output.

- [ ] **Step 2: Replace the existing Pre-flight section**

The current `## Pre-flight` section in `skills/iso-init-repo/SKILL.md` reads:

```markdown
## Pre-flight

```bash
# Verify gh CLI authenticated
gh auth status

# Detect if remote already exists
git remote get-url origin 2>/dev/null || echo "no remote"
```
```

Replace it with:

```markdown
## Pre-flight

Run these checks before any step.

### git
```bash
command -v git &>/dev/null \
  || { echo "✗ git not found. Install Xcode CLI tools: xcode-select --install"; exit 1; }
```

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

Authentication is interactive — cannot be automated. If not authenticated, stop and run the login command manually.

```bash
if ! gh auth status &>/dev/null; then
  echo "⚠ gh not authenticated."
  echo "  Run: gh auth login"
  echo "  Then re-run /iso-init-repo"
  exit 1
fi
```

### Remote detection
```bash
git remote get-url origin 2>/dev/null || echo "no remote"
```

### node / npx (Node repos — commitlint + version-bump)

Only relevant when `package.json` exists. Warns rather than fails — repo/branch steps still run.

```bash
if [ -f package.json ] && ! command -v npx &>/dev/null; then
  echo "⚠ node/npx not found — Steps 5–6 (commitlint, version-bump) will be skipped."
  echo "  Install Node.js: https://nodejs.org or via nvm/fnm"
fi
```

All checks pass → proceed to Step 1.

```

- [ ] **Step 3: Verify section content**

```bash
grep -n "brew install gh" skills/iso-init-repo/SKILL.md
grep -n "gh auth login" skills/iso-init-repo/SKILL.md
grep -n "node/npx" skills/iso-init-repo/SKILL.md
```

Expected: each line found exactly once.

- [ ] **Step 4: Commit**

```bash
git add skills/iso-init-repo/SKILL.md
git commit -m "feat(iso-init-repo): expand pre-flight with gh install and node/npx guard"
```

---

### Task 3: dispatch-to-codex — add Pre-flight section

**Files:**
- Modify: `skills/dispatch-to-codex/SKILL.md` — insert `## Pre-flight` before `## Step 1`

- [ ] **Step 1: Syntax-check the bash blocks**

```bash
bash -n <<'EOF'
command -v python3 &>/dev/null \
  || { echo "x python3 not found. Install: brew install python3"; exit 1; }
EOF

bash -n <<'EOF'
if ! command -v codex &>/dev/null; then
  echo "codex not found — installing..."
  npm install -g @openai/codex
  command -v codex &>/dev/null \
    || { echo "x codex install failed. Run manually: npm install -g @openai/codex"; exit 1; }
  echo "codex installed"
fi
EOF
```

Expected: no output.

- [ ] **Step 2: Insert the Pre-flight section**

Open `skills/dispatch-to-codex/SKILL.md`. Insert the following block immediately before the `## Step 1: Find the Plan` heading:

```markdown
## Pre-flight

Run before Step 1.

### python3 (URL encoding in Step 5)
```bash
command -v python3 &>/dev/null \
  || { echo "✗ python3 not found. Install: brew install python3"; exit 1; }
```

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

Warp is optional — Step 5 already has a graceful fallback if the URL scheme fails.

All checks pass → proceed to Step 1.

```

- [ ] **Step 3: Verify section landed**

```bash
grep -n "## Pre-flight" skills/dispatch-to-codex/SKILL.md
grep -n "## Step 1" skills/dispatch-to-codex/SKILL.md
```

Expected: Pre-flight line number is lower than Step 1 line number.

- [ ] **Step 4: Commit**

```bash
git add skills/dispatch-to-codex/SKILL.md
git commit -m "feat(dispatch-to-codex): add pre-flight checks for python3 and codex CLI"
```

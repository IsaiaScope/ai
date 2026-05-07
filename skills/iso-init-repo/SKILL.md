---
name: iso-init-repo
description: Set up a repo with IsaiaScope governance defaults — GitHub repo creation, prod/test/dev branch structure with protection, prod-gate CI, commitlint, version-bump hook, and /deploy-cascade command. Use when the user runs /iso-init-repo or asks to set up repo governance.
---

# iso-init-repo

Set up GitHub repo governance. Run from inside the target repo.

All templates live in `templates/` next to this file.

## Pre-flight

```bash
# Verify gh CLI authenticated
gh auth status

# Detect if remote already exists
git remote get-url origin 2>/dev/null || echo "no remote"
```

## Step 1 — GitHub repo

### No remote → create

Ask user for repo name (default: current directory name) and visibility (private/public).

```bash
gh repo create <name> --private --source=. --remote=origin --push
```

### Remote exists → verify

```bash
gh repo view
```

Confirm accessible, then continue.

## Step 2 — Branch structure

Target: `dev` (default, daily work) ← `test` (staging) ← `prod` (release)

```bash
ORIGIN=$(git symbolic-ref --short HEAD)   # current default, likely 'main'

# Create prod from current default
git checkout -b prod 2>/dev/null || git checkout prod
git push -u origin prod

# Create test and dev from prod
git checkout -b test prod && git push -u origin test
git checkout -b dev prod && git push -u origin dev

# Set dev as GitHub default branch
gh repo edit --default-branch dev

# Delete original default (main) if it was the starting point
if [ "$ORIGIN" = "main" ]; then
  git push origin --delete main
  git branch -d main
fi
```

Only delete `main` if `prod` was successfully created with full history.

## Step 3 — Branch protection

Requires the branches from Step 2 to exist on origin.

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# prod — PR required, no force push. ci-prod-gate enforces source=test.
gh api "repos/$REPO/branches/prod/protection" --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null
}
EOF

# test — PR required, no force push
gh api "repos/$REPO/branches/test/protection" --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null
}
EOF

# dev — PR required, no force push
gh api "repos/$REPO/branches/dev/protection" --method PUT \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null
}
EOF
```

Branch protection can't restrict PR source branch — that's what `ci-prod-gate.yml` handles.

## Step 4 — GitHub files

Read `templates/ci-prod-gate.yml` → write to `.github/workflows/ci-prod-gate.yml`.

```bash
git checkout dev
git add .github/
git commit -m "chore(repo): add prod-gate workflow"
git push origin dev
```

## Step 5 — Commitlint

Skip if no `package.json`.

### 5a — Package manager

```bash
if [ -f pnpm-lock.yaml ]; then echo "pnpm"
elif [ -f yarn.lock ]; then echo "yarn"
elif [ -f bun.lockb ] || [ -f bun.lock ]; then echo "bun"
else echo "npm"; fi
```

### 5b — Init Husky (only if `.husky/` missing)

```bash
[ -d .husky ] || npx husky init
```

### 5c — Install deps

Only install packages not already in `package.json`. Skip any already present.

```bash
pnpm add -D -w @commitlint/cli @commitlint/config-conventional   # pnpm
yarn add -D -W @commitlint/cli @commitlint/config-conventional   # yarn
bun add -d @commitlint/cli @commitlint/config-conventional       # bun
npm install --save-dev @commitlint/cli @commitlint/config-conventional  # npm
```

Also ensure `"prepare": "husky"` is in `package.json` scripts if missing.

### 5d — commit-msg hook

Read `templates/commit-msg.sh` → write to `.husky/commit-msg`, chmod +x.

Guard:
```bash
grep -q "commitlint" .husky/commit-msg 2>/dev/null \
  && echo "commit-msg: already configured, skipping" \
  || { cat templates/commit-msg.sh > .husky/commit-msg && chmod +x .husky/commit-msg; }
```

### 5e — commitlint.config.js

Check before writing:
```bash
[ -f commitlint.config.js ] \
  && echo "commitlint.config.js: already exists, skipping — review manually if needed" \
  || cp templates/commitlint.config.js commitlint.config.js
```

**Before enabling `scope-enum`**, audit all scopes in git history:
```bash
git log --oneline | sed -n 's/[^(]*(\([^)]*\)).*/\1/p' | sort -u
```

Only uncomment `scope-enum` if the repo has clean, consistent scopes. Populate from:
- scopes found above
- names from `ls apps/ packages/`
- cross-cutting: `ci`, `deps`, `docs`, `repo`

If history has free-text scopes — leave `scope-enum` commented. `scope-empty` alone is sufficient.

Commit:
```bash
git add .husky/ commitlint.config.js package.json
git commit -m "chore(repo): add commitlint"
git push origin dev
```

## Step 6 — Version bump hook

Skip if no `package.json`.

Read `templates/post-commit-version-bump.sh` → write to `.husky/post-commit-version-bump.sh`, chmod +x.

If `.husky/post-commit` exists, append; otherwise create:

```bash
bash "$(dirname "$0")/post-commit-version-bump.sh"
```

Commit:
```bash
git add .husky/
git commit -m "chore(repo): add version-bump post-commit hook"
git push origin dev
```

## Step 8 — Deploy cascade command

Read `templates/deploy-cascade-command.md` → write to `.claude/commands/deploy-cascade.md`.

This gives the repo a `/deploy-cascade` command. Uses caveman skill for all output. Starting point is auto-detected from current branch — runnable from any branch except `prod`.

```bash
mkdir -p .claude/commands
git add .claude/commands/deploy-cascade.md
git commit -m "chore(repo): add /deploy-cascade command"
git push origin dev
```

## Step 9 — Summary

```
✓ GitHub repo created/configured
✓ Branches: dev (default) ← test ← prod
✓ Protection: PR required on dev, test, prod (no direct push)
✓ .github/workflows/ci-prod-gate.yml       — prod accepts PRs from test only
✓ .husky/commit-msg + commitlint.config.js [or: skipped — no package.json]
✓ .husky/post-commit-version-bump.sh       [or: skipped — no package.json]
✓ .claude/commands/deploy-cascade.md       — /deploy-cascade command
```

Cascade: `<any branch> → dev → test → prod`
`/deploy-cascade` auto-detects starting point — run from any branch except `prod`. Uses caveman skill.
Prod-gate: PRs to `prod` from any branch other than `test` fail CI automatically.

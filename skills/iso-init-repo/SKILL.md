---
name: iso-init-repo
description: Set up a repo with IsaiaScope governance defaults — GitHub repo creation, prod/test/dev branch structure with protection, PR template, prod-gate CI, version-bump hook, and /deploy cascade command. Use when the user runs /iso-init-repo or asks to set up repo governance.
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

## Step 5 — Version bump hook

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

## Step 6 — Deploy cascade command

Read `templates/deploy-cascade-command.md` → write to `.claude/commands/deploy-cascade.md`.

This gives the repo a `/deploy-cascade` command. Uses caveman skill for all output. Starting point is auto-detected from current branch — runnable from any branch except `prod`.

```bash
mkdir -p .claude/commands
git add .claude/commands/deploy-cascade.md
git commit -m "chore(repo): add /deploy-cascade command"
git push origin dev
```

## Step 7 — Summary

```
✓ GitHub repo created/configured
✓ Branches: dev (default) ← test ← prod
✓ Protection: PR required on dev, test, prod (no direct push)
✓ .github/workflows/ci-prod-gate.yml       — prod accepts PRs from test only
✓ .husky/post-commit-version-bump.sh       [or: skipped — no package.json]
✓ .claude/commands/deploy-cascade.md       — /deploy-cascade command
```

Cascade: `<any branch> → dev → test → prod`
`/deploy-cascade` auto-detects starting point — run from any branch except `prod`. Uses caveman skill.
Prod-gate: PRs to `prod` from any branch other than `test` fail CI automatically.

---
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git fetch:*), Bash(git checkout:*), Bash(gh pr:*), Bash(gh run:*), Bash(gh auth:*), Bash(cat:*), AskUserQuestion
description: Cascade to target env. Auto-detects start from current branch. /deploy-cascade [dev|test|prod]
---

# /deploy-cascade

Invoke the caveman skill immediately: `Skill("caveman")`. All status output and reports use caveman ultra style.

```
/deploy-cascade          # → prod
/deploy-cascade dev      # → dev (stop)
/deploy-cascade test     # → test (stop)
```

## Pre-flight

```bash
BRANCH=$(git branch --show-current)
TARGET=${1:-prod}
gh auth status
git fetch origin
```

Starting step by current branch:
- `prod` → refuse (protected; never deploy from prod)
- `test` → Step 3 only; refuse if target dev/test
- `dev` → Step 2+; refuse if target dev
- any other branch → Step 1+

Uncommitted changes on feature branch: stage + commit (derive conventional message from diff, check `commitlint.config.js` for scope rules if present), push.

## Commit/PR message rules

Before generating any title or message:

```bash
[ -f commitlint.config.js ] && cat commitlint.config.js
```

- If `scope-enum` enabled → use only listed scopes
- If `scope-empty: never` → scope required
- Cascade PRs: use `chore(cascade):` or `chore:` depending on scope rules above
- Feature PRs: derive `<type>(<scope>):` from branch commits

## Step 1 — feature → dev

```bash
gh pr list --head "$BRANCH" --base dev --json number --jq '.[0].number'
```

Reuse existing PR if found. Else create — title from branch commits, body = commit log only:

```bash
gh pr create --base dev --head "$BRANCH" \
  --title "<type>(<scope>): <derived from commits>" \
  --body "$(git log origin/dev.."$BRANCH" --oneline)"
```

```bash
gh pr checks <number> --watch
gh pr merge <number> --merge --delete-branch
```

Stop if target `dev`.

## Step 2 — dev → test

```bash
git fetch origin
gh pr list --head dev --base test --json number --jq '.[0].number'
```

Reuse if found. Else:

```bash
gh pr create --base test --head dev \
  --title "chore(cascade): dev → test" \
  --body "$(git log origin/test..origin/dev --oneline)"
```

```bash
gh pr checks <number> --watch
gh pr merge <number> --merge
```

Stop if target `test`.

## Step 3 — test → prod

```bash
git fetch origin
gh pr list --head test --base prod --json number --jq '.[0].number'
```

Reuse if found. Else:

```bash
gh pr create --base prod --head test \
  --title "chore(cascade): test → prod" \
  --body "$(git log origin/prod..origin/test --oneline)"
```

```bash
gh pr checks <number> --watch
gh pr merge <number> --merge
```

Report: URLs of all created/merged PRs.

## Failure

```bash
gh pr checks <number>
gh run list --branch <branch> --status failure --limit 1
gh run view <run-id> --log-failed
```

Report: job, error, fix. Stop. User re-runs.

## Constraints

- No force-push, no destructive ops
- `prod` ← `test` only (prod-gate enforces)
- Never skip CI
- Runnable from any branch except `prod`; on `prod`: refuse immediately

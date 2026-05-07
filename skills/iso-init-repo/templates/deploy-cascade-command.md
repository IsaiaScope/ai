---
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git fetch:*), Bash(git checkout:*), Bash(gh pr:*), Bash(gh run:*), Bash(gh auth:*), AskUserQuestion
description: Cascade to a target environment. Auto-detects starting point from current branch. /deploy-cascade [dev|test|prod]
---

# /deploy-cascade

Promote to a target environment. Starting point is auto-detected from current branch.

## Invocation

```
/deploy-cascade          # cascade from current branch → prod
/deploy-cascade dev      # cascade from current branch → dev (stop)
/deploy-cascade test     # cascade from current branch → test (stop)
/deploy-cascade prod     # cascade from current branch → prod (explicit)
```

## Pre-flight

```bash
BRANCH=$(git branch --show-current)
gh auth status
git status --porcelain
```

1. Parse target from args — default: `prod`
2. Detect starting step from current branch:
   - On `prod` → refuse (already at destination)
   - On `test` → start at Step 3 (test → prod); refuse if target is `dev` or `test`
   - On `dev` → start at Step 2 (dev → test → ...); refuse if target is `dev`
   - On any other branch → start at Step 1 (feature → dev → test → prod)
3. If on a feature branch with uncommitted changes: stage + commit (ask user for message or generate from diff), then push

## Step 1 — feature → dev

*Skip if starting from `dev` or `test`.*

```bash
gh pr list --head "$BRANCH" --base dev --json number,url --jq '.[0]'
```

If no PR, create:

```bash
gh pr create --base dev --head "$BRANCH" \
  --title "<type>(<scope>): <summary from commits>" \
  --body "$(cat <<'EOF'
## Summary
[Generated from branch commits — what changed and why]

## Technical Details
[Files changed, grouped by domain. Key decisions.]

## Testing
CI pipeline: all checks must pass before merge.
EOF
)"
```

Poll: `gh pr checks <number> --watch`
Pass: `gh pr merge <number> --merge --delete-branch`
Fail: diagnose (see Failure Handling), stop.

**Stop here if target is `dev`.**

## Step 2 — dev → test

*Skip if starting from `test`.*

```bash
git fetch origin
gh pr list --head dev --base test --json number --jq '.[0].number'
```

If no PR, create:

```bash
gh pr create --base test --head dev \
  --title "chore(cascade): promote dev to test" \
  --body "$(cat <<'EOF'
## Summary
Promotes dev to test.

### Changes
$(git log origin/test..origin/dev --oneline)
EOF
)"
```

Poll CI, merge on pass.
**Stop here if target is `test`.**

## Step 3 — test → prod

```bash
git fetch origin
gh pr list --head test --base prod --json number --jq '.[0].number'
```

If no PR, create:

```bash
gh pr create --base prod --head test \
  --title "chore(cascade): promote test to prod" \
  --body "$(cat <<'EOF'
## Summary
Promotes test to prod.

### Changes
$(git log origin/prod..origin/test --oneline)
EOF
)"
```

Poll CI (prod-gate verifies source=test), merge on pass.

Report success with links to all created/merged PRs.

## Failure Handling

1. `gh pr checks <number>` — identify which job failed
2. `gh run list --branch <branch> --status failure --limit 1` — get run ID
3. `gh run view <run-id> --log-failed` — read failure logs
4. Report: which job, specific error, suggested fix
5. Stop — user fixes and re-runs `/deploy-cascade`

## Constraints

- Never force-push or use destructive git operations
- Never merge to `prod` from anything other than `test`
- Always wait for CI to pass — never skip checks
- If on `prod`, refuse and explain

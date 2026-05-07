---
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git branch:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git fetch:*), Bash(git checkout:*), Bash(gh pr:*), Bash(gh run:*), Bash(gh auth:*), AskUserQuestion
description: Deploy current feature branch through the cascade — feature → dev → test → prod. Pass a target to stop early (e.g. /deploy dev).
---

# /deploy

Cascade the current feature branch to a target environment.

## Invocation

```
/deploy          # full cascade → prod
/deploy dev      # feature → dev only
/deploy test     # feature → dev → test
/deploy prod     # full cascade (same as no arg)
```

## Pre-flight

1. Get current branch: `git branch --show-current`
2. Refuse if already on `dev`, `test`, or `prod` — only feature branches deploy
3. Verify gh CLI: `gh auth status`
4. Parse target from args (default: `prod`)
5. Check for uncommitted changes: `git status --porcelain`

## Step 1 — Commit & push feature branch

If uncommitted changes exist: stage and commit (ask user for message or generate from diff).
If clean but unpushed: push.
If no remote tracking: `git push -u origin <branch>`.

## Step 2 — feature → dev

```bash
# Check for existing PR
gh pr list --head <branch> --base dev --json number,url --jq '.[0]'
```

If no PR: create one.

```bash
gh pr create --base dev --head <branch> \
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

Poll CI: `gh pr checks <number> --watch`
On pass: `gh pr merge <number> --merge --delete-branch`
On fail: diagnose (see Failure Handling), stop.

**Stop here if target is `dev`.**

## Step 3 — dev → test

```bash
git fetch origin
gh pr create --base test --head dev \
  --title "chore(cascade): promote dev to test" \
  --body "$(cat <<'EOF'
## Summary
Promotes dev to test.

### Changes included
$(git log origin/test..origin/dev --oneline)
EOF
)"
```

Poll CI, merge on pass.
**Stop here if target is `test`.**

## Step 4 — test → prod

```bash
gh pr create --base prod --head test \
  --title "chore(cascade): promote test to prod" \
  --body "$(cat <<'EOF'
## Summary
Promotes test to prod.

### Changes included
$(git log origin/prod..origin/test --oneline)
EOF
)"
```

Poll CI (includes prod-gate verifying source=test), merge on pass.

Report success with links to all created/merged PRs.

## Failure Handling

When any CI check fails:

1. `gh pr checks <number>` — identify which job failed
2. `gh run list --branch <branch> --status failure --limit 1` — get run ID
3. `gh run view <run-id> --log-failed` — read failure logs
4. Report: which job, specific error, suggested fix
5. Stop cascade — user fixes and re-runs `/deploy`

## Constraints

- Never force-push or use destructive git operations
- Never merge to `prod` from anything other than `test`
- Always wait for CI to pass — never skip checks
- If on `dev`/`test`/`prod`, refuse and explain why

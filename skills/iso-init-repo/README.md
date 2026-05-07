# iso-init-repo

> One command to wire GitHub repo governance — branch structure, protection rules, prod-gate CI, and a `/deploy-cascade` command.

---

## What It Does

Runs a six-step setup sequence from inside any git repo:

1. **GitHub repo** — creates a new private/public repo via `gh`, or verifies an existing remote
2. **Branch structure** — creates `prod` ← `test` ← `dev`, sets `dev` as the GitHub default branch, removes `main` if it was the starting point
3. **Branch protection** — PR required on all three branches, no direct push, no force push
4. **CI prod-gate** — `.github/workflows/ci-prod-gate.yml` enforces that PRs to `prod` must come from `test` only (GitHub's branch protection API cannot do this natively)
5. **Version bump hook** — `post-commit-version-bump.sh` auto-bumps `package.json` on every commit (Node.js repos only)
6. **Deploy cascade** — writes `.claude/commands/deploy-cascade.md`, giving the repo a `/deploy-cascade` slash command that auto-detects the starting branch and cascades through the pipeline

---

## Trigger

```
/iso-init-repo
```

Or ask: *"set up repo governance"*, *"create branch structure"*, *"add prod protection"*, *"wire deploy cascade"*

---

## Output

```
✓ GitHub repo created/configured
✓ Branches: dev (default) ← test ← prod
✓ Protection: PR required on dev, test, prod (no direct push)
✓ .github/workflows/ci-prod-gate.yml    — prod accepts PRs from test only
✓ .husky/post-commit-version-bump.sh   [Node only — or: skipped]
✓ .claude/commands/deploy-cascade.md   — /deploy-cascade command
```

---

## Branch Flow

```
feature branches
       ↓  PR
      dev  (daily work, GitHub default)
       ↓  PR
     test  (staging / QA)
       ↓  PR  [ci-prod-gate enforces source = test]
     prod  (release)
```

`/deploy-cascade` auto-detects your current branch and drives the PR chain from wherever you are.

---

## Dependencies

| Tool | Purpose | Source | Latest |
|------|---------|--------|--------|
| `gh` (GitHub CLI) | Repo creation, branch protection, API calls | [cli.github.com](https://cli.github.com) · [GitHub](https://github.com/cli/cli) | `gh --version` or [releases](https://github.com/cli/cli/releases) |
| `git` | Branch creation, remote management | [git-scm.com](https://git-scm.com) | `git --version` |
| `husky` | Git hooks (version bump, optional) | [npm](https://www.npmjs.com/package/husky) · [GitHub](https://github.com/typicode/husky) | `npm info husky version` |

### Install `gh` CLI

```bash
# macOS
brew install gh

# Linux (apt)
sudo apt install gh

# After install, authenticate
gh auth login
```

### Verify before running

```bash
gh auth status        # must be authenticated
git remote -v         # check if a remote already exists
```

---

## Templates

All generated files come from `templates/`:

| Template | Writes to |
|----------|-----------|
| `ci-prod-gate.yml` | `.github/workflows/ci-prod-gate.yml` |
| `post-commit-version-bump.sh` | `.husky/post-commit-version-bump.sh` |
| `deploy-cascade-command.md` | `.claude/commands/deploy-cascade.md` |

To change CI rules or deploy behavior, edit the template — no SKILL.md change needed.

---

## Notes

- Branch protection is set via the GitHub REST API (`gh api`) — requires repo admin access
- `ci-prod-gate.yml` uses `github.event.pull_request.base.ref` and `head.ref` to block non-`test` sources; adjust the workflow if your branch names differ
- Version bump is skipped automatically when no `package.json` is present
- `/deploy-cascade` starting point is inferred from the current branch at runtime

---

## Related

- [`iso-ai-init`](../iso-ai-init/) — AI tooling setup (caveman, graphify, commitlint, version bump)
- [`graphify`](../graphify/) — codebase knowledge graph

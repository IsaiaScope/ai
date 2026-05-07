# iso-init-repo

> One command to wire GitHub repo governance — branch structure, protection rules, prod-gate CI, commitlint, version bump, and a `/deploy-cascade` command.

---

## What It Does

Runs a seven-step setup sequence from inside any git repo:

1. **GitHub repo** — creates a new private/public repo via `gh`, or verifies an existing remote
2. **Branch structure** — creates `prod` ← `test` ← `dev`, sets `dev` as the GitHub default branch, removes `main` if it was the starting point
3. **Branch protection** — PR required on all three branches, no direct push, no force push
4. **CI prod-gate** — `.github/workflows/ci-prod-gate.yml` enforces that PRs to `prod` must come from `test` only (GitHub's branch protection API cannot do this natively)
5. **Commitlint** — installs `@commitlint/cli` + `@commitlint/config-conventional`, wires `commit-msg` hook, writes `commitlint.config.js` with scope enforcement; skipped if no `package.json`
6. **Version bump hook** — `post-commit-version-bump.sh` reads conventional commit type → bumps `patch`/`minor`/`major`, amends into the same commit; skipped if no `package.json`; supports npm, pnpm, yarn, bun
7. **Deploy cascade** — writes `.claude/commands/deploy-cascade.md`, giving the repo a `/deploy-cascade` slash command that uses caveman ultra style, auto-detects the starting branch, and cascades through the pipeline from any branch except `prod`

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
✓ .github/workflows/ci-prod-gate.yml       — prod accepts PRs from test only
✓ .husky/commit-msg + commitlint.config.js [skipped if no package.json]
✓ .husky/post-commit-version-bump.sh       [skipped if no package.json]
✓ .claude/commands/deploy-cascade.md       — /deploy-cascade command
```

---

## Branch Flow

```
any branch (except prod)
       ↓  PR
      dev  (daily work, GitHub default)
       ↓  PR
     test  (staging / QA)
       ↓  PR  [ci-prod-gate enforces source = test]
     prod  (release)
```

`/deploy-cascade` auto-detects your current branch and drives the PR chain from wherever you are — runnable from any branch except `prod`.

---

## Dependencies

| Tool | Purpose | Source |
|------|---------|--------|
| `gh` (GitHub CLI) | Repo creation, branch protection, API calls | [cli.github.com](https://cli.github.com) · [GitHub](https://github.com/cli/cli) |
| `git` | Branch creation, remote management | [git-scm.com](https://git-scm.com) |
| `husky` | Git hooks (commitlint + version bump, optional) | [GitHub](https://github.com/typicode/husky) |
| `@commitlint/cli` | Commit message linter | [GitHub](https://github.com/conventional-changelog/commitlint) |
| `@commitlint/config-conventional` | Conventional commits ruleset | [GitHub](https://github.com/conventional-changelog/commitlint) |

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
| `commit-msg.sh` | `.husky/commit-msg` |
| `commitlint.config.js` | `commitlint.config.js` |
| `post-commit-version-bump.sh` | `.husky/post-commit-version-bump.sh` |
| `deploy-cascade-command.md` | `.claude/commands/deploy-cascade.md` |

To change CI rules or deploy behavior, edit the template — no SKILL.md change needed.

---

## Notes

- Branch protection is set via the GitHub REST API (`gh api`) — requires repo admin access
- `ci-prod-gate.yml` uses `github.event.pull_request.base.ref` and `head.ref` to block non-`test` sources; adjust the workflow if your branch names differ
- Commitlint and version bump are skipped automatically when no `package.json` is present
- `scope-enum` in `commitlint.config.js` is commented out by default — enable only after auditing existing git history scopes
- `/deploy-cascade` starting point is inferred from the current branch at runtime; refuses only on `prod`
- `/deploy-cascade` invokes the caveman skill at start — all output is caveman ultra style

---

## Related

- [`iso-ai-init`](../iso-ai-init/) — AI tooling setup (caveman, graphify, commitlint, version bump)
- [`graphify`](../graphify/) — codebase knowledge graph

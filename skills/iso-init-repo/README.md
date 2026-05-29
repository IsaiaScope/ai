# 🏛️ iso-init-repo

> Wire GitHub repo governance in one command — branch structure, protection rules, CI prod-gate, conventional commits, version bump, and a deploy cascade command.

---

## 🧩 What It Does

Runs a seven-step setup sequence from inside any git repo:

1. **🐙 GitHub repo** — creates a new private/public repo via `gh`, or verifies an existing remote is accessible
2. **🌿 Branch structure** — creates `prod` ← `test` ← `dev`, sets `dev` as the GitHub default branch, removes `main` if it was the starting point
3. **🔒 Branch protection** — PR required on all three branches; no direct push, no force push
4. **🚦 CI prod-gate** — `.github/workflows/ci-prod-gate.yml` enforces that PRs to `prod` must come from `test` only (GitHub's branch protection API can't do this natively — the workflow fills the gap)
5. **📝 Commitlint** — installs `@commitlint/cli` + `@commitlint/config-conventional`, wires a `commit-msg` hook, writes `commitlint.config.js` with scope enforcement; skipped if no `package.json`
6. **📦 Version bump** — `post-commit-version-bump.sh` reads the conventional commit type and bumps `patch` / `minor` / `major`, then amends the commit in place; skips merge commits; supports npm, pnpm, yarn, bun; skipped if no `package.json`
7. **🚀 Deploy cascade** — writes `.claude/commands/deploy-cascade.md`, giving the repo a `/deploy-cascade` slash command that auto-detects the current branch and cascades PRs through the pipeline; uses caveman ultra style for all output; runnable from any branch except `prod`

---

## ▶️ Trigger

```
/iso-init-repo
```

Or ask: *"set up repo governance"*, *"create branch structure"*, *"add prod protection"*, *"wire deploy cascade"*

---

## ✅ Output

```
✓ GitHub repo created/configured
✓ Branches: dev (default) ← test ← prod
✓ Protection: PR required on dev, test, prod — no direct push
✓ .github/workflows/ci-prod-gate.yml       — prod accepts PRs from test only
✓ .husky/commit-msg + commitlint.config.js — [skipped if no package.json]
✓ .husky/post-commit-version-bump.sh       — [skipped if no package.json]
✓ .claude/commands/deploy-cascade.md       — /deploy-cascade command
```

---

### Branch Flow

```
any branch  (feature work, fixes, etc.)
     ↓  PR → CI checks
    dev  (daily work — GitHub default branch)
     ↓  PR → CI checks
   test  (staging / QA)
     ↓  PR → ci-prod-gate enforces source = test
   prod  (release)
```

`/deploy-cascade` detects your current branch and drives the full PR chain automatically. Refuses to run from `prod`.

---

## 🔧 Dependencies

| Tool | Purpose | Source |
|------|---------|--------|
| `gh` (GitHub CLI) | Repo creation, branch protection, API calls | [cli.github.com](https://cli.github.com) · [GitHub](https://github.com/cli/cli) |
| `git` | Branch creation, remote management | [git-scm.com](https://git-scm.com) |
| `husky` | Git hooks — commitlint + version bump (Node.js repos) | [GitHub](https://github.com/typicode/husky) |
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
gh auth status   # must be authenticated
git remote -v    # check if a remote already exists
```

---

### Templates

All generated files come from `templates/` next to this file:

| Template | Writes to | Purpose |
|----------|-----------|---------|
| `ci-prod-gate.yml` | `.github/workflows/ci-prod-gate.yml` | blocks non-test PRs to prod |
| `commit-msg.sh` | `.husky/commit-msg` | runs commitlint on every commit |
| `commitlint.config.js` | `commitlint.config.js` | scope enforcement + emoji rules |
| `post-commit-version-bump.sh` | `.husky/post-commit-version-bump.sh` | semver bump + amend |
| `deploy-cascade-command.md` | `.claude/commands/deploy-cascade.md` | `/deploy-cascade` command |

> Edit any template to change behavior — no SKILL.md change needed.

---

### Notes

- Branch protection requires repo admin access (set via `gh api`)
- `ci-prod-gate.yml` checks `base.ref` and `head.ref`; adjust branch names in the workflow if your naming differs
- Commitlint and version bump are skipped automatically when no `package.json` is present
- `scope-enum` in `commitlint.config.js` is commented out by default — enable only after auditing existing git history scopes with `git log --oneline | sed -n 's/[^(]*(\([^)]*\)).*/\1/p' | sort -u`
- `/deploy-cascade` infers its starting point from the current branch at runtime; refuses only on `prod`
- `/deploy-cascade` invokes the caveman skill at start — all output is caveman ultra style

---

## 🔗 Related

- [`iso‑ai‑init`](../iso-ai-init/) — AI *tooling* setup (caveman, graphify, statusline); pairs with this skill's repo *governance*.
- [`iso‑write`](../iso-write/) — builds reviewed work on the feature branches this governance protects.
- [`graphify`](https://github.com/safishamsi/graphify) — knowledge-graph skill (manual invocation via `/graphify`).

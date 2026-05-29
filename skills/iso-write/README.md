# ✍️ iso-write

> Build a written plan using TDD in the workspace mode you pick — fresh branch, current branch, a named branch, or an isolated worktree — then **stop without committing**, so you review the full diff and commit yourself.

---

## 🧩 What It Does

Takes the plan [`iso‑plan`](../iso-plan/) wrote and implements it, task by task, red-green-refactor. The hard rule that overrides everything else: **it never commits.** Every change is left in the working tree for you to review.

```
1. Read the whole plan end-to-end
2. Resolve the workspace mode → fresh branch (default), current branch, named branch, or worktree
3. Execute each task with TDD   (write failing test → minimal code → pass)
4. Tick each checkbox in the plan as tasks finish
5. Stamp the plan "implemented (uncommitted)"
6. Print the diff stat and HALT — no commit, no PR
```

A dirty working tree is fine. The branch-switching modes (default, `--branch=<name>`) stash uncommitted work and carry it onto the target branch; `--no-branch` leaves it in place; `--worktree` leaves it in the main checkout and starts the worktree clean.

It works the same whether driven by **Claude Code or Codex** — agent-independent.

---

## ▶️ Trigger

```
/iso-write <plan_path> [--no-branch | --branch=<name> | --worktree]
```

Example: `/iso-write docs/superpowers/plans/2026-05-26-feat-thing.md`

The path is required. Missing file → it halts immediately. Passing more than one workspace flag → it halts (`pick one workspace mode`).

---

### Workspace Modes

| Flag | Where it implements | Dirty tree |
|------|---------------------|------------|
| *(none)* | Fresh `<type>/<slug>` branch from the filename. Halts if it already exists. | stash-carried onto the branch |
| `--no-branch` | The current branch, in place. No checkout. | left in place |
| `--branch=<name>` | Branch `<name>` — checks it out, creating it if missing (no halt if it exists). | stash-carried onto the branch |
| `--worktree` | Isolated worktree on a fresh `<type>/<slug>` branch, via [`using-git-worktrees`](https://github.com/obra/superpowers). | left in the main checkout; worktree starts clean |

---

### Branch Naming

Parsed from the plan filename `YYYY-MM-DD-<type>-<slug>.md`:

| Plan file | Branch |
|-----------|--------|
| `2026-05-26-feat-health-check.md` | `feat/health-check` |
| `2026-05-26-fix-token-expiry.md` | `fix/token-expiry` |
| `2026-05-26-some-idea.md` | `feat/some-idea` *(no known type → defaults to `feat`)* |

Known types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`. Used by the default and `--worktree` modes. In default mode, if the branch already exists it halts rather than clobbering it — use `--branch=<name>` to reuse an existing branch on purpose.

---

## ✅ Output

```
✓ Implementation complete — nothing committed.
  Mode:    <fresh-branch | no-branch | named-branch | worktree>
  Branch:  <branch>
  Worktree: <path>            (worktree mode only)
  Plan:    <plan_path> (stamped)
  Files changed:
  <git diff --stat>

Review the full diff, then commit yourself when satisfied.
```

If a task gets stuck (test fails >3×, missing file, ambiguous instruction), it writes `.iso/logs/write/<plan-basename>.blocked.md` (git-ignored, keyed per plan) with what failed and what it tried, then waits for you — still no commit.

---

## 🔧 Dependencies

| Tool / Skill | Role | Source |
|--------------|------|--------|
| `git` | Branch creation, stash carry-over | [git-scm.com](https://git-scm.com) |
| `superpowers:using-git-worktrees` | Isolated workspace for `--worktree` | [obra/superpowers](https://github.com/obra/superpowers) |
| `superpowers:executing-plans` | Drives task-by-task execution | [obra/superpowers](https://github.com/obra/superpowers) |
| `superpowers:test-driven-development` | Red-green-refactor per task | [obra/superpowers](https://github.com/obra/superpowers) |

---

## 🔗 Related

- [`iso‑plan`](../iso-plan/) — produces the plan file this skill consumes.
- [`iso‑init‑repo`](../iso-init-repo/) — set up the branch protection your reviewed work merges through.

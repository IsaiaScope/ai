# ✍️ iso-write

> Build a written plan on a fresh feature branch using TDD — then **stop without committing**, so you review the full diff and commit yourself.

---

## 🧩 What It Does

Takes the plan [`iso-plan`](../iso-plan/) wrote and implements it, task by task, red-green-refactor. The hard rule that overrides everything else: **it never commits.** Every change is left in the working tree for you to review.

```
1. Read the whole plan end-to-end
2. Derive a branch from the plan filename → git checkout -b <type>/<slug>
3. Execute each task with TDD   (write failing test → minimal code → pass)
4. Tick each checkbox in the plan as tasks finish
5. Stamp the plan "implemented (uncommitted)"
6. Print the diff stat and HALT — no commit, no PR
```

A dirty working tree is fine — uncommitted work is stashed and carried onto the new branch, so it shows up in the final review diff too.

It works the same whether driven by **Claude Code or Codex** — agent-independent.

---

## ▶️ Trigger

```
/iso-write <plan_path>
```

Example: `/iso-write docs/superpowers/plans/2026-05-26-feat-thing.md`

The path is required. Missing file → it halts immediately.

---

## 🌿 Branch Naming

Parsed from the plan filename `YYYY-MM-DD-<type>-<slug>.md`:

| Plan file | Branch |
|-----------|--------|
| `2026-05-26-feat-health-check.md` | `feat/health-check` |
| `2026-05-26-fix-token-expiry.md` | `fix/token-expiry` |
| `2026-05-26-some-idea.md` | `feat/some-idea` *(no known type → defaults to `feat`)* |

Known types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`. If the branch already exists, it halts rather than clobbering it.

---

## ✅ Output

```
✓ Implementation complete — nothing committed.
  Branch:  <branch>
  Plan:    <plan_path> (stamped)
  Files changed:
  <git diff --stat>

Review the full diff, then commit yourself when satisfied.
```

If a task gets stuck (test fails >3×, missing file, ambiguous instruction), it writes `BLOCKED.md` at the repo root with what failed and what it tried, then waits for you — still no commit.

---

## 🔧 Dependencies

| Tool / Skill | Role | Source |
|--------------|------|--------|
| `git` | Branch creation, stash carry-over | [git-scm.com](https://git-scm.com) |
| `superpowers:executing-plans` | Drives task-by-task execution | [obra/superpowers](https://github.com/obra/superpowers) |
| `superpowers:test-driven-development` | Red-green-refactor per task | [obra/superpowers](https://github.com/obra/superpowers) |

---

## 🔗 Related

- [`iso-plan`](../iso-plan/) — produces the plan file this skill consumes.
- [`iso-init-repo`](../iso-init-repo/) — set up the branch protection your reviewed work merges through.

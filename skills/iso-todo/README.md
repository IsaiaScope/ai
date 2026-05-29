# 🧵 iso-todo

> Run the full development cycle — plan, write, review, and leave one uncommitted diff ready for human review.

---

## 🧩 What It Does

Chains the original workflow skills into one hands-off run:

```
/iso-todo [--codex-only] [seed]
  1. PLAN   parent session       → iso-plan → plan file
  2. WRITE  spawned codex tab    → iso-write on fresh feat/<slug>
  3. REVIEW parent session       → iso-review over the resulting diff
  4. CLOSE  parent session       → no commit; implementation tab stays alive
```

With a seed, planning starts from that text. Without one, planning starts from the current conversation. Use `--codex-only` to make review skip Claude. There is no plan-path entry, phase skip, or resume mode.

| Phase | Where | Skill |
|-------|-------|-------|
| Plan | parent session | [`iso‑plan`](../iso-plan/) |
| Write | spawned codex tab | [`iso‑write`](../iso-write/) |
| Review | parent session | [`iso‑review`](../iso-review/) |

The implementation tab is reused as the review fix tab, so accepted fixes land in the same workspace as the original implementation. See [ADR 0001](../../docs/adr/0001-impl-tab-reused-as-fix-tab.md).

## ▶️ Trigger

```
/iso-todo
/iso-todo --codex-only
/iso-todo <seed idea>
```

Or ask: *"take this idea from plan to implemented and reviewed"*

## ✅ Output

```
  /iso-todo — <branch>              no commit
  ──────────────────────────────────────────
  ✓ Plan     <plan_path>
  ✓ Write    <N files, +a/-b>    tab <TERM_IMPL> (alive)
  ✓ Review   <x fixed, y dropped>   tab <TERM_IMPL> (reused)
             tests <pass|fail> · types <pass|fail>

  Review the diff → commit yourself.
  Tab: <TERM_IMPL>
```

Everything stays uncommitted on `feat/<slug>`: the plan, implementation, and review fixes. If planning produces no plan, or implementation returns `blocked` / `unknown`, the pipeline stops before review and leaves the implementation tab available for follow-up.

## 🔧 Dependencies

| Tool / Skill | Role | Source |
|--------------|------|--------|
| [`iso‑plan`](../iso-plan/) | Produces the implementation plan | — |
| [`iso‑write`](../iso-write/) | Builds the plan with TDD, no commit | — |
| [`iso‑review`](../iso-review/) | Reviews the uncommitted diff and applies accepted fixes | — |
| [`iso‑spawn`](../iso-spawn/) | Launches and reuses the implementation tab | — |
| `git` | Branch and diff state | [git-scm.com](https://git-scm.com) |

Executable mechanics live in `scripts/todo.sh`; outcome classification lives in `scripts/classify-impl.sh`.

## 🔗 Related

- [`iso‑plan`](../iso-plan/) — the first phase: turn the seed into a written plan.
- [`iso‑write`](../iso-write/) — the second phase: implement that plan without committing.
- [`iso‑review`](../iso-review/) — the third phase: review and fix the uncommitted diff.
- [`iso‑spawn`](../iso-spawn/) — the tab lifecycle engine used for implementation and fixes.

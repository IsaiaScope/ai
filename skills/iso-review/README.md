# 🔍 iso-review

> Review your **uncommitted working tree** with one agent or with Codex + Claude — merge findings, apply every fix that helps, verify, and stop uncommitted for your final read.

---

## 🧩 What It Does

Review of the current working-tree diff, then applies the fixes worth keeping — never committing.

- 👥 **Review tabs** — both Codex and Claude review the diff by default; `--agent codex|claude` runs just that one
- 🔀 **Merged + de-duplicated** — findings hitting the same spot fold into one (noting both reviewers raised it)
- ✅ **Keeps almost everything** — applies every fix except the net-negative ones (over-engineering, speculative "consider…" notes, coupling/churn for no real gain)
- 🧪 **Self-verifies** — a fix tab (the `--agent` agent, claude when both reviewers ran, or an existing tab via `--fix-term`) applies the fixes, then runs the repo's tests + type-check and reports
- 🛑 **Never commits** — leaves all changes in the working tree for your final read

---

### Flow

The main session orchestrates; the review and fix tabs do the work. One review at a time per working tree — for parallel reviews, use separate git worktrees (each gets its own cwd-local `docs/iso/logs/review`).

```mermaid
flowchart LR
    P["1 · Pre-flight"] --> R["2 · Reviews<br/>one agent<br/>or codex + claude"]
    R --> E["3 · Extract + merge"]
    E --> F["4 · Filter<br/>drop net-negative"]
    F --> A["5 · Apply + verify<br/>tests + type-check"]
    A --> C["6 · Close-out<br/>uncommitted"]
```

`docs/iso/logs/review` is wiped clean at the start of each run, so no prior run's findings, transcripts, or accepted fixes leak in.

---

## ▶️ Trigger

```
/iso-review
```

Or ask: *"review and fix my uncommitted changes with codex only"*

### Flags

| Flag | Effect |
|------|--------|
| `--agent codex\|claude` | Run only that reviewer; **omit → both**. The chosen agent also applies the fixes (claude when both ran) |
| `--claude-review-effort medium\|high\|max` | Effort level for the claude reviewer (default `medium`) |
| `--fix-term TERM` | Reuse an existing live agent tab for fixes instead of spawning a new fix tab; overrides the `--agent`-derived fixer |
| `--kill-review-tabs` | Tear down the review tabs once their findings are saved to disk |
| `--kill-fix-tab` | Tear down the fix tab once its test/type report is captured |
| `--kill-tabs` | Shorthand for both kill flags |

```
/iso-review --agent codex
/iso-review --agent claude
/iso-review --claude-review-effort max
/iso-review --fix-term term_IMPL
/iso-review --kill-tabs
```

The default reviewers are codex + claude. Use `--agent codex` (or `claude`) for a single reviewer — e.g. when Claude tokens are unavailable. The **fixer** follows `--agent`: a single named agent reviews and fixes; with both reviewers it falls back to claude (or reuse a tab with `--fix-term`).

Teardown is **opt-in** — by default every tab stays alive for inspection. Each kill happens only *after* that tab's output is on disk, so it reclaims the process without losing anything you read.

---

## ✅ Output

- 📄 `docs/iso/logs/review/review-codex.txt` + `review-claude.txt` — the raw reviewer findings (JSON)
- 📋 `docs/iso/logs/review/accepted-fixes.md` — the itemised fix instructions actually applied
- 🧾 An **accepted / dropped ledger** (each drop with a one-line reason) plus the fix tab's test + type-check report, printed in the session
- 🌳 Every fix left **uncommitted** in your working tree — you review and commit

---

## 🔧 Dependencies

| Tool | Role | Source |
|------|------|--------|
| [`iso‑spawn`](../iso-spawn/) | Spawns + drives the review and fix tabs | — |
| `herdr` | Terminal workspace manager the tabs live in | [herdr.dev](https://herdr.dev) |
| `codex` / `claude` | The reviewing + fixing agent CLIs (`claude` only when not restricted to codex via `--agent`) | — |
| `git` | Reads the uncommitted working-tree diff | [git-scm.com](https://git-scm.com) |

> Requires running **inside a herdr pane** (`$HERDR_PANE_ID` must be set — inherited from [`iso-spawn`](../iso-spawn/)).

---

## 🔗 Related

- [`iso‑spawn`](../iso-spawn/) — the spawn / deliver / recover engine iso-review is built on.
- [`iso‑write`](../iso-write/) — build a plan with TDD; review the result here before committing.
- [`iso‑plan`](../iso-plan/) — produce that plan first.

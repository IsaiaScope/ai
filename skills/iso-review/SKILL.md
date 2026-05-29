---
name: iso-review
description: Review the uncommitted working tree. By default spawns codex /review and claude /code-review in two visible herdr tabs; with --codex-only, spawns only codex. Merges and de-duplicates findings in the main session, applies every fix except the net-negative ones via a fix tab (codex by default, claude via --fix-agent, or an existing tab via --fix-term) that then runs the project's tests and type-check — leaving all changes uncommitted. Use when invoked as /iso-review [--codex-only] [--claude-review-effort high|max] [--fix-agent codex|claude] [--fix-term TERM] [--kill-tabs], or asked to review-and-fix the current uncommitted changes.
---

# iso-review

Review the **uncommitted working-tree diff**, keep the fixes that help, apply them, verify, and stop — uncommitted — for your final read.

Invocation: `/iso-review [--codex-only] [--claude-review-effort high|max] [--fix-agent codex|claude] [--fix-term TERM] [--kill-review-tabs] [--kill-fix-tab] [--kill-tabs]`.

| flag | effect |
|------|--------|
| `--codex-only` | run only the Codex reviewer; no Claude tab is spawned and no Claude tokens are consumed |
| `--claude-review-effort high\|max` | effort level for the claude `/code-review` reviewer; default `high`. `--max` is shorthand for `--claude-review-effort max` |
| `--fix-agent codex\|claude` | which agent drives a newly spawned fix tab (Step 7); default `codex`. Ignored when `--fix-term` is provided |
| `--fix-term TERM` | reuse an existing live agent tab to apply accepted fixes instead of spawning a fresh fix tab |
| `--kill-review-tabs` | tear down both review tabs once their findings are saved to disk (Step 2) |
| `--kill-fix-tab` | tear down the fix tab once its test/type report is captured (Step 7) |
| `--kill-tabs` | shorthand for both `--kill-review-tabs` and `--kill-fix-tab` |

By default, the two **reviewers** are codex `/review` + claude `/code-review`. Use `--codex-only` when Claude tokens are unavailable or you want a Codex-only lifecycle test. Only the claude reviewer's effort and the **fixer** are selectable (codex `/review` is pinned to the uncommitted preset, no effort knob). Teardown is **opt-in**: by default every tab is left alive for live inspection. The kill flags make cleanup systematic — each tab is killed only *after* its output has been persisted, so a kill reclaims the process without losing anything you read. Map the invocation flags onto the orchestrator calls: pass `--codex-only` / `--claude-review-effort <level>` / `--kill-review-tabs` (or `--kill-tabs`) to `reviews`, and `--fix-agent <agent>` or `--fix-term <TERM>` / `--kill-fix-tab` (or `--kill-tabs`) to `apply`.

Orchestrator: `skills/iso-review/scripts/review.sh`. Run it with its absolute path. Reviewer-specific behavior lives behind `Reviewer adapter` files: `scripts/lib/reviewer-codex.sh` owns Codex `/review` dispatch and Codex output normalization; `scripts/lib/reviewer-claude.sh` owns Claude `/code-review` dispatch and Claude output normalization. Use `review.sh run ...` for the full scripted path, or the lower-level subcommands below when the main session needs to inspect and decide each phase manually.

## Flow (the main session drives this)

1. **Pre-flight** — `review.sh preflight`. If it exits non-zero, print its message and stop.
2. **Reviews** — `review.sh reviews [--codex-only] [--claude-review-effort high|max] [--kill-review-tabs]`. Wipes `.iso/logs/review` clean first (so no prior run's `accepted-fixes.md`/transcripts/`.spawned-terms` can leak in), then spawns the reviewer tabs, drives them, waits for them to truly finish, and writes `.iso/logs/review/review-codex.txt` and `.iso/logs/review/review-claude.txt`. With `--codex-only`, the Claude files are empty/`[]` placeholders so downstream merge logic stays stable. Read both files. With `--kill-review-tabs`, reviewer tabs are torn down right after those files are written (their findings are already on disk). (One review at a time per working tree; for parallel reviews use separate git worktrees — each gets its own cwd-local `.iso/logs/review`.)
3. **Extract** — pull every finding into `{ file, line, problem, fix, source }`. Both reviewers emit JSON, so prefer parsing it; fall back to reading prose if a file isn't JSON.
   - codex: `{ "findings": [ { "title", "body", "priority", "code_location": { "absolute_file_path", "line_range" } } ] }`
   - claude: `[ { "file", "line", "summary", "failure_scenario" } ]`
   - If a file is empty, that reviewer produced nothing — continue with the other. If both are empty, stop: "no findings".
4. **Merge + dedup** — fold findings that hit the same file + overlapping lines + same underlying problem into one (note both reviewers raised it).
5. **Filter (keep almost everything)** — accept every merged finding **except** ones that make the code worse or overcomplicated: unwarranted abstraction, over-engineering, speculative "consider…" notes, readability churn that fixes nothing, anything adding coupling/length without real gain. Conflicting fixes for one spot → take the simpler; if ambiguous, skip. Drop nothing else.
6. **Ledger** — print the accepted list and the dropped list (each drop with a one-line reason) so the decisions are visible.
7. **Apply + self-verify** — write the accepted fixes as an itemised instruction list to `.iso/logs/review/accepted-fixes.md`, then `review.sh apply .iso/logs/review/accepted-fixes.md [--fix-agent codex|claude | --fix-term TERM] [--kill-fix-tab]`. **If the accepted list is empty (every finding was dropped), do not call `apply` — `review.sh apply` returns 3 and spawns no fix tab; report "no fixes to apply" and skip to close-out.** When there are fixes, this either spawns the fix tab (codex by default, or claude via `--fix-agent claude`) or reuses the caller-provided `--fix-term` tab. The fix tab implements the fixes **and then runs the repo's tests + type-check and reports**. Read its report. With `--kill-fix-tab`, the tab is torn down right after the report is captured.
8. **Close-out (no commit, no extra tab)** — leave every change in the working tree. By default the review and fix tabs stay alive for inspection (kill them yourself, or pass the kill flags on Steps 2/7 for systematic teardown). Print the final summary (accepted/dropped ledger + the fix tab's test/type report) and stop. The user reviews and commits. **Never commit, never open a PR, never spawn a re-review tab.**

Scripted helper:

```bash
skills/iso-review/scripts/review.sh run --kill-review-tabs --fix-term "$TERM_IMPL"
# Codex-only:
skills/iso-review/scripts/review.sh run --codex-only --kill-review-tabs --fix-term "$TERM_IMPL"
```

This runs preflight, reviewer dispatch, normalized finding collection, accepted-fix file creation, and apply. The main-session `/iso-review` flow may still use the lower-level subcommands above when human judgment is needed for the merge/filter ledger.

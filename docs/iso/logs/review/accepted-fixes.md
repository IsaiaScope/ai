# Accepted fixes — scope: skills/iso-review/scripts/lib/drive.sh ONLY

**Hard scope rule:** Edit **only** `skills/iso-review/scripts/lib/drive.sh`. Do **not** touch
`herdr.sh`, `wait.sh`, or any other file — they are another agent's in-flight work and are out of scope.
Locate each fix by the **function name and surrounding code shown below**, not by line number
(the review's line numbers are unreliable).

---

## Fix 1 — accept a fast-finished reviewer as "started" (correctness bug)

**Where:** function `rv_reviews`, inside the start-confirmation loop `for reviewer in codex claude; do … done`.
Find this `case` (it classifies the polled agent status `$st`):

```bash
      case "$st" in
        working|done) started=1; break;;
        blocked) echo "✗ agent $term blocked (awaiting approval/permission)" >&2; break;;
      esac
```

**Change:** add `idle` to the first branch so it reads `working|idle|done)`:

```bash
      case "$st" in
        working|idle|done) started=1; break;;
        blocked) echo "✗ agent $term blocked (awaiting approval/permission)" >&2; break;;
      esac
```

**Why:** a reviewer that completes before this loop first polls reports `idle`. The old pattern
matched only `working|done`, so the loop ran its full window without ever setting `started=1`,
then marked the reviewer failed and overwrote a perfectly valid review file with
`__DISPATCH_FAILED__`. `wait_done` (called right after) already treats `idle` as finished, so
accepting `idle` here is consistent and self-correcting.

---

## Fix 2 — use the `herdr_pane_read` wrapper instead of open-coding the pane read (DRY)

**Where:** functions `rv_wait_ready` and `rv_drive_codex_review` in the same file. They open-code
the pane read several times in this exact form:

```bash
herdr pane read "$p" --source visible --lines 30 2>/dev/null
```

`drive.sh` already sources `herdr.sh`, which provides the wrapper:
`herdr_pane_read() { herdr pane read "$1" --source visible --lines "${2:-40}" 2>/dev/null || true; }`

**Change:** replace **every** occurrence of `herdr pane read "$p" --source visible --lines 30 2>/dev/null`
in `drive.sh` with `herdr_pane_read "$p" 30`. Keep the surrounding pipeline (`| grep …`) and logic
identical — only the read call changes. Pass `30` explicitly so the line count is unchanged
(the wrapper defaults to 40).

**Why:** the read flags (`--source visible`, error suppression) then live in one place; a future
change to how panes are read updates the wrapper and is picked up here automatically, instead of
silently missing these open-coded copies.

---

## After applying

- Run the iso-review unit tests: `bash skills/iso-review/scripts/lib/drive.test.sh` — all assertions must print `ok:` and the script must exit 0.
- Syntax-check: `bash -n skills/iso-review/scripts/lib/drive.sh`.
- Report PASS/FAIL for both. Do NOT commit — leave all changes in the working tree.

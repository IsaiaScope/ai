# Accepted fixes C + E — scope: iso-spawn wait.sh, deliver.sh, tests/run.sh ONLY

**Hard scope rule:** Edit **only** these three files:
- `skills/iso-spawn/scripts/lib/wait.sh`
- `skills/iso-spawn/scripts/lib/deliver.sh`
- `skills/iso-spawn/tests/run.sh`

Do **not** touch `drive.sh`, `herdr.sh`, or anything else. Locate each fix by the **function name
and exact code shown below**, not by line number. Apply each as a literal before→after replacement.

---

## Fix C — don't let a scrollback-sourced recover satisfy the `--done-grep` gate (wait.sh)

**Where:** function `wait_done`, the `if [ -n "$done_grep" ]; then …` block inside the main `while`
loop.

**Before:**
```bash
    if [ -n "$done_grep" ]; then
      cur=$(wait_recover_once "$term" --what output 2>/dev/null || true)
      if printf '%s' "$cur" | grep -qE -- "$done_grep"; then
        WAIT_SETTLE_SLEEP="${WAIT_SETTLE_SLEEP:-$poll}" wait_recover_settled "$term" --what output >/dev/null
        echo "wait_done: done-grep matched" >&2
        return 0
      fi
    fi
```

**After:**
```bash
    if [ -n "$done_grep" ]; then
      cur=$(wait_recover_once "$term" --what output 2>/dev/null || true)
      # A scrollback-sourced recover (recover.py couldn't map the jsonl and fell back to raw TUI
      # text, prefixed "# source: scrollback") is not a real transcript: a partial render can show
      # the done-grep tokens before the agent's final turn flushes. Don't let it satisfy the gate —
      # wait for a real mapped transcript so we never return on a truncated review.
      case "$cur" in
        '# source: scrollback'*) ;;
        *)
          if printf '%s' "$cur" | grep -qE -- "$done_grep"; then
            WAIT_SETTLE_SLEEP="${WAIT_SETTLE_SLEEP:-$poll}" wait_recover_settled "$term" --what output >/dev/null
            echo "wait_done: done-grep matched" >&2
            return 0
          fi
          ;;
      esac
    fi
```

---

## Fix E-1 — `wait_seconds` is a seconds sanitizer, not a unit guesser (wait.sh)

**Where:** function `wait_seconds`.

**Before:**
```bash
wait_seconds() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) printf '0'; return 0;; esac
  if [ "$n" -gt 10000 ]; then printf '%s' "$(( (n + 999) / 1000 ))"
  else printf '%s' "$n"; fi
}
```

**After:**
```bash
# Sanitize a --timeout/--escalate argument to a non-negative integer number of SECONDS.
# wait_done's --timeout/--escalate are contractually seconds; any caller holding milliseconds
# (e.g. deliver.sh) converts at its own boundary. No unit guessing here — a large seconds value
# (e.g. 14400 for a 4h review) is passed through unchanged instead of being mistaken for ms.
wait_seconds() {
  local n="${1:-0}"
  case "$n" in ''|*[!0-9]*) printf '0'; return 0;; esac
  printf '%s' "$n"
}
```

(The two call sites `timeout=$(wait_seconds "$timeout")` and `escalate=$(wait_seconds "$escalate")`
stay exactly as they are — they now sanitize seconds instead of guessing units.)

## Fix E-2 — convert ms→seconds at deliver's boundary (deliver.sh)

**Where:** function `deliver_worker`, its final line (the `--wait` branch that calls `wait_done`).
`WAIT_MS` is milliseconds (default 600000 from spawn.sh) and is consumed nowhere else.

**Before:**
```bash
  [ "$WAIT" = 1 ] && wait_done "$TERM2" --timeout "$WAIT_MS" >/dev/null 2>&1 || true
```

**After:**
```bash
  # WAIT_MS is milliseconds; wait_done --timeout is seconds. Convert at this boundary
  # (round up so a sub-second wait never collapses to 0).
  [ "$WAIT" = 1 ] && wait_done "$TERM2" --timeout "$(( (WAIT_MS + 999) / 1000 ))" >/dev/null 2>&1 || true
```

---

## Tests — lock both new contracts (tests/run.sh)

These reuse the existing wait-section harness. The block that mocks `herdr_agent_status` /
`wait_recover_once` / `herdr_pane_active` ends with:
`unset -f herdr_agent_status wait_recover_once herdr_pane_active`.

**Add C's assertion just before that `unset -f` line** (mocks still in scope), mirroring the
existing `term_TIMEOUT` case:
```bash
printf 'working' > "$wait_status_file"; printf '# source: scrollback\n{"findings":[]}' > "$wait_recover_file"; printf '0' > "$wait_active_file"
WAIT_DONE_POLL=0 WAIT_DONE_STEP=1 wait_done term_SCROLLBACK --timeout 2 --escalate 10 --done-grep '"findings"' >/dev/null 2>&1; wait_scrollback_rc=$?
assert_eq "wait_done ignores scrollback source in done-grep gate" "$wait_scrollback_rc" "4"
```
(If there is a trailing `unset wait_status_file … wait_*_rc` line, append `wait_scrollback_rc` to it.)

**Add E's assertions** anywhere after `wait.sh` is sourced (e.g. immediately after the C assertion,
before the `unset -f`). They call `wait_seconds` directly — no mocks needed:
```bash
assert_eq "wait_seconds keeps large seconds unchanged" "$(wait_seconds 14400)" "14400"
assert_eq "wait_seconds passes small seconds" "$(wait_seconds 600)" "600"
assert_eq "wait_seconds sanitizes non-numeric to 0" "$(wait_seconds abc)" "0"
```

---

## After applying

- Run `bash skills/iso-spawn/tests/run.sh` — every assertion must pass, exit 0.
- Syntax-check: `bash -n skills/iso-spawn/scripts/lib/wait.sh` and `bash -n skills/iso-spawn/scripts/lib/deliver.sh`.
- Also run `bash skills/iso-review/scripts/lib/drive.test.sh` (read-only check that nothing regressed) — but do NOT edit drive.sh.
- Report PASS/FAIL for each. Do NOT commit — leave all changes in the working tree.

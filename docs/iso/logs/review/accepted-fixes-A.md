# Accepted fix A — scope: skills/iso-spawn/scripts/lib/herdr.sh ONLY

**Hard scope rule:** Edit **only** `skills/iso-spawn/scripts/lib/herdr.sh`. Do **not** touch
`wait.sh`, `drive.sh`, or any other file. Locate the fix by the **function name and code shown
below**, not by line number.

---

## Fix — `herdr_pane_active`: a missing pane must mean inactive, not active

**Where:** function `herdr_pane_active`. It starts by resolving the term's pane, then guards:

```bash
herdr_pane_active() { # $1=term — rc 0 active, rc 1 inactive
  local term="$1" pane text sum safe cache dir
  pane=$(herdr_pane_for "$term")
  [ -n "$pane" ] || return 0
```

**Change:** the no-pane guard must return **1** (inactive), not 0:

```bash
  [ -n "$pane" ] || return 1
```

**Why:** `herdr_pane_for` returns empty when the agent's tab has been closed or crashed (herdr can
no longer resolve a pane for that term). Returning 0 here reports a dead tab as **active**, which
defeats `wait_done`'s dead-detection: its `*)` branch resets `dead=0` on every poll, so it never
returns 3 (dead) and instead blocks the full `--timeout` (up to `RV_REVIEW_TIMEOUT`=3600s) on an
agent that is already gone. A missing pane is the clearest possible "not active" signal, so it must
map to rc 1.

**Why this is safe (no false-dead at boot):** `herdr_pane_active` is only called from `wait_done`
*after* `elapsed >= escalate` (escalate = timeout/2, capped at 300s), and a dead verdict requires
`dead_limit` (default 18) consecutive inactive polls. A just-spawned agent has a resolvable pane long
before escalate, so this change cannot prematurely kill a healthy agent — it only lets a genuinely
gone tab be detected promptly instead of hanging to timeout.

---

## After applying

- Run the iso-spawn test suite: `bash skills/iso-spawn/tests/run.sh` — report the result.
- Syntax-check: `bash -n skills/iso-spawn/scripts/lib/herdr.sh`.
- If any existing test encodes the OLD "no pane => active (rc 0)" contract, do NOT change the test —
  stop and report it instead, so the contract change can be reviewed.
- Report PASS/FAIL. Do NOT commit — leave all changes in the working tree.

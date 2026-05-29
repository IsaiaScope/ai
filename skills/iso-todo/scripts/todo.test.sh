#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TODO="$HERE/todo.sh"
fail=0
assert() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

tmp=$(mktemp -d)
mkdir -p "$tmp/bin" "$tmp/plan-dir" "$tmp/review" "$tmp/cwd"
plan="$tmp/plan-dir/2026-01-01-feat-demo.md"
printf '# plan\n' > "$plan"
cat > "$tmp/spawn.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  spawn)
    printf '{"term":"term_IMPL","pane":"pane_IMPL","tab":"tab_IMPL","agent":"codex","name":"itodoimpl","cwd":"%s","spawn_file":"%s/spawnfile"}\n' "$PWD" "$PWD"
    ;;
  send)
    echo "$2" > "$ISO_STUB_SENT_TERM"
    printf '%s' "$3" > "$ISO_STUB_SENT_PROMPT"
    ;;
  recover)
    printf '✓ Implementation complete — nothing committed.\n'
    ;;
esac
SH
cat > "$tmp/review.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  run)
    echo run "$@" >> "$ISO_STUB_REVIEW_LOG"
    ;;
esac
SH
cat > "$tmp/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") printf '{"result":{"agent":{"agent_status":"idle","pane_id":"pane_IMPL"}}}\n' ;;
esac
SH
chmod +x "$tmp/spawn.sh" "$tmp/review.sh" "$tmp/bin/herdr"
( cd "$tmp/cwd" && ISO_STUB_SENT_TERM="$tmp/sent-term" ISO_STUB_SENT_PROMPT="$tmp/sent-prompt" \
  ISO_STUB_REVIEW_LOG="$tmp/review.log" ISO_STUB_RV_OUT="$tmp/review" RV_OUTDIR="$tmp/review" \
  SPAWN="$tmp/spawn.sh" REVIEW="$tmp/review.sh" PATH="$tmp/bin:$PATH" \
  WAIT_DONE_POLL=0 WAIT_DONE_STEP=1 WAIT_DONE_FAST_IDLE_POLLS=1 "$TODO" run-plan "$plan" >/dev/null )
assert "todo sends iso-write to implementation tab" "grep -qx term_IMPL '$tmp/sent-term' && grep -qx '/iso-write $plan' '$tmp/sent-prompt'"
assert "todo runs full iso-review with implementation tab reuse" "grep -q -- 'run run --kill-review-tabs --fix-term term_IMPL' '$tmp/review.log'"
rm -rf "$tmp"

tmp=$(mktemp -d)
mkdir -p "$tmp/bin" "$tmp/cwd"
plan="$tmp/2026-01-01-feat-blocked.md"
printf '# plan\n' > "$plan"
cat > "$tmp/spawn.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  spawn) printf '{"term":"term_BLOCK","pane":"pane_BLOCK"}\n' ;;
  send) : ;;
  recover) printf 'still working\n' ;;
esac
SH
cat > "$tmp/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") printf '{"result":{"agent":{"agent_status":"idle","pane_id":"pane_BLOCK"}}}\n' ;;
esac
SH
chmod +x "$tmp/spawn.sh" "$tmp/bin/herdr"
( cd "$tmp/cwd" && mkdir -p .iso/logs/write && touch .iso/logs/write/2026-01-01-feat-blocked.blocked.md \
  && SPAWN="$tmp/spawn.sh" REVIEW="$tmp/missing-review" PATH="$tmp/bin:$PATH" \
  WAIT_DONE_POLL=0 WAIT_DONE_STEP=1 WAIT_DONE_FAST_IDLE_POLLS=1 "$TODO" run-plan "$plan" >/dev/null 2>&1 )
assert "todo stops before review when implementation blocked" "[ $? -eq 3 ]"
rm -rf "$tmp"

tmp=$(mktemp -d)
mkdir -p "$tmp/bin" "$tmp/cwd"
plan="$tmp/2026-01-01-feat-timeout.md"
printf '# plan\n' > "$plan"
cat > "$tmp/spawn.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  spawn) printf '{"term":"term_TIMEOUT","pane":"pane_TIMEOUT"}\n' ;;
  send) : ;;
  recover) printf '✓ Implementation complete — nothing committed.\n' ;;
esac
SH
cat > "$tmp/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") printf '{"result":{"agent":{"agent_status":"working","pane_id":"pane_TIMEOUT"}}}\n' ;;
  "pane read") printf '' ;;
esac
SH
chmod +x "$tmp/spawn.sh" "$tmp/bin/herdr"
( cd "$tmp/cwd" && SPAWN="$tmp/spawn.sh" REVIEW="$tmp/missing-review" PATH="$tmp/bin:$PATH" \
  ISO_TODO_WAIT_MS=1000 WAIT_DONE_POLL=0 WAIT_DONE_STEP=1 "$TODO" run-plan "$plan" >/dev/null 2>&1 )
assert "todo stops before review when spawn lifecycle wait fails" "[ $? -eq 4 ]"
rm -rf "$tmp"

exit $fail

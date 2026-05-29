#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/drive.sh"
fail=0
assert() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

# preflight fails outside a git repo
tmp=$(mktemp -d); ( cd "$tmp" && HERDR_PANE_ID=p_1 rv_preflight >/dev/null 2>&1 ); assert "no-git rejected" "[ $? -ne 0 ]"

# preflight fails on clean tree
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && git commit -q --allow-empty -m init && HERDR_PANE_ID=p_1 rv_preflight >/dev/null 2>&1 ); assert "clean-tree rejected" "[ $? -ne 0 ]"

# preflight fails without HERDR_PANE_ID
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && echo x > f && unset HERDR_PANE_ID && rv_preflight >/dev/null 2>&1 ); assert "no-herdr rejected" "[ $? -ne 0 ]"

# preflight passes: git repo + uncommitted change + herdr
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && echo x > f && HERDR_PANE_ID=p_1 rv_preflight >/dev/null 2>&1 ); assert "valid accepted" "[ $? -eq 0 ]"

# detect npm test
tmp=$(mktemp -d); ( cd "$tmp" && printf '{"scripts":{"test":"jest"}}' > package.json && out=$(rv_detect_test_cmd); [ "$out" = "npm test" ] ); assert "npm test detected" "[ $? -eq 0 ]"

# detect Makefile test target
tmp=$(mktemp -d); ( cd "$tmp" && printf 'test:\n\techo hi\n' > Makefile && out=$(rv_detect_test_cmd); [ "$out" = "make test" ] ); assert "make test detected" "[ $? -eq 0 ]"

# nothing → empty output
tmp=$(mktemp -d); ( cd "$tmp" && out=$(rv_detect_test_cmd); [ -z "$out" ] ); assert "no test cmd → empty" "[ $? -eq 0 ]"

tmp=$(mktemp -d)
(
  RV_OUTDIR="$tmp/out"
  rv_spawn() { [ "$1" = codex ] && echo "term_CODEX pane_CODEX" || echo "term_CLAUDE pane_CLAUDE"; }
  rv_wait_ready() { return 0; }
  reviewer_codex_dispatch() { return 0; }
  reviewer_claude_dispatch() { return 0; }
  herdr_agent_status() { echo working; }
  rv_confirm_started() { return 0; }
  rv_wait_finished() { return 0; }
  rv_recover_settled() { printf 'settled %s' "$1" > "$2"; }
  wait_done() { printf '%s\n' "$*" >> "$tmp/wait_done.args"; return 0; }
  wait_recover_settled() { printf 'settled %s' "$1"; }
  rv_reviews high >/dev/null
  grep -q -- '--done-grep' "$tmp/wait_done.args" &&
    grep -qF -- '```json|"findings"|"summary"|"failure_scenario"' "$tmp/wait_done.args"
); assert "review wait passes findings done-grep" "[ $? -eq 0 ]"
rm -rf "$tmp"

# --- normalized Findings -------------------------------------------------------

tmp=$(mktemp -d)
cat > "$tmp/codex.txt" <<'JSON'
{"findings":[{"title":"Bad branch","body":"fails when branch is empty","priority":"P1","code_location":{"absolute_file_path":"/repo/skills/x.sh","line_range":{"start":42}}}]}
JSON
reviewer_codex_normalize "$tmp/codex.txt" "$tmp/codex-findings.json"
python3 - "$tmp/codex-findings.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d == [{
  "source":"codex",
  "file":"/repo/skills/x.sh",
  "line":42,
  "problem":"Bad branch\nfails when branch is empty",
  "fix":"fails when branch is empty",
  "severity":"P1"
}]
PY
assert "codex raw output normalizes to Findings" "[ $? -eq 0 ]"
rm -rf "$tmp"

tmp=$(mktemp -d)
cat > "$tmp/claude.txt" <<'JSON'
[{"file":"skills/y.sh","line":7,"summary":"Missing quote","failure_scenario":"path with spaces breaks"}]
JSON
reviewer_claude_normalize "$tmp/claude.txt" "$tmp/claude-findings.json"
python3 - "$tmp/claude-findings.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d == [{
  "source":"claude",
  "file":"skills/y.sh",
  "line":7,
  "problem":"Missing quote",
  "fix":"path with spaces breaks",
  "severity":""
}]
PY
assert "claude raw output normalizes to Findings" "[ $? -eq 0 ]"
rm -rf "$tmp"

tmp=$(mktemp -d)
mkdir -p "$tmp/out"
cat > "$tmp/out/findings-codex.json" <<'JSON'
[
  {"source":"codex","file":"skills/a.sh","line":12,"problem":"Dropped send","fix":"Require a working transition","severity":"P2"},
  {"source":"codex","file":"skills/a.sh","line":12,"problem":"Dropped send","fix":"Require a working transition","severity":"P2"}
]
JSON
printf '[]\n' > "$tmp/out/findings-claude.json"
rv_write_accepted_fixes "$tmp/out"
rc=$?
ones=$(grep -c '^1\. ' "$tmp/out/accepted-fixes.md" 2>/dev/null || true)
twos=$(grep -c '^2\. ' "$tmp/out/accepted-fixes.md" 2>/dev/null || true)
assert "accepted fixes are written and exact duplicates deduped" "[ $rc -eq 0 ] && grep -q 'Require a working transition' \"$tmp/out/accepted-fixes.md\" && [ $ones -eq 1 ] && [ $twos -eq 0 ]"
rm -rf "$tmp"

tmp=$(mktemp -d)
mkdir -p "$tmp/out"
printf '[]\n' > "$tmp/out/findings-codex.json"
printf '[]\n' > "$tmp/out/findings-claude.json"
rv_write_accepted_fixes "$tmp/out" >/dev/null 2>&1
rc=$?
assert "no accepted fixes writes empty file and rc 3" "[ $rc -eq 3 ] && [ ! -s \"$tmp/out/accepted-fixes.md\" ]"
rm -rf "$tmp"

tmp=$(mktemp -d)
(
  fake="$tmp/spawn-json.sh"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '{"term":"term_JSON","pane":"pane_JSON","tab":"tab_JSON","spawn_file":"/tmp/s.spawn"}\n'
SH
  chmod +x "$fake"
  SPAWN="$fake"
  out=$(rv_spawn codex label name)
  [ "$out" = "term_JSON pane_JSON" ]
); assert "rv_spawn consumes spawn --json output" "[ $? -eq 0 ]"
rm -rf "$tmp"

# --- teardown flags -------------------------------------------------------------

# reviews_mock: stub the spawn/drive/wait surface, log every rv_kill_term call to $tmp/killed.
reviews_mock() {  # runs rv_reviews "$@" in the current subshell with mocks in place
  rv_spawn() { [ "$1" = codex ] && echo "term_CODEX pane_CODEX" || echo "term_CLAUDE pane_CLAUDE"; }
  rv_wait_ready() { return 0; }
  reviewer_codex_dispatch() { return 0; }
  reviewer_claude_dispatch() { printf '%s\n' "${2:-}" > "$tmp/level"; return 0; }  # $2 = effort level
  herdr_agent_status() { echo working; }
  wait_done() { return 0; }
  wait_recover_settled() { printf 'settled %s' "$1"; }
  rv_kill_term() { printf '%s\n' "$1" >> "$tmp/killed"; }
  rv_reviews "$@" >/dev/null
}

# --kill-review-tabs tears down BOTH review terms
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; reviews_mock high --kill-review-tabs
  grep -qx term_CODEX "$tmp/killed" && grep -qx term_CLAUDE "$tmp/killed"
); assert "kill-review-tabs kills both review terms" "[ $? -eq 0 ]"
rm -rf "$tmp"

# idle/done without a working transition is a dispatch failure, not a started review
tmp=$(mktemp -d)
(
  RV_OUTDIR="$tmp/out"
  RV_START_WINDOW=1
  rv_spawn() { [ "$1" = codex ] && echo "term_CODEX pane_CODEX" || echo "term_CLAUDE pane_CLAUDE"; }
  rv_wait_ready() { return 0; }
  reviewer_codex_dispatch() { return 0; }
  reviewer_claude_dispatch() { return 0; }
  herdr_agent_status() { echo idle; }
  wait_done() { touch "$tmp/waited"; return 0; }
  wait_recover_settled() { printf 'should not recover'; }
  rv_reviews >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] &&
    [ ! -f "$tmp/waited" ] &&
    grep -qx "__DISPATCH_FAILED__" "$tmp/out/review-codex.txt" &&
    grep -qx "__DISPATCH_FAILED__" "$tmp/out/review-claude.txt"
); assert "idle without working transition fails dispatch" "[ $? -eq 0 ]"
rm -rf "$tmp"

# default reviews keeps both tabs alive (no kill)
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; reviews_mock high
  [ ! -f "$tmp/killed" ]
); assert "reviews default keeps tabs (no kill)" "[ $? -eq 0 ]"
rm -rf "$tmp"

# --- claude review effort -------------------------------------------------------

# --claude-review-effort max drives claude at max
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; reviews_mock --claude-review-effort max
  grep -qx max "$tmp/level"
); assert "claude-review-effort max" "[ $? -eq 0 ]"
rm -rf "$tmp"

# default effort is high
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; reviews_mock
  grep -qx high "$tmp/level"
); assert "claude-review-effort default high" "[ $? -eq 0 ]"
rm -rf "$tmp"

# positional level still honored (back-compat with --max → reviews max)
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; reviews_mock max
  grep -qx max "$tmp/level"
); assert "positional level still works" "[ $? -eq 0 ]"
rm -rf "$tmp"

# unknown effort rejected before any driving
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; reviews_mock --claude-review-effort ultra >/dev/null 2>&1
  [ ! -f "$tmp/level" ]
); assert "unknown review effort rejected" "[ $? -eq 0 ]"
rm -rf "$tmp"

# full run: preflight, review, accepted-fixes creation, then apply into an existing fix term
tmp=$(mktemp -d)
(
  RV_OUTDIR="$tmp/out"
  rv_preflight() { echo preflight > "$tmp/preflight"; }
  rv_reviews() {
    printf '%s\n' "$*" > "$tmp/reviews.args"
    mkdir -p "$RV_OUTDIR"
    printf '[{"source":"codex","file":"skills/a.sh","line":12,"problem":"Dropped send","fix":"Require working"}]\n' > "$RV_OUTDIR/findings-codex.json"
    printf '[]\n' > "$RV_OUTDIR/findings-claude.json"
  }
  rv_apply() { printf '%s\n' "$@" > "$tmp/apply.args"; }
  rv_run --kill-review-tabs --fix-term term_IMPL >/dev/null
  grep -qx preflight "$tmp/preflight" &&
    grep -q -- '--kill-review-tabs' "$tmp/reviews.args" &&
    grep -qx -- '--fix-term' "$tmp/apply.args" &&
    grep -qx term_IMPL "$tmp/apply.args" &&
    grep -q 'Require working' "$RV_OUTDIR/accepted-fixes.md"
); assert "run performs full review path and reuses fix term" "[ $? -eq 0 ]"
rm -rf "$tmp"

# full run: no accepted findings means no apply call
tmp=$(mktemp -d)
(
  RV_OUTDIR="$tmp/out"
  rv_preflight() { return 0; }
  rv_reviews() {
    mkdir -p "$RV_OUTDIR"
    printf '[]\n' > "$RV_OUTDIR/findings-codex.json"
    printf '[]\n' > "$RV_OUTDIR/findings-claude.json"
  }
  rv_apply() { touch "$tmp/applied"; }
  rv_run >/dev/null
  [ ! -f "$tmp/applied" ] && [ ! -s "$RV_OUTDIR/accepted-fixes.md" ]
); assert "run skips apply when no accepted fixes" "[ $? -eq 0 ]"
rm -rf "$tmp"

# apply_mock: fake SPAWN that emits a term on stderr + a report on stdout; log rv_kill_term calls.
apply_mock() {  # runs rv_apply "$@" with mocks in place
  mkdir -p "$RV_OUTDIR"
  printf 'fix: do the thing\n' > "$tmp/fixes.md"
  fake="$tmp/fakespawn.sh"
  # $1=spawn $2=<agent>; record the chosen agent so tests can assert fixer selection.
  printf '#!/usr/bin/env bash\necho "$2" > %q\nprintf '"'"'{"term":"term_FIX","result":"REPORT OK"}\\n'"'"'\n' "$tmp/fixagent" > "$fake"; chmod +x "$fake"
  SPAWN="$fake"
  rv_detect_test_cmd() { printf ''; }
  rv_kill_term() { printf '%s\n' "$1" >> "$tmp/killed"; }
  rv_apply "$tmp/fixes.md" "$@" >/dev/null
}

# --kill-fix-tab tears down the fix term
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; apply_mock --kill-fix-tab
  grep -qx term_FIX "$tmp/killed"
); assert "kill-fix-tab kills fix term" "[ $? -eq 0 ]"
rm -rf "$tmp"

# default apply keeps the fix tab alive (no kill)
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; apply_mock
  [ ! -f "$tmp/killed" ]
); assert "apply default keeps fix tab (no kill)" "[ $? -eq 0 ]"
rm -rf "$tmp"

# --- fix agent selection --------------------------------------------------------

# --fix-agent claude drives the fix tab with claude
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; apply_mock --fix-agent claude
  grep -qx claude "$tmp/fixagent"
); assert "fix-agent claude drives fix tab" "[ $? -eq 0 ]"
rm -rf "$tmp"

# cloudcode alias normalizes to claude
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; apply_mock --fix-agent cloudcode
  grep -qx claude "$tmp/fixagent"
); assert "fix-agent cloudcode → claude" "[ $? -eq 0 ]"
rm -rf "$tmp"

# default fixer is codex
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; apply_mock
  grep -qx codex "$tmp/fixagent"
); assert "fix-agent default codex" "[ $? -eq 0 ]"
rm -rf "$tmp"

# unknown fix agent rejected before any spawn
tmp=$(mktemp -d)
( RV_OUTDIR="$tmp/out"; apply_mock --fix-agent bogus >/dev/null 2>&1
  [ ! -f "$tmp/fixagent" ]
); assert "unknown fix-agent rejected" "[ $? -eq 0 ]"
rm -rf "$tmp"

# --fix-term reuses an existing implementation tab instead of spawning a fix tab
tmp=$(mktemp -d)
(
  RV_OUTDIR="$tmp/out"
  printf 'fix: do the thing\n' > "$tmp/fixes.md"
  fake="$tmp/fakespawn.sh"
  cat > "$fake" <<EOF
#!/usr/bin/env bash
case "\$1" in
  send) echo "\$2" > "$tmp/sent-term"; printf '%s' "\$3" > "$tmp/sent-prompt"; echo sent;;
  recover) echo RECOVERED_REPORT;;
  spawn) touch "$tmp/spawned";;
esac
EOF
  chmod +x "$fake"
  SPAWN="$fake"
  rv_detect_test_cmd() { printf ''; }
  wait_done() { echo "$1" > "$tmp/waited-term"; return 0; }
  rv_apply "$tmp/fixes.md" --fix-term term_IMPL >/dev/null
  grep -qx term_IMPL "$tmp/sent-term" &&
    grep -qx term_IMPL "$tmp/waited-term" &&
    grep -q "fix: do the thing" "$tmp/sent-prompt" &&
    [ ! -f "$tmp/spawned" ]
); assert "fix-term reuses existing tab (no spawn)" "[ $? -eq 0 ]"
rm -rf "$tmp"

# rv_apply: empty accepted file → no spawn, distinct rc 3
tmp=$(mktemp -d)
( cd "$tmp" \
  && : > accepted.md \
  && printf '#!/usr/bin/env bash\ntouch "%s/spawned"\n' "$tmp" > "$tmp/fakespawn" \
  && chmod +x "$tmp/fakespawn" \
  && SPAWN="$tmp/fakespawn" rv_apply accepted.md >/dev/null 2>&1; rc=$? \
  ; [ "$rc" -eq 3 ] && [ ! -f "$tmp/spawned" ] )
assert "empty accepted → no spawn (rc 3)" "[ $? -eq 0 ]"
rm -rf "$tmp"

# rv_apply: non-empty accepted file → spawn IS invoked
tmp=$(mktemp -d)
( cd "$tmp" \
  && echo "- fix the off-by-one in foo()" > accepted.md \
  && printf '#!/usr/bin/env bash\ntouch "%s/spawned"\necho "term=t_1"\n' "$tmp" > "$tmp/fakespawn" \
  && chmod +x "$tmp/fakespawn" \
  && SPAWN="$tmp/fakespawn" rv_apply accepted.md >/dev/null 2>&1 \
  ; [ -f "$tmp/spawned" ] )
assert "non-empty accepted → spawn invoked" "[ $? -eq 0 ]"
rm -rf "$tmp"

exit $fail

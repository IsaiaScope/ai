#!/usr/bin/env bash
# iso-spawn test runner. Pure bash, no external deps. Exits non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RECOVER="$HERE/../scripts/recover.py"
SPAWN="$HERE/../scripts/spawn.sh"
FIX="$HERE/fixtures"
fail=0

assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then echo "ok: $1"
  else echo "FAIL: $1"; echo "  expected: [$3]"; echo "  actual:   [$2]"; fail=1; fi
}
assert_has() { # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"
  else echo "FAIL: $1 (missing: [$3])"; echo "  in: [$2]"; fail=1; fi
}
assert_not_has() { # name haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL: $1 (unexpected: [$3])"; echo "  in: [$2]"; fail=1
  else echo "ok: $1"; fi
}
assert_before() { # name haystack first second
  local a b; a=$(printf '%s' "$2" | grep -nF -- "$3" | head -1 | cut -d: -f1)
  b=$(printf '%s' "$2" | grep -nF -- "$4" | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "ok: $1"
  else echo "FAIL: $1 ([$3]@$a not before [$4]@$b)"; fail=1; fi
}

# --- Task 1: codex output ---
out=$(python3 "$RECOVER" codex output "$FIX/codex.jsonl" text)
assert_eq "codex output = final answer" "$out" "FINAL_ANSWER_42"

# --- Task 2: codex chat + empty ---
chat=$(python3 "$RECOVER" codex chat "$FIX/codex.jsonl" text)
assert_has "codex chat has question" "$chat" "hello question"
assert_has "codex chat has answer" "$chat" "FINAL_ANSWER_42"
assert_before "codex chat user before assistant" "$chat" "hello question" "FINAL_ANSWER_42"

emptyout=$(python3 "$RECOVER" codex output "$FIX/empty.jsonl" text); rc=$?
assert_eq "empty output note" "$emptyout" "# (no assistant output found)"
assert_eq "empty output exit 1" "$rc" "1"

# --- Task 3: claude ---
cout=$(python3 "$RECOVER" claude output "$FIX/claude.jsonl" text)
assert_eq "claude output skips tool_use line" "$cout" "FINAL_ANSWER_42"
cchat=$(python3 "$RECOVER" claude chat "$FIX/claude.jsonl" text)
assert_has "claude chat has question" "$cchat" "hello question"
assert_has "claude chat has answer" "$cchat" "FINAL_ANSWER_42"

# --- Task 4: json format ---
j=$(python3 "$RECOVER" codex output "$FIX/codex.jsonl" json)
role=$(printf '%s' "$j" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["role"])')
txt=$(printf '%s' "$j" | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["text"])')
assert_eq "json output role" "$role" "assistant"
assert_eq "json output text" "$txt" "FINAL_ANSWER_42"
jc=$(python3 "$RECOVER" codex chat "$FIX/codex.jsonl" json)
n=$(printf '%s' "$jc" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
assert_eq "json chat turn count" "$n" "2"

# --- Task 5: spawn.sh recover with --session-file seam ---
e2e=$("$SPAWN" recover dummyterm --session-file "$FIX/codex.jsonl" --agent codex --what output)
assert_eq "spawn recover output via session-file" "$e2e" "FINAL_ANSWER_42"
e2ec=$("$SPAWN" recover dummyterm --session-file "$FIX/claude.jsonl" --agent claude --what chat)
assert_has "spawn recover claude chat" "$e2ec" "hello question"

TMP=$(mktemp -d)
: > "$TMP/x__term_EMPTY.spawn"
emptyrecover=$(ISO_SPAWN_LOGDIR="$TMP" "$SPAWN" recover term_EMPTY --session-file "$FIX/empty.jsonl" --agent codex --what output --kill); rc=$?
assert_eq "recover empty output still exits 1" "$rc" "1"
assert_has "recover empty output note via spawn" "$emptyrecover" "# (no assistant output found)"
[ -f "$TMP/x__term_EMPTY.spawn" ]; assert_eq "recover --kill cleans after parser rc 1" "$?" "1"
rm -rf "$TMP"

# --- Task 6: candidate set + snapshot diff (env-overridable dirs) ---
TMP=$(mktemp -d)
mkdir -p "$TMP/codex/2026/05/27" "$TMP/claude/-tmp-fixture"
touch "$TMP/codex/2026/05/27/rollout-A.jsonl"
PRE=$(ISO_CODEX_SESS="$TMP/codex" "$SPAWN" __candidate-set codex /tmp/fixture)
touch "$TMP/codex/2026/05/27/rollout-B.jsonl"
NEW=$(ISO_CODEX_SESS="$TMP/codex" "$SPAWN" __diff-new codex /tmp/fixture "$PRE")
assert_eq "snapshot diff finds new codex file" "$(basename "$NEW")" "rollout-B.jsonl"
touch "$TMP/claude/-tmp-fixture/sess-A.jsonl"
CPRE=$(ISO_CLAUDE_PROJ="$TMP/claude" "$SPAWN" __candidate-set claude /tmp/fixture)
touch "$TMP/claude/-tmp-fixture/sess-B.jsonl"
CNEW=$(ISO_CLAUDE_PROJ="$TMP/claude" "$SPAWN" __diff-new claude /tmp/fixture "$CPRE")
assert_eq "snapshot diff finds new claude file" "$(basename "$CNEW")" "sess-B.jsonl"
rm -rf "$TMP"

# --- Task 7: .spawn meta block writer ---
TMP=$(mktemp -d)
SF="$TMP/x.spawn"
"$SPAWN" __write-meta "$SF" term_X codex /tmp/fixture "$(printf '/a.jsonl\n/b.jsonl')"
assert_has "meta has term" "$(cat "$SF")" "term=term_X"
assert_has "meta has agent" "$(cat "$SF")" "agent=codex"
assert_has "meta has cwd" "$(cat "$SF")" "cwd=/tmp/fixture"
assert_has "meta has pre a" "$(cat "$SF")" "pre=/a.jsonl"
assert_has "meta has pre b" "$(cat "$SF")" "pre=/b.jsonl"
rm -rf "$TMP"

# --- Task 8: __deliver-style session_file resolution (via _diff_new) ---
TMP=$(mktemp -d); mkdir -p "$TMP/codex/2026/05/27"
touch "$TMP/codex/2026/05/27/rollout-OLD.jsonl"
SF="$TMP/y.spawn"
"$SPAWN" __write-meta "$SF" term_Y codex /tmp/fixture "$TMP/codex/2026/05/27/rollout-OLD.jsonl"
touch "$TMP/codex/2026/05/27/rollout-NEWEST.jsonl"
NEWF=$(ISO_CODEX_SESS="$TMP/codex" "$SPAWN" __diff-new codex /tmp/fixture "$(grep '^pre=' "$SF" | cut -d= -f2-)")
assert_eq "deliver resolves newest as session_file" "$(basename "$NEWF")" "rollout-NEWEST.jsonl"
rm -rf "$TMP"

# --- Task 9: recover <TERM> resolves session_file from .spawn sidecar ---
TMP=$(mktemp -d)
cp "$FIX/codex.jsonl" "$TMP/real.jsonl"
SF="$TMP/20260527-000000__codex__t__term_Z.spawn"
{ echo "[meta]"; echo "term=term_Z"; echo "agent=codex"; echo "cwd=/tmp/fixture"; echo "session_file=$TMP/real.jsonl"; } > "$SF"
got=$(ISO_SPAWN_LOGDIR="$TMP" "$SPAWN" recover term_Z --what output)
assert_eq "recover by TERM uses sidecar session_file" "$got" "FINAL_ANSWER_42"
rm -rf "$TMP"

# --- Task 5: cleanup (orphaned + named, grace window) ---
. "$HERE/../scripts/lib/transcript.sh"; . "$HERE/../scripts/lib/herdr.sh"; . "$HERE/../scripts/lib/cleanup.sh"
TMP=$(mktemp -d)
mkdir -p "$TMP/work" "$TMP/main" "$TMP/tmpdir" "$TMP/indexed"
herdr_agent_terms() { echo "term_LIVE"; }              # stub: only term_LIVE is alive
: > "$TMP/main/a__term_LIVE.spawn"                         # alive -> keep
: > "$TMP/main/b__term_DEAD.spawn"; touch -t 202001010000 "$TMP/main/b__term_DEAD.spawn"  # dead+old -> reap
: > "$TMP/main/c__term_FRESH.spawn"                        # dead but fresh (<grace) -> keep
: > "$TMP/tmpdir/d__term_TMP.spawn"; touch -t 202001010000 "$TMP/tmpdir/d__term_TMP.spawn"
: > "$TMP/indexed/e__term_INDEX.spawn"; touch -t 202001010000 "$TMP/indexed/e__term_INDEX.spawn"
printf '%s\n' "$TMP/indexed" > "$TMP/index"
( cd "$TMP/work" && ISO_SPAWN_LOGDIR="$TMP/main" ISO_SPAWN_INDEX="$TMP/index" TMPDIR="$TMP/tmpdir" ISO_ORPHAN_GRACE=60 cleanup_orphaned )
[ -f "$TMP/main/a__term_LIVE.spawn" ];  assert_eq "live sidecar kept"  "$?" "0"
[ -f "$TMP/main/b__term_DEAD.spawn" ];  assert_eq "dead+old reaped"    "$?" "1"
[ -f "$TMP/main/c__term_FRESH.spawn" ]; assert_eq "dead+fresh kept"    "$?" "0"
[ -f "$TMP/tmpdir/d__term_TMP.spawn" ]; assert_eq "TMPDIR sidecar reaped" "$?" "1"
[ -f "$TMP/indexed/e__term_INDEX.spawn" ]; assert_eq "indexed cwd sidecar reaped" "$?" "1"
cleanup_rm_sidecar term_FRESH "$TMP/main"
[ -f "$TMP/main/c__term_FRESH.spawn" ]; assert_eq "rm_sidecar removes named" "$?" "1"
unset -f herdr_agent_terms
rm -rf "$TMP"

# --- Task 6: dispatch routing ---
out=$("$SPAWN" recover dummyterm --session-file "$FIX/codex.jsonl" --agent codex --what output)
assert_eq "verb: recover routes" "$out" "FINAL_ANSWER_42"
err=$("$SPAWN" bogusverb 2>&1 || true)
assert_has "unknown verb -> usage" "$err" "Usage:"

# --- Task 4: prompt-fingerprint disambiguation (concurrent same-cwd spawns) ---
. "$HERE/../scripts/lib/transcript.sh"
TMP=$(mktemp -d); mkdir -p "$TMP/codex/2026/05/27"
touch "$TMP/codex/2026/05/27/rollout-OLD.jsonl"
PRE=$(ISO_CODEX_SESS="$TMP/codex" transcript_candidate_set codex /tmp/fixture)
# two new files appear; only the SECOND (older mtime via touch order) contains our prompt
printf '{"payload":{"type":"user_message","message":"OTHER agent prompt"}}\n' > "$TMP/codex/2026/05/27/rollout-NEW-other.jsonl"
sleep 1
printf '{"payload":{"type":"user_message","message":"UNIQUE-FINGERPRINT-XYZ"}}\n' > "$TMP/codex/2026/05/27/rollout-NEW-mine.jsonl"
got=$(ISO_CODEX_SESS="$TMP/codex" transcript_resolve_new codex /tmp/fixture "$PRE" "UNIQUE-FINGERPRINT-XYZ")
assert_eq "fingerprint beats newest-by-mtime" "$(basename "$got")" "rollout-NEW-mine.jsonl"
# no prompt -> falls back to newest (the later-touched 'mine')
gotn=$(ISO_CODEX_SESS="$TMP/codex" transcript_resolve_new codex /tmp/fixture "$PRE" "")
assert_eq "no prompt -> newest-by-mtime" "$(basename "$gotn")" "rollout-NEW-mine.jsonl"
rm -rf "$TMP"

# --- Regression: delivery classifier failures do not kill worker under set -e ---
(
  set -euo pipefail
  . "$HERE/../scripts/lib/transcript.sh"
  . "$HERE/../scripts/lib/deliver.sh"
  deliver_classify() { return 7; }
  herdr_pane_read() { echo "OpenAI Codex"; }
  herdr_pane_run() { :; }
  herdr_agent_status() { echo working; }
  herdr_send_keys() { :; }
  deliver_worker term_CLASSIFY pane_CLASSIFY 0 1 "PROMPT_CLASSIFY" ""
)
assert_eq "deliver classify failure falls back to none" "$?" "0"

# --- Regression: --wait --recover accepts omitted value and propagates recovery rc ---
TMP=$(mktemp -d)
mkdir -p "$TMP/bin" "$TMP/cwd" "$TMP/codex/2026/05/27" "$TMP/logs"
cat > "$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get") printf '{"result":{"pane":{"workspace_id":"ws_TEST","cwd":"%s"}}}\n' "$ISO_STUB_CWD" ;;
  "agent list") printf '{"result":{"agents":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"tab_TEST"},"root_pane":{"pane_id":"pane_ROOT"}}}\n' ;;
  "agent start")
    cp "$ISO_STUB_EMPTY_JSONL" "$ISO_STUB_CODEX_SESS/2026/05/27/rollout-empty.jsonl"
    printf '{"result":{"agent":{"terminal_id":"term_WAIT","pane_id":"pane_AGENT","tab_id":"tab_TEST","agent_status":"idle"}}}\n'
    ;;
  "pane close") exit 0 ;;
  "pane read") printf '{"result":{"read":{"text":""}}}\n' ;;
  "agent get") printf '{"result":{"agent":{"terminal_id":"term_WAIT","pane_id":"pane_AGENT","tab_id":"tab_TEST","agent_status":"idle"}}}\n' ;;
  "agent wait") exit 0 ;;
  "tab close") exit 0 ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
chmod +x "$TMP/bin/herdr"
waitout=$(HERDR_PANE_ID=pane_CALL ISO_STUB_CWD="$TMP/cwd" ISO_STUB_EMPTY_JSONL="$FIX/empty.jsonl" \
  ISO_STUB_CODEX_SESS="$TMP/codex" ISO_CODEX_SESS="$TMP/codex" TMPDIR="$TMP/logs" PATH="$TMP/bin:$PATH" \
  "$SPAWN" codex --cwd "$TMP/cwd" --name waitrecover --safe --wait --recover --kill 2>&1); rc=$?
assert_eq "spawn --wait --recover without value exits with recover rc" "$rc" "1"
assert_has "spawn --wait --recover defaults to output" "$waitout" "--- recovered (output) ---"
assert_has "spawn --wait --recover prints parser output" "$waitout" "# (no assistant output found)"
assert_not_has "spawn --wait --recover failure does not print done" "$waitout" "done"
sidecars=$(find "$TMP/logs" -name '*__term_WAIT.spawn' -print)
assert_eq "spawn --wait --recover --kill cleans after recover rc 1" "$sidecars" ""
rm -rf "$TMP"

# --- Regression: spawned children inherit the caller's terminal type, not agent TERM ---
TMP=$(mktemp -d)
mkdir -p "$TMP/bin" "$TMP/cwd" "$TMP/codex"
cat > "$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pane get") printf '{"result":{"pane":{"workspace_id":"ws_TEST","cwd":"%s"}}}\n' "$ISO_STUB_CWD" ;;
  "agent list") printf '{"result":{"agents":[]}}\n' ;;
  "tab create") printf '{"result":{"tab":{"tab_id":"tab_TEST"},"root_pane":{"pane_id":"pane_ROOT"}}}\n' ;;
  "agent start") printf '{"result":{"agent":{"terminal_id":"term_ENV","pane_id":"pane_AGENT"}}}\n' ;;
  "pane close") exit 0 ;;
  "agent get") printf '{"result":{"agent":{"terminal_id":"term_ENV","pane_id":"pane_AGENT","tab_id":"tab_TEST","agent_status":"idle"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
cat > "$TMP/bin/nohup" <<'SH'
#!/usr/bin/env bash
printf '%s' "${TERM:-}" > "$ISO_STUB_NOHUP_TERM"
exit 0
SH
chmod +x "$TMP/bin/herdr" "$TMP/bin/nohup"
TERM=xterm-256color HERDR_PANE_ID=pane_CALL ISO_STUB_CWD="$TMP/cwd" ISO_STUB_NOHUP_TERM="$TMP/nohup_term" \
  ISO_CODEX_SESS="$TMP/codex" TMPDIR="$TMP/tmp" PATH="$TMP/bin:$PATH" \
  "$SPAWN" codex --cwd "$TMP/cwd" --name envtest --safe >/dev/null
for _ in $(seq 1 20); do [ -s "$TMP/nohup_term" ] && break; sleep 0.1; done
assert_eq "spawn preserves exported TERM for child processes" "$(cat "$TMP/nohup_term")" "xterm-256color"
rm -rf "$TMP"

exit $fail

#!/usr/bin/env bash
# Self-check for multica-session.sh. Run: bash multica-session.test.sh
# ponytail: asserts only on logic that could silently do harm — a redaction
# leak, a misresolved branch, a status write that starts an agent. No framework.
set -uo pipefail

SH="$(cd "$(dirname "$0")" && pwd)/multica-session.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

export MULTICA_STATE_DIR; MULTICA_STATE_DIR=$(mktemp -d)
# shellcheck source=/dev/null
. "$SH" >/dev/null 2>&1 || true
type redact >/dev/null 2>&1 || { echo "FATAL: sourcing did not define redact"; exit 1; }

echo "redact"
for secret in \
  "mul_d1df3554902c5cb1e167e3075e4d7d23740db963" \
  "sk-ant-api03-AAAAAAAAAAAAAAAAAAAA" \
  "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" \
  "AKIAIOSFODNN7EXAMPLE" \
  "AGE-SECRET-KEY-1QQPQZRHFVEXAMPLEEXAMPLEEXAMPLE" \
  "deadbeefdeadbeefdeadbeefdeadbeef" ; do
  out=$(printf 'x %s y' "$secret" | redact)
  if contains "$secret" "$out"; then bad "leaks $secret"; else ok "redacts ${secret:0:14}"; fi
done
check "keeps ordinary text" "$(printf 'fix auth bug' | redact)" "fix auth bug"
check "redacts inline in a sentence" \
  "$(printf 'token is mul_aaaaaaaaaaaaaaaaaaaa ok' | redact)" "token is [redacted] ok"

echo "project_for"
tmp=$(mktemp -d)
check "no remote -> scratch" "$( cd "$tmp" && git init -q -b main . && project_for "$tmp" )" "scratch"
( cd "$tmp" && git remote add origin https://github.com/IsaiaScope/ai-agent.git )
check "https remote -> basename"  "$(project_for "$tmp")" "ai-agent"
( cd "$tmp" && git remote set-url origin git@github.com:IsaiaScope/ai-agent.git )
check "ssh remote -> basename"    "$(project_for "$tmp")" "ai-agent"
check "outside any repo -> scratch" "$(project_for /)" "scratch"

echo "integration_branch"
r=$(mktemp -d)
# -b main on purpose: this repo's init.defaultBranch is dev, which would seed
# the fixture with the very branch the first assertion says is absent.
( cd "$r" && git init -q -b main . && git commit -q --allow-empty -m x )
check "no dev/develop -> not dev" "$(integration_branch "$r" | grep -c '^dev$')" "0"
( cd "$r" && git branch dev )
check "dev wins"     "$(integration_branch "$r")" "dev"
( cd "$r" && git branch -D dev >/dev/null 2>&1; git branch develop )
check "develop next" "$(integration_branch "$r")" "develop"

echo "ledger"
ledger_put WOR-1 '{"repo":"r","branch":"b","project":"p","opened_by":"claude"}'
check "put then get"          "$(ledger_get WOR-1 | jq -r .branch)" "b"
check "opened_by round-trips" "$(ledger_get WOR-1 | jq -r .opened_by)" "claude"
ledger_put WOR-2 '{"repo":"r","branch":"c","project":"p","opened_by":"iso"}'
check "two rows"              "$(jq -r 'keys|length' "$LEDGER")" "2"
ledger_del WOR-1
check "del removes one"       "$(jq -r 'keys|length' "$LEDGER")" "1"
check "del leaves other"      "$(ledger_get WOR-2 | jq -r .branch)" "c"
check "get on missing key is empty" "$(ledger_get NOPE)" ""

echo "exit contract"
PATH=/usr/bin:/bin bash "$SH" prompt </dev/null >/dev/null 2>&1
check "prompt with no multica/gh on PATH exits 0" "$?" "0"
PATH=/usr/bin:/bin bash "$SH" bogus-subcommand >/dev/null 2>&1
check "unknown subcommand exits 0" "$?" "0"
bash "$SH" >/dev/null 2>&1
check "no subcommand exits 0" "$?" "0"

echo "prompt / end"
S2=$(mktemp -d)
out=$(printf '{"session_id":"s1","prompt":"hello"}' | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" prompt 2>/dev/null)
contains "no issue bound" "$out" && ok "unbound prints the standing reminder" || bad "unbound line missing"

printf '{"issue":"WOR-42"}' > "$S2/session-s2.json"
out=$(printf '{"session_id":"s2","prompt":"hello"}' | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" prompt 2>/dev/null)
contains "WOR-42" "$out" && ok "bound prints the issue key" || bad "bound line missing key"

out=$(printf '{"session_id":"s2","prompt":"my token mul_aaaaaaaaaaaaaaaaaaaa here"}' \
  | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" prompt 2>/dev/null)
contains "mul_aaaaaaaaaaaaaaaaaaaa" "$out" && bad "secret reached stdout" || ok "secret absent from stdout"

printf '{"issue":"WOR-43"}' > "$S2/session-s3.json"
printf '{"session_id":"s3"}' | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" end >/dev/null 2>&1
[ -f "$S2/session-s3.json" ] && bad "end left the session file behind" || ok "end removes the session file"

printf '{"session_id":"s9"}' | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" end >/dev/null 2>&1
check "end on an unbound session exits 0" "$?" "0"

printf 'not json at all' | MULTICA_STATE_DIR="$S2" bash "$SH" prompt >/dev/null 2>&1
check "malformed payload exits 0" "$?" "0"
rm -rf "$S2"

echo "open / bind / done (offline)"
S3=$(mktemp -d)
MULTICA_STATE_DIR="$S3" PATH=/usr/bin:/bin bash "$SH" bind "" "" >/dev/null 2>&1
check "bind with no args exits 0" "$?" "0"
MULTICA_STATE_DIR="$S3" PATH=/usr/bin:/bin bash "$SH" open s9 "" >/dev/null 2>&1
check "open with no title exits 0" "$?" "0"
MULTICA_STATE_DIR="$S3" PATH=/usr/bin:/bin bash "$SH" open s9 "a title" >/dev/null 2>&1
check "open without multica on PATH exits 0" "$?" "0"
check "open without multica writes no ledger row" \
  "$(jq -r 'keys|length' "$S3/tracked.json" 2>/dev/null)" "0"
grep -q "could not resolve project\|open failed" "$S3/log" \
  && ok "the failure was logged" || bad "silent failure, nothing logged"
MULTICA_STATE_DIR="$S3" PATH=/usr/bin:/bin bash "$SH" done s9 >/dev/null 2>&1
check "done with nothing bound exits 0" "$?" "0"

# The whole design is outbound-only, so no status write may omit --no-start.
grep -n "multica issue status" "$SH" | grep -qv -- "--no-start" \
  && bad "a status write is missing --no-start" || ok "every status write passes --no-start"
rm -rf "$S3"

echo "reconcile guards"
S4=$(mktemp -d); rr=$(mktemp -d)
( cd "$rr" && git init -q -b main . && git commit -q --allow-empty -m x && git branch dev )
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-100 "{\"repo\":\"r\",\"branch\":\"ghost\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-101 "{\"repo\":\"r\",\"branch\":\"ghost\",\"project\":\"p\",\"opened_by\":\"iso\"}"'
check "two ledger rows seeded" "$(jq -r 'keys|length' "$S4/tracked.json")" "2"

( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH=/usr/bin:/bin bash "$SH" reconcile ) >/dev/null 2>&1
check "reconcile without gh exits 0" "$?" "0"
grep -q "gh unavailable" "$S4/log" && ok "interlock logged" || bad "interlock not logged"
grep -q -- "-> cancelled" "$S4/log" && bad "cancelled while gh was unavailable" || ok "no cancellation without gh"
check "claude-owned row survives (gh down)" "$(jq -r '."WOR-100".opened_by' "$S4/tracked.json")" "claude"
check "iso-owned row survives"              "$(jq -r '."WOR-101".opened_by' "$S4/tracked.json")" "iso"
grep -q "not cancelling" "$S4/log" && ok "deferral was logged per row" || bad "deferral not logged"

# A row whose branch IS the integration branch must never be touched.
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-102 "{\"repo\":\"r\",\"branch\":\"dev\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH=/usr/bin:/bin bash "$SH" reconcile ) >/dev/null 2>&1
check "integration-branch row skipped" "$(jq -r 'has("WOR-102")' "$S4/tracked.json")" "true"

# Idempotence: running twice must not change the ledger.
before=$(jq -Sc . "$S4/tracked.json")
( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH=/usr/bin:/bin bash "$SH" reconcile ) >/dev/null 2>&1
check "reconcile is idempotent" "$(jq -Sc . "$S4/tracked.json")" "$before"

check "no integration branch -> skips" \
  "$( d=$(mktemp -d); cd "$d" && git init -q -b main . >/dev/null 2>&1; \
      MULTICA_STATE_DIR="$S4" PATH=/usr/bin:/bin bash "$SH" reconcile >/dev/null 2>&1; echo $? )" "0"
# Empty ledger must not reach the network at all.
S5=$(mktemp -d)
( cd "$rr" && MULTICA_STATE_DIR="$S5" PATH=/usr/bin:/bin bash "$SH" reconcile ) >/dev/null 2>&1
check "empty ledger reconcile exits 0" "$?" "0"
grep -q "gh unavailable" "$S5/log" 2>/dev/null \
  && bad "empty ledger still probed gh" || ok "empty ledger short-circuits before gh"
rm -rf "$S5"

rm -rf "$S4" "$rr"

echo "scope colours"
n_scopes=$(printf '%s' "$SCOPES" | wc -w | tr -d ' ')
n_colors=$(for x in $SCOPES; do label_color_for "$x"; done | sort -u | wc -l | tr -d ' ')
check "every scope has a distinct colour" "$n_colors" "$n_scopes"

echo "project_id_for (stubbed CLI)"
S6=$(mktemp -d); BIN=$(mktemp -d)
# Stub multica. Records every invocation so the test can assert that the
# existing-project path never reaches `project create` - the failure that
# would silently make a duplicate project on every open.
cat > "$BIN/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
if [ "$1" = "project" ] && [ "$2" = "list" ]; then
  cat "$STUB_LIST"; exit 0
fi
if [ "$1" = "project" ] && [ "$2" = "create" ]; then
  echo '{"id":"created-id"}'; exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  # real CLI prints this on stderr, not stdout
  printf 'User:    Test User (t@e.com)\n' >&2; exit 0
fi
exit 0
STUB
chmod +x "$BIN/multica"
export STUB_CALLS="$S6/calls" STUB_LIST="$S6/list.json"

: > "$STUB_CALLS"; echo '[{"id":"existing-id","title":"ai-agent"}]' > "$STUB_LIST"
got=$(MULTICA_STATE_DIR="$S6" PATH="$BIN:$PATH" bash -c '. "'"$SH"'"; project_id_for ai-agent')
check "existing project -> its id"  "$got" "existing-id"
grep -q "project create" "$STUB_CALLS" && bad "created a duplicate project" || ok "no create when it already exists"

rm -f "$S6/projects.json"; : > "$STUB_CALLS"; echo '[]' > "$STUB_LIST"
got=$(MULTICA_STATE_DIR="$S6" PATH="$BIN:$PATH" bash -c '. "'"$SH"'"; project_id_for ai-agent')
check "missing project -> created id" "$got" "created-id"
check "create called exactly once"    "$(grep -c 'project create' "$STUB_CALLS")" "1"
grep -q '\-\-icon' "$STUB_CALLS" && ok "create passes an icon" || bad "create passes no icon"
grep -q -- '--status in_progress' "$STUB_CALLS" \
  && ok "create passes --status in_progress" || bad "project created without in_progress"
grep -q -- '--lead Test User' "$STUB_CALLS" \
  && ok "create passes the authenticated user as lead" || bad "project created with no lead"

: > "$STUB_CALLS"
got=$(MULTICA_STATE_DIR="$S6" PATH="$BIN:$PATH" bash -c '. "'"$SH"'"; project_id_for ai-agent')
check "cached id reused"        "$got" "created-id"
check "cache hit makes no calls" "$(wc -l < "$STUB_CALLS" | tr -d ' ')" "0"
rm -rf "$S6" "$BIN"

echo "open: description, emoji title, repo label (stubbed CLI)"
S7=$(mktemp -d); BIN7=$(mktemp -d)
cat > "$BIN7/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
case "$1 $2" in
  "project list")   echo '[{"id":"proj-id","title":"ai-agent"}]'; exit 0 ;;
  "label list")     echo '[]'; exit 0 ;;
  "label create")   echo '{"id":"label-id"}'; exit 0 ;;
  "issue create")   cat > "$STUB_DESC"; echo '{"identifier":"FIRE-9"}'; exit 0 ;;
  "issue get")      echo '{"status":"todo"}'; exit 0 ;;
  "auth status")    printf 'User:    Test User (t@e.com)\n' >&2; exit 0 ;;
  "property list")  echo '[]'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN7/multica"
export STUB_CALLS="$S7/calls" STUB_DESC="$S7/desc"
: > "$STUB_CALLS"; : > "$STUB_DESC"

g=$(mktemp -d); ( cd "$g" && git init -q -b main . && git commit -q --allow-empty -m x \
    && git remote add origin https://github.com/IsaiaScope/ai-agent.git )
got=$( cd "$g" && printf 'why: uploads die on 5xx\ntoken mul_aaaaaaaaaaaaaaaaaaaa here' \
  | MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
      open s1 "bug Retry uploader on 5xx" --scope be,data --scope ci )
check "open returns the identifier" "$got" "FIRE-9"

grep -q 'mul_aaaaaaaaaaaaaaaaaaaa' "$STUB_DESC" \
  && bad "SECRET REACHED THE DESCRIPTION" || ok "description is redacted before the board"
grep -q '\[redacted\]' "$STUB_DESC" && ok "redaction marker present in description" || bad "no redaction marker"
grep -q 'why: uploads die on 5xx' "$STUB_DESC" && ok "description body preserved" || bad "description body lost"
grep -q -- '--description-stdin' "$STUB_CALLS" \
  && ok "description sent via --description-stdin" || bad "description not sent on stdin"
grep -q 'issue label add FIRE-9 label-id' "$STUB_CALLS" \
  && ok "scope label attached to the issue" || bad "label not attached"
for want in be data ci; do
  grep -q -- "--name $want" "$STUB_CALLS" \
    && ok "label '$want' created" || bad "label '$want' missing"
done
check "three labels attached" "$(grep -c 'issue label add FIRE-9' "$STUB_CALLS")" "3"
grep -q -- '--name ai-agent' "$STUB_CALLS" \
  && bad "still labelling by repo name" || ok "no repo-named label"
grep -q -- '--assignee Test User' "$STUB_CALLS" \
  && ok "issue assigned to the authenticated user" || bad "issue created unassigned"
grep -q -- '--color #' "$STUB_CALLS" && ok "label created with a colour" || bad "label created without colour"
check "label cached" "$(jq -r '.be' "$S7/labels.json")" "label-id"

# A typo must not mint a permanent label.
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open s3 "t" --scope frontend </dev/null ) >/dev/null 2>&1
grep -q 'label create' "$STUB_CALLS" && bad "unknown scope created a label" || ok "unknown scope creates no label"
grep -q "unknown scope" "$S7/log" && ok "unknown scope logged" || bad "unknown scope not logged"

echo "branch on the card"
# Fresh state dir: the opens above already cached the property definition, so
# reusing S7 would assert against a warm cache and never see the create.
S8=$(mktemp -d)
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S8" PATH="$BIN7:$PATH" bash "$SH" \
    open b1 "t" --scope be </dev/null ) >/dev/null 2>&1
grep -q -- 'property create --name Branch --type text' "$STUB_CALLS" \
  && ok "Branch property defined once" || bad "Branch property never created"
grep -q -- 'issue property set FIRE-9 --name Branch --value main' "$STUB_CALLS" \
  && ok "branch written onto the issue" || bad "branch not written to the issue"
check "property definition cached" "$(jq -r '.Branch' "$S8/properties.json")" "1"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S8" PATH="$BIN7:$PATH" bash "$SH" \
    open b2 "t" --scope be </dev/null ) >/dev/null 2>&1
grep -q -- 'property create' "$STUB_CALLS" \
  && bad "re-created the property definition" || ok "cache prevents a second create"
grep -q -- '--name Branch --value main' "$STUB_CALLS" \
  && ok "branch still written on later opens" || bad "branch missing on second open"
rm -rf "$S8"

echo "priority"
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open p1 "t" --scope be </dev/null ) >/dev/null 2>&1
grep -q -- '--priority medium' "$STUB_CALLS" \
  && ok "defaults to medium, never none" || bad "no priority default"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open p2 "t" --priority urgent </dev/null ) >/dev/null 2>&1
grep -q -- '--priority urgent' "$STUB_CALLS" && ok "explicit priority passed" || bad "priority ignored"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open p3 "t" --priority critical </dev/null ) >/dev/null 2>&1
grep -q -- '--priority medium' "$STUB_CALLS" \
  && ok "invalid priority falls back to medium" || bad "invalid priority not handled"
grep -q "unknown priority" "$S7/log" && ok "invalid priority logged" || bad "invalid priority not logged"

# --parent must survive the new flag parsing.
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open s4 "t" --parent FIRE-1 --scope doc </dev/null ) >/dev/null 2>&1
grep -q -- '--parent FIRE-1' "$STUB_CALLS" && ok "--parent passed through" || bad "--parent lost"

# No description piped: must still create the issue, without --description-stdin.
: > "$STUB_CALLS"
got=$( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" open s2 "plain title" </dev/null )
check "open works with no description" "$got" "FIRE-9"
grep -q -- '--description-stdin' "$STUB_CALLS" \
  && ok "still sends a description (the resume block)" || bad "resume block not sent"
grep -q 'claude --resume s2 --dangerously-skip-permissions' "$STUB_DESC" \
  && ok "resume command present with no prose" || bad "resume command missing"

echo "resume block"
: > "$STUB_CALLS"; : > "$STUB_DESC"
( cd "$g" && printf 'context here' | MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open r1 "t" --scope be ) >/dev/null 2>&1
grep -q 'claude --resume r1 --dangerously-skip-permissions' "$STUB_DESC" \
  && ok "resume appended after prose" || bad "resume missing after prose"
grep -q 'context here' "$STUB_DESC" && ok "prose preserved alongside resume" || bad "prose lost"
grep -q '^---$' "$STUB_DESC" && ok "separator between prose and resume" || bad "no separator"
grep -c '```' "$STUB_DESC" | grep -q '^2$' && ok "resume is a fenced block" || bad "fence malformed"

# --agent codex: the work happens in a session `claude --resume` cannot reach, so
# the block must be absent entirely, not merely retargeted.
: > "$STUB_CALLS"; : > "$STUB_DESC"
( cd "$g" && printf 'context here' | MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open r2 "t" --scope be --agent codex ) >/dev/null 2>&1
grep -q 'claude --resume' "$STUB_DESC" \
  && bad "--agent codex still emitted a claude resume block" \
  || ok "--agent codex omits the resume block"
grep -q 'context here' "$STUB_DESC" \
  && ok "--agent codex keeps the prose" || bad "--agent codex lost the prose"

# default is claude, so an omitted --agent behaves as before.
: > "$STUB_CALLS"; : > "$STUB_DESC"
( cd "$g" && printf 'context here' | MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open r3 "t" --scope be --agent claude ) >/dev/null 2>&1
grep -q 'claude --resume r3 --dangerously-skip-permissions' "$STUB_DESC" \
  && ok "--agent claude emits the resume block" || bad "--agent claude lost the resume block"

echo "stage"
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open st1 "t" --parent FIRE-1 --stage 2 </dev/null ) >/dev/null 2>&1
grep -q -- '--stage 2' "$STUB_CALLS" && ok "stage passed with a parent" || bad "stage lost"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open st2 "t" --stage 2 </dev/null ) >/dev/null 2>&1
grep -q -- '--stage' "$STUB_CALLS" && bad "stage sent without a parent" || ok "stage without parent dropped"
grep -q "no effect" "$S7/log" && ok "orphan stage logged" || bad "orphan stage not logged"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open st3 "t" --parent FIRE-1 --stage abc </dev/null ) >/dev/null 2>&1
grep -q -- '--stage' "$STUB_CALLS" && bad "non-numeric stage sent" || ok "non-numeric stage dropped"
rm -rf "$S7" "$BIN7" "$g"

rm -rf "$tmp" "$r"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

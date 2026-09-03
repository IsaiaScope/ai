#!/usr/bin/env bash
# Self-check for tracking.sh. Run: bash multica-session.test.sh
# ponytail: asserts only on logic that could silently do harm — a redaction
# leak, a misresolved branch, a status write that starts an agent. No framework.
set -uo pipefail

SH="$(cd "$(dirname "$0")" && pwd)/tracking.sh"
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

echo "iso_current_branch"
# A detached head has no branch. `rev-parse --abbrev-ref HEAD` answers with the
# literal string "HEAD", which four call sites used to bind and resolve tickets
# by -- so this asserts the empty answer, not a pretty one.
cb=$(mktemp -d)
( cd "$cb" && git init -q -b main . && git commit -q --allow-empty -m x ) >/dev/null 2>&1
check "on a branch"   "$( cd "$cb" && iso_current_branch )" "main"
( cd "$cb" && git checkout -q --detach HEAD ) >/dev/null 2>&1
check "detached is empty" "$( cd "$cb" && iso_current_branch )" ""
check "and resolves no ticket" "$( cd "$cb" && ticket_for_branch >/dev/null 2>&1; echo $? )" "1"
rm -rf "$cb"

echo "ledger"
ledger_put WOR-1 '{"repo":"scratch","branch":"b","project":"p","opened_by":"claude"}'
check "put then get"          "$(ledger_get WOR-1 | jq -r .branch)" "b"
check "opened_by round-trips" "$(ledger_get WOR-1 | jq -r .opened_by)" "claude"
ledger_put WOR-2 '{"repo":"scratch","branch":"c","project":"p","opened_by":"iso"}'
check "two rows"              "$(jq -r 'keys|length' "$LEDGER")" "2"
ledger_del WOR-1
check "del removes one"       "$(jq -r 'keys|length' "$LEDGER")" "1"
check "del leaves other"      "$(ledger_get WOR-2 | jq -r .branch)" "c"
check "get on missing key is empty" "$(ledger_get NOPE)" ""


echo "plan entries"
S15=$(mktemp -d)
pe() { MULTICA_STATE_DIR="$S15" bash -c '. "'"$SH"'"; '"$*"''; }

# A legacy row written before this change holds a bare string. It must read as
# one current entry, with no migration script anywhere.
pe 'ledger_put OLD-1 "{\"repo\":\"r\",\"branch\":\"b\",\"plan\":\"docs/p/one.md\"}"'
check "string plan coerces to one entry" "$(pe 'plan_entries OLD-1 | jq -r "length"')" "1"
check "coerced entry is current"         "$(pe 'plan_entries OLD-1 | jq -r ".[0].state"')" "current"
check "coerced entry keeps the path"     "$(pe 'plan_entries OLD-1 | jq -r ".[0].path"')" "docs/p/one.md"

# An empty string is not a plan. It must not become an entry with an empty path.
pe 'ledger_put OLD-2 "{\"repo\":\"r\",\"branch\":\"b\",\"plan\":\"\"}"'
check "empty string plan is no entries" "$(pe 'plan_entries OLD-2 | jq -r "length"')" "0"
check "a row with no plan key is no entries" \
  "$(pe 'ledger_put OLD-3 "{\"repo\":\"r\"}"; plan_entries OLD-3 | jq -r "length"')" "0"

# addplan semantics: the outgoing current plan becomes done.
pe 'plan_push OLD-1 docs/p/two.md done "second body"'
check "push appends"                 "$(pe 'plan_entries OLD-1 | jq -r "length"')" "2"
check "previous current became done" "$(pe 'plan_entries OLD-1 | jq -r ".[0].state"')" "done"
check "new entry is current"         "$(pe 'plan_entries OLD-1 | jq -r ".[1].state"')" "current"
check "new entry keeps its body"     "$(pe 'plan_entries OLD-1 | jq -r ".[1].body"')" "second body"
check "plan_current names it"        "$(pe 'plan_current OLD-1')" "docs/p/two.md"

# replan semantics: the outgoing current plan becomes superseded, and is kept.
pe 'plan_push OLD-1 docs/p/three.md superseded "third"'
check "replan supersedes, does not delete" "$(pe 'plan_entries OLD-1 | jq -r ".[1].state"')" "superseded"
check "superseded body survives"           "$(pe 'plan_entries OLD-1 | jq -r ".[1].body"')" "second body"
check "three entries now"                  "$(pe 'plan_entries OLD-1 | jq -r "length"')" "3"

# Re-adding a plan already on the row moves it, never duplicates it.
pe 'plan_push OLD-1 docs/p/two.md done "again"'
check "re-adding does not duplicate" \
  "$(pe 'plan_entries OLD-1 | jq -r "[.[] | select(.path==\"docs/p/two.md\")] | length"')" "1"
check "re-added plan is current" "$(pe 'plan_current OLD-1')" "docs/p/two.md"

# The ledger row is an open object. A bind merges with `. +`, so a field do_bind
# knows nothing about has to survive it.
pe 'ledger_put PR-1 "{\"repo\":\"scratch\",\"branch\":\"b\",\"opened_by\":\"claude\",\"extra\":\"keep-me\"}"'
( cd "$tmp" && MULTICA_STATE_DIR="$S15" PATH=/usr/bin:/bin bash -c '. "'"$SH"'"; do_bind s1 PR-1 claude "" 0' ) >/dev/null 2>&1
check "bind preserves unknown fields" "$(pe 'ledger_get PR-1 | jq -r ".extra"')" "keep-me"

check "plan_push on a missing row fails" "$(pe 'plan_push NOPE-1 x done ""' >/dev/null 2>&1; echo $?)" "1"
rm -rf "$S15"

echo "ticket_for with plan arrays"
S16=$(mktemp -d); rr2=$(mktemp -d)
( cd "$rr2" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git )
tf() { ( cd "$rr2" && MULTICA_STATE_DIR="$S16" bash -c '. "'"$SH"'"; '"$*"'' ); }

tf 'ledger_put ARR-1 "{\"repo\":\"scratch\",\"branch\":\"feat/x\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/superpowers/plans/a.md\",\"state\":\"done\",\"body\":\"\"},{\"path\":\"docs/superpowers/plans/b.md\",\"state\":\"current\",\"body\":\"\"}]}"'
check "resolves by branch"                  "$(tf 'ticket_for feat/x')" "ARR-1"
check "resolves by the current plan"        "$(tf 'ticket_for docs/superpowers/plans/b.md')" "ARR-1"
check "resolves by an older plan"           "$(tf 'ticket_for docs/superpowers/plans/a.md')" "ARR-1"
check "an unknown plan resolves to nothing" "$(tf 'ticket_for docs/superpowers/plans/zz.md')" ""

# The FIRE-20/FIRE-21 case: two live rows, one branch, same repo. head -1 hid
# this completely. One key is still returned - callers expect one - but the
# duplicate must be announced.
tf 'ledger_put ARR-2 "{\"repo\":\"scratch\",\"branch\":\"feat/x\",\"opened_by\":\"claude\",\"plan\":[]}"'
check "still returns exactly one key" "$(tf 'ticket_for feat/x' | wc -l | tr -d ' ')" "1"
err=$( cd "$rr2" && MULTICA_STATE_DIR="$S16" bash -c '. "'"$SH"'"; ticket_for feat/x' 2>&1 >/dev/null )
contains "ARR-1" "$err" && contains "ARR-2" "$err" \
  && ok "a duplicate branch is announced on stderr, naming both" \
  || bad "duplicate rows on one branch went unreported"
grep -q 'ARR-2' "$S16/log" && ok "the duplicate is logged" || bad "duplicate not logged"

# A row scoped out by repo must announce itself, or "wrong checkout" and "new
# work" are indistinguishable - and only one of them should open a ticket.
tf 'ledger_put FAR-9 "{\"repo\":\"elsewhere\",\"branch\":\"feat/far\",\"opened_by\":\"claude\",\"plan\":[]}"'
check "another repo's row still resolves to nothing" "$(tf 'ticket_for feat/far')" ""
err2=$( cd "$rr2" && MULTICA_STATE_DIR="$S16" bash -c '. "'"$SH"'"; ticket_for feat/far' 2>&1 >/dev/null )
contains "another checkout" "$err2" && ok "a scoped-out match is announced" || bad "scoped-out match was silent"
rm -rf "$S16" "$rr2"

echo "render_body"
S17=$(mktemp -d); rr3=$(mktemp -d)
( cd "$rr3" && git init -q -b main . && git commit -q --allow-empty -m x )
rb() { ( cd "$rr3" && MULTICA_STATE_DIR="$S17" bash -c '. "'"$SH"'"; '"$*"'' ); }

check "label strips date and type" "$(rb 'plan_label docs/superpowers/plans/2026-08-28-feat-editor-script.md')" "editor script"
check "label survives no prefix"   "$(rb 'plan_label docs/superpowers/plans/script-layer.md')" "script layer"

ENT='[{"path":"docs/p/2026-08-27-script-layer.md","state":"done","body":"first prose"},{"path":"docs/p/2026-08-28-feat-editor-script.md","state":"current","body":"third prose"},{"path":"docs/p/2026-08-28-feat-x.md","state":"superseded","body":"abandoned"}]'
out=$(rb 'render_body s1 claude "the umbrella" '"'$ENT'"'')

contains "the umbrella" "$out"  && ok "intro is rendered"         || bad "intro missing"
contains "script layer" "$out"  && ok "done section rendered"     || bad "done section missing"
contains "editor script" "$out" && ok "current section rendered"  || bad "current section missing"
contains "abandoned" "$out"     && ok "a superseded body is kept" || bad "superseded body was dropped"
check "exactly one /iso-write line" "$(printf '%s' "$out" | grep -c '^/iso-write ')" "1"
contains "/iso-write docs/p/2026-08-28-feat-editor-script.md" "$out" \
  && ok "the /iso-write line names the current plan" || bad "wrong plan in the /iso-write line"
check "exactly one resume block" "$(printf '%s' "$out" | grep -c 'claude --resume')" "1"
check "three section headings" "$(printf '%s' "$out" | grep -c '^## ')" "3"

# Idempotence: the whole point of rendering rather than patching.
out2=$(rb 'render_body s1 claude "the umbrella" '"'$ENT'"'')
check "render is idempotent" "$out" "$out2"

# codex does the work in a session this command cannot reach, so no resume line.
outc=$(rb 'render_body s1 codex "" '"'$ENT'"'')
contains "claude --resume" "$outc" && bad "resume offered for a codex session" || ok "no resume line for codex"
contains "third prose" "$outc" && ok "sections still render for codex" || bad "codex render lost the sections"

# No entries at all: open with no plan must still produce the footer.
oute=$(rb 'render_body s1 claude "" "[]"')
contains "claude --resume s1" "$oute" && ok "empty entries still render a resume block" || bad "empty render lost the footer"
rm -rf "$S17" "$rr3"

echo "addplan"
S18=$(mktemp -d); BIN18=$(mktemp -d); g18=$(mktemp -d)
CALLS18="$S18/calls"; DESC18="$S18/desc"; : > "$CALLS18"; : > "$DESC18"
cat > "$BIN18/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS18"
case "$1 $2" in
  "issue get")    printf '{"status":"in_review"}' ;;
  "issue update") cat > "$DESC18" ;;
  "issue create") cat >/dev/null 2>&1; printf '{"identifier":"FIRE-9"}' ;;
  "auth status")  printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN18/multica"
export CALLS18 DESC18
( cd "$g18" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/many )

ap() { ( cd "$g18" && MULTICA_STATE_DIR="$S18" PATH="$BIN18:$PATH" bash "$SH" "$@" ); }

MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; ledger_put FIRE-50 "{\"repo\":\"scratch\",\"branch\":\"feat/many\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/one.md\",\"state\":\"current\",\"body\":\"first\"}]}"'

got=$(printf 'second body\n' | ap addplan s5 --plan docs/p/two.md)
check "addplan returns the existing key" "$got" "FIRE-50"
check "no new issue was created" "$(grep -c 'issue create' "$CALLS18")" "0"
check "the previous plan is done" \
  "$(MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; plan_entries FIRE-50 | jq -r ".[0].state"')" "done"
check "the new plan is current" \
  "$(MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; plan_current FIRE-50')" "docs/p/two.md"
contains "first" "$(cat "$DESC18")" && ok "the earlier plan survives in the body" || bad "addplan destroyed the earlier plan"
contains "second body" "$(cat "$DESC18")" && ok "the new plan is in the body" || bad "new plan missing from body"
grep -q 'issue status FIRE-50 in_progress' "$CALLS18" \
  && ok "in_review moves to in_progress" || bad "status not moved to in_progress"
grep -q 'comment add FIRE-50' "$CALLS18" && ok "the switch is commented" || bad "no comment for the plan switch"

# A token in the piped body must never reach the board, and must never be stored
# in the ledger either - the ledger is now what the body is rendered from.
: > "$DESC18"
printf 'tok mul_abcdefghijklmnop1234 x\n' | ap addplan s6 --plan docs/p/three.md >/dev/null 2>&1
grep -q 'mul_abcdefghijklmnop1234' "$DESC18" && bad "a token reached the board" || ok "the body was redacted"
MULTICA_STATE_DIR="$S18" bash -c '. "'"$SH"'"; plan_entries FIRE-50' | grep -q 'mul_abcdefghijklmnop1234' \
  && bad "a token was stored in the ledger" || ok "the stored body was redacted"

# No live ticket for this branch: addplan is not a create path.
( cd "$g18" && git checkout -q -b feat/orphan )
out=$(printf 'x\n' | ap addplan s7 --plan docs/p/four.md 2>&1)
check "addplan on an unknown branch exits 0" "$?" "0"
contains "no live ticket" "$out" && ok "says why it did nothing" || bad "silent on a missing ticket"
( cd "$g18" && git checkout -q feat/many )

check "addplan with no --plan exits 0" "$(printf 'x\n' | ap addplan s8 >/dev/null 2>&1; echo $?)" "0"
rm -rf "$S18" "$BIN18" "$g18"

echo "replan keeps history"
S19=$(mktemp -d); BIN19=$(mktemp -d); g19=$(mktemp -d)
CALLS19="$S19/calls"; DESC19="$S19/desc"; : > "$CALLS19"; : > "$DESC19"
cat > "$BIN19/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS19"
case "$1 $2" in
  "issue get")    printf '{"status":"in_progress"}' ;;
  "issue update") cat > "$DESC19" ;;
  "auth status")  printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN19/multica"
export CALLS19 DESC19
( cd "$g19" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/redo )
MULTICA_STATE_DIR="$S19" bash -c '. "'"$SH"'"; ledger_put FIRE-60 "{\"repo\":\"scratch\",\"branch\":\"feat/redo\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/wrong.md\",\"state\":\"current\",\"body\":\"the wrong approach\"}]}"'

printf 'the right approach\n' | ( cd "$g19" && MULTICA_STATE_DIR="$S19" PATH="$BIN19:$PATH" bash "$SH" \
  replan s9 --plan docs/p/right.md ) >/dev/null 2>&1

check "the abandoned plan is superseded, not gone" \
  "$(MULTICA_STATE_DIR="$S19" bash -c '. "'"$SH"'"; plan_entries FIRE-60 | jq -r ".[0].state"')" "superseded"
contains "the wrong approach" "$(cat "$DESC19")" \
  && ok "the superseded plan still appears in the body" || bad "replan destroyed the superseded plan"
contains "the right approach" "$(cat "$DESC19")" && ok "the new plan is in the body" || bad "new plan missing"
check "exactly one /iso-write line after a replan" "$(grep -c '^/iso-write ' "$DESC19")" "1"
contains "/iso-write docs/p/right.md" "$(cat "$DESC19")" \
  && ok "the runnable command names the new plan" || bad "wrong plan in the /iso-write line"
grep -q 'issue status FIRE-60 todo' "$CALLS19" && ok "replan returns the ticket to todo" || bad "replan did not move to todo"
rm -rf "$S19" "$BIN19" "$g19"

echo "open redirects on a held branch"
S20=$(mktemp -d); BIN20=$(mktemp -d); g20=$(mktemp -d)
CALLS20="$S20/calls"; DESC20="$S20/desc"; : > "$CALLS20"; : > "$DESC20"
cat > "$BIN20/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS20"
case "$1 $2" in
  "issue get")      printf '{"status":"in_review"}' ;;
  "issue update")   cat > "$DESC20" ;;
  "issue create")   cat >/dev/null 2>&1; printf '{"identifier":"FIRE-99"}' ;;
  "project list")   printf '[]' ;;
  "project create") printf '{"id":"p1"}' ;;
  "auth status")    printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN20/multica"
export CALLS20 DESC20
( cd "$g20" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/held )

# THE regression test. The exact FIRE-20/FIRE-21 case: a live ticket already
# holds this branch, and `open` is called anyway.
MULTICA_STATE_DIR="$S20" bash -c '. "'"$SH"'"; ledger_put FIRE-70 "{\"repo\":\"scratch\",\"branch\":\"feat/held\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/first.md\",\"state\":\"current\",\"body\":\"first\"}]}"'
got=$(printf 'second\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s10 "a second title" --plan docs/p/second.md --scope be ) 2>/dev/null)

check "open returns the existing key" "$got" "FIRE-70"
check "open created no second issue"  "$(grep -c 'issue create' "$CALLS20")" "0"
check "the ledger still has one row for this branch" \
  "$(jq -r '[to_entries[] | select(.value.branch=="feat/held")] | length' "$S20/tracked.json")" "1"
check "the second plan landed on the existing ticket" \
  "$(MULTICA_STATE_DIR="$S20" bash -c '. "'"$SH"'"; plan_current FIRE-70')" "docs/p/second.md"
contains "first" "$(cat "$DESC20")" && ok "the first plan survives the redirect" || bad "redirect lost the first plan"
err=$(printf 'x\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s11 "third" --plan docs/p/third.md ) 2>&1 >/dev/null)
contains "FIRE-70" "$err" && ok "the redirect is announced on stderr" || bad "the redirect was silent"
grep -q 'redirect' "$S20/log" && ok "the redirect is logged" || bad "redirect not logged"

# A branch with no live ticket must still create, or open is broken.
( cd "$g20" && git checkout -q -b feat/fresh )
got=$(printf 'body\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s12 "a fresh one" --plan docs/p/fresh.md --scope be ) 2>/dev/null)
check "a free branch still opens a new ticket" "$got" "FIRE-99"

# --intro survives the redirect (addplan renders it) but has nowhere to go on a
# fresh ticket, which has no plan sections for it to introduce. The same command
# line therefore keeps the prose on a held branch and drops it on a free one, so
# the drop is logged: this asserts the log line, not a behaviour change.
( cd "$g20" && git checkout -q -b feat/introless )
: > "$S20/log"
printf 'body\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s14 "introless" --plan docs/p/i.md --intro 'umbrella prose' ) >/dev/null 2>&1
grep -q 'intro ignored' "$S20/log" \
  && ok "a dropped --intro is logged, not silent" \
  || bad "--intro vanished on a fresh ticket with nothing in the log"

# There is no escape hatch. --force-new must be treated as an unknown flag.
: > "$CALLS20"
( cd "$g20" && git checkout -q feat/held )
got=$(printf 'x\n' | ( cd "$g20" && MULTICA_STATE_DIR="$S20" PATH="$BIN20:$PATH" bash "$SH" \
  open s13 "forced" --force-new --plan docs/p/forced.md ) 2>/dev/null)
check "--force-new does not create a second ticket" "$(grep -c 'issue create' "$CALLS20")" "0"
check "--force-new still redirects" "$got" "FIRE-70"
rm -rf "$S20" "$BIN20" "$g20"

echo "umbrella title"
S21=$(mktemp -d); BIN21=$(mktemp -d); g21=$(mktemp -d)
CALLS21="$S21/calls"; : > "$CALLS21"
cat > "$BIN21/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS21"
case "$1 $2" in
  "issue get")    printf '{"status":"in_review"}' ;;
  "issue update") cat >/dev/null 2>&1 ;;
  "auth status")  printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN21/multica"
export CALLS21
( cd "$g21" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x && git checkout -q -b feat/umb )
MULTICA_STATE_DIR="$S21" bash -c '. "'"$SH"'"; ledger_put FIRE-80 "{\"repo\":\"scratch\",\"branch\":\"feat/umb\",\"opened_by\":\"claude\",\"plan\":[{\"path\":\"docs/p/a.md\",\"state\":\"current\",\"body\":\"a\"}]}"'

printf 'b\n' | ( cd "$g21" && MULTICA_STATE_DIR="$S21" PATH="$BIN21:$PATH" bash "$SH" \
  addplan s14 --plan docs/p/b.md ) >/dev/null 2>&1
grep -q -- '--title' "$CALLS21" && bad "renamed the ticket without being asked" || ok "no --title means no rename"

: > "$CALLS21"
printf 'c\n' | ( cd "$g21" && MULTICA_STATE_DIR="$S21" PATH="$BIN21:$PATH" bash "$SH" \
  addplan s15 --plan docs/p/c.md --title "The script layer" ) >/dev/null 2>&1
grep -q -- 'issue update FIRE-80 --title The script layer' "$CALLS21" \
  && ok "an explicit --title renames the ticket" || bad "--title did not rename"
grep -q -- '--no-start' "$CALLS21" && ok "the rename cannot start an agent" || bad "rename missing --no-start"

# A redirect must never rename: the incoming title describes one plan, and the
# ticket it lands on already covers several.
: > "$CALLS21"
printf 'd\n' | ( cd "$g21" && MULTICA_STATE_DIR="$S21" PATH="$BIN21:$PATH" bash "$SH" \
  open s16 "only the newest plan" --plan docs/p/d.md ) >/dev/null 2>&1
grep -q -- '--title' "$CALLS21" && bad "the redirect renamed the ticket" || ok "a redirect leaves the title alone"
rm -rf "$S21" "$BIN21" "$g21"

echo "honest status writes"
S22=$(mktemp -d); BIN22=$(mktemp -d); g22=$(mktemp -d)
CALLS22="$S22/calls"; : > "$CALLS22"
# The board accepts the write and then does not move - exactly the FIRE-19 shape.
cat > "$BIN22/multica" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS22"
case "$1 $2" in
  "issue get")   printf '{"status":"in_review"}' ;;
  "auth status") printf 'User: Isaia Riva (x)\n' >&2 ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$BIN22/multica"
export CALLS22
( cd "$g22" && git init -q -b main . && git remote add origin https://github.com/IsaiaScope/scratch.git \
  && git commit -q --allow-empty -m x )
rc=$( cd "$g22" && MULTICA_STATE_DIR="$S22" PATH="$BIN22:$PATH" bash -c '. "'"$SH"'"; set_status FIRE-19 done; echo $?' )
check "a status that did not stick reports failure" "$rc" "1"
grep -q 'FIRE-19' "$S22/log" && ok "the refused transition is logged" || bad "a silent failed transition"

# Outside a repo the script still exits 0, but no longer vanishes without trace.
out=$( cd / && MULTICA_STATE_DIR="$S22" PATH="$BIN22:/usr/bin:/bin" bash "$SH" ticket-for-branch >/dev/null 2>&1; echo $? )
check "outside a repo still exits 0" "$out" "0"
grep -q 'not a git repo' "$S22/log" && ok "a non-repo invocation is logged" || bad "non-repo invocation is invisible"
rm -rf "$S22" "$BIN22" "$g22"
echo "exit contract"
PATH=/usr/bin:/bin bash "$SH" end </dev/null >/dev/null 2>&1
check "end with no multica/gh on PATH exits 0" "$?" "0"
PATH=/usr/bin:/bin bash "$SH" bogus-subcommand >/dev/null 2>&1
check "unknown subcommand exits 0" "$?" "0"
bash "$SH" >/dev/null 2>&1
check "no subcommand exits 0" "$?" "0"

echo "end"
S2=$(mktemp -d)
printf '{"issue":"WOR-43"}' > "$S2/session-s3.json"
printf '{"session_id":"s3"}' | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" end >/dev/null 2>&1
[ -f "$S2/session-s3.json" ] && bad "end left the session file behind" || ok "end removes the session file"

printf '{"session_id":"s9"}' | MULTICA_STATE_DIR="$S2" PATH=/usr/bin:/bin bash "$SH" end >/dev/null 2>&1
check "end on an unbound session exits 0" "$?" "0"

printf 'not json at all' | MULTICA_STATE_DIR="$S2" bash "$SH" end >/dev/null 2>&1
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
# After the adapter split the string lives in adapters/multica.sh, not here.
# Grepping $SH would match nothing and pass vacuously — the exact failure this
# assertion exists to prevent.
ADAPTER="$(dirname "$SH")/adapters/multica.sh"
_writes=$(grep -c "issue status" "$ADAPTER")
[ "$_writes" -gt 0 ] && ok "the status-write grep still matches something" \
                     || bad "status-write grep matches nothing — assertion is vacuous"
grep -n "multica issue status" "$ADAPTER" | grep -qv -- "--no-start" \
  && bad "a status write is missing --no-start" || ok "every status write passes --no-start"
rm -rf "$S3"

echo "reconcile guards"
S4=$(mktemp -d); rr=$(mktemp -d)
( cd "$rr" && git init -q -b main . && git commit -q --allow-empty -m x && git branch dev )
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-100 "{\"repo\":\"scratch\",\"branch\":\"ghost\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-101 "{\"repo\":\"scratch\",\"branch\":\"ghost\",\"project\":\"p\",\"opened_by\":\"iso\"}"'
check "two ledger rows seeded" "$(jq -r 'keys|length' "$S4/tracked.json")" "2"

( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH=/usr/bin:/bin bash "$SH" reconcile ) >/dev/null 2>&1
check "reconcile without gh exits 0" "$?" "0"
grep -q "gh unavailable" "$S4/log" && ok "interlock logged" || bad "interlock not logged"
grep -q -- "-> cancelled" "$S4/log" && bad "cancelled while gh was unavailable" || ok "no cancellation without gh"
check "claude-owned row survives (gh down)" "$(jq -r '."WOR-100".opened_by' "$S4/tracked.json")" "claude"
check "iso-owned row survives"              "$(jq -r '."WOR-101".opened_by' "$S4/tracked.json")" "iso"
grep -q "not cancelling" "$S4/log" && ok "deferral was logged per row" || bad "deferral not logged"

# A row whose branch IS the integration branch must never be touched.
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-102 "{\"repo\":\"scratch\",\"branch\":\"dev\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH=/usr/bin:/bin bash "$SH" reconcile ) >/dev/null 2>&1
check "integration-branch row skipped" "$(jq -r 'has("WOR-102")' "$S4/tracked.json")" "true"

# A commitless branch points at the integration tip, so `merge-base --is-ancestor`
# is vacuously true. Closing on that marks work `done` that never shipped.
# multica must be stubbed: without it set_status fails and `&& ledger_del` hides
# the bug behind a missing binary.
MB=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 0\n' > "$MB/multica"; chmod +x "$MB/multica"
( cd "$rr" && git branch feat/empty )   # same tip as dev — nothing committed on it
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-103 "{\"repo\":\"scratch\",\"branch\":\"feat/empty\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH="$MB:/usr/bin:/bin" bash "$SH" reconcile ) >/dev/null 2>&1
check "commitless branch not closed" "$(jq -r 'has("WOR-103")' "$S4/tracked.json")" "true"
grep -q 'WOR-103 -> done' "$S4/log" && bad "closed a branch with no commits" || ok "no done for a commitless branch"

# The other half: a branch that really did land must still close.
( cd "$rr" && git checkout -q -b feat/landed dev && git commit -q --allow-empty -m shipped \
    && git checkout -q dev && git merge -q --no-ff -m merge feat/landed )
MULTICA_STATE_DIR="$S4" bash -c '. "'"$SH"'"; ledger_put WOR-104 "{\"repo\":\"scratch\",\"branch\":\"feat/landed\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
( cd "$rr" && MULTICA_STATE_DIR="$S4" PATH="$MB:/usr/bin:/bin" bash "$SH" reconcile ) >/dev/null 2>&1
check "genuinely merged branch still closes" "$(jq -r 'has("WOR-104")' "$S4/tracked.json")" "false"
rm -rf "$MB"

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

rm -rf "$S4"

echo "one ledger, many repos"
# The ledger is a single file shared by every checkout on the machine, so every
# row is offered to every reconcile run. A foreign row's branch does not exist
# here, which the cancellation rule reads as "gone" - that is how a session
# start in one repo cancelled a live ticket in another, and how an unscoped
# branch lookup wrote one repo's branch name onto the other repo's ticket.
# Both stubs are required: with no gh there is no cancellation to guard against,
# and with no multica set_status fails and the row survives for the wrong reason.
S6=$(mktemp -d); GB=$(mktemp -d)
printf '#!/usr/bin/env bash\nprintf "[]"\n' > "$GB/gh";      chmod +x "$GB/gh"
printf '#!/usr/bin/env bash\nexit 0\n'      > "$GB/multica"; chmod +x "$GB/multica"
# Same branch name in both rows, because that is the real collision: every repo
# has a dev, and a row parked on one matched whoever asked first.
MULTICA_STATE_DIR="$S6" bash -c '. "'"$SH"'"; ledger_put FAR-1 "{\"repo\":\"elsewhere\",\"branch\":\"feat/shared\",\"project\":\"p\",\"opened_by\":\"claude\"}"'
MULTICA_STATE_DIR="$S6" bash -c '. "'"$SH"'"; ledger_put NEAR-1 "{\"repo\":\"scratch\",\"branch\":\"feat/shared\",\"project\":\"p\",\"opened_by\":\"claude\"}"'

check "a shared branch name resolves to this repo's ticket" \
  "$( cd "$rr" && MULTICA_STATE_DIR="$S6" bash -c '. "'"$SH"'"; ticket_for feat/shared' )" "NEAR-1"
check "a branch only another repo holds resolves to nothing" \
  "$( cd "$rr" && MULTICA_STATE_DIR="$S6" bash -c '. "'"$SH"'"; ledger_put FAR-2 "{\"repo\":\"elsewhere\",\"branch\":\"feat/lonely\",\"project\":\"p\",\"opened_by\":\"claude\"}"; ticket_for feat/lonely' )" ""

( cd "$rr" && MULTICA_STATE_DIR="$S6" PATH="$GB:/usr/bin:/bin" bash "$SH" reconcile ) >/dev/null 2>&1
check "another repo's row survives"   "$(jq -r 'has("FAR-1")'  "$S6/tracked.json")" "true"
# The control. Without it the first assertion also passes when cancellation is
# simply broken, which is not what is being fixed.
check "this repo's own row still cancels" "$(jq -r 'has("NEAR-1")' "$S6/tracked.json")" "false"
rm -rf "$S6" "$GB"

rm -rf "$rr"

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

echo "branch on the ticket"
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

# --parent is retired: one plan, one ticket. A stale flag left in a caller must be
# ignored, never forwarded to the board.
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open s4 "t" --parent FIRE-1 --scope doc </dev/null ) >/dev/null 2>&1
grep -q -- '--parent' "$STUB_CALLS" && bad "stale --parent forwarded" || ok "stale --parent ignored"

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
grep -qE '^cd /.* && claude --resume r1 ' "$STUB_DESC" \
  && ok "resume cds into the repo first" || bad "resume missing repo path"
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
# --stage grouped sub-issues into ordered barriers. With no sub-issues there is
# nothing to order, so the flag is retired and must reach no board.
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S7" PATH="$BIN7:$PATH" bash "$SH" \
    open st1 "t" --stage 2 </dev/null ) >/dev/null 2>&1
grep -q -- '--stage' "$STUB_CALLS" && bad "stale --stage forwarded" || ok "stale --stage ignored"
check "a stale --stage still opens the ticket" "$(grep -c 'issue create' "$STUB_CALLS")" "1"
rm -rf "$S7" "$BIN7" "$g"

echo "retro (merge comment + close)"
S11=$(mktemp -d); BIN11=$(mktemp -d)
cat > "$BIN11/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
case "$1 $2" in
  "issue children") echo '[{"identifier":"FIRE-21"},{"identifier":"FIRE-22"}]'; exit 0 ;;
esac
if [ "$1 $2 $3" = "issue comment add" ]; then
  { echo "=== comment $4 ==="; cat; echo; } >> "$STUB_DESC"; exit 0
fi
exit 0
STUB
chmod +x "$BIN11/multica"
export STUB_CALLS="$S11/calls" STUB_DESC="$S11/desc"
g11=$(mktemp -d); ( cd "$g11" && git init -q -b main . && git commit -q --allow-empty -m x )
P11='docs/superpowers/plans/2026-03-03-feat-retro.md'
MULTICA_STATE_DIR="$S11" bash -c '. "'"$SH"'"; ledger_put FIRE-20 "{\"repo\":\"scratch\",\"branch\":\"b\",\"project\":\"p\",\"opened_by\":\"claude\",\"plan\":\"'"$P11"'\"}"'

: > "$STUB_CALLS"; : > "$STUB_DESC"
( cd "$g11" && printf '%s\n' \
    '🏁 **Landed** · PR [#42](url)' '- 🔀 moved to a webhook' \
    '- 🐛 signature check widened to 5m' \
    | MULTICA_STATE_DIR="$S11" PATH="$BIN11:/usr/bin:/bin" bash "$SH" retro "$P11" ) >/dev/null 2>&1
check "retro exits 0" "$?" "0"
check "one comment, one ticket" "$(grep -c 'issue comment add' "$STUB_CALLS")" "1"
grep -q '=== comment FIRE-20 ===' "$STUB_DESC" && ok "the ticket got a comment" || bad "the ticket got no comment"
awk '/^=== comment FIRE-20 ===$/{p=1;next} /^=== comment /{p=0} p' "$STUB_DESC" | grep -q 'Landed' \
  && ok "comment carries the landing line" || bad "comment body wrong"
# Every line of stdin lands on the one ticket - there is no block splitting left
# to drop the tail on the floor.
awk '/^=== comment FIRE-20 ===$/{p=1;next} /^=== comment /{p=0} p' "$STUB_DESC" | grep -q 'signature check' \
  && ok "the whole body reaches the ticket" || bad "body truncated at a separator"
check "the ticket closed" "$(grep -c 'issue status FIRE-20 done --no-start' "$STUB_CALLS")" "1"
check "ledger row deleted" "$(jq -r 'has("FIRE-20")' "$S11/tracked.json")" "false"

# Same trust boundary as every other outbound body.
: > "$STUB_CALLS"; : > "$STUB_DESC"
MULTICA_STATE_DIR="$S11" bash -c '. "'"$SH"'"; ledger_put FIRE-30 "{\"repo\":\"scratch\",\"branch\":\"b\",\"project\":\"p\",\"opened_by\":\"claude\",\"plan\":\"'"$P11"'\"}"'
( cd "$g11" && printf 'landed with mul_aaaaaaaaaaaaaaaaaaaa inside' \
    | MULTICA_STATE_DIR="$S11" PATH="$BIN11:/usr/bin:/bin" bash "$SH" retro "$P11" ) >/dev/null 2>&1
grep -q 'mul_aaaaaaaaaaaaaaaaaaaa' "$STUB_DESC" && bad "SECRET REACHED A RETRO COMMENT" || ok "retro body is redacted"

: > "$STUB_CALLS"
( cd "$g11" && printf 'x' | MULTICA_STATE_DIR="$S11" PATH="$BIN11:/usr/bin:/bin" bash "$SH" retro docs/plans/nope.md ) >/dev/null 2>&1
check "retro on an unknown plan exits 0" "$?" "0"
grep -q 'issue status' "$STUB_CALLS" && bad "unknown plan still closed something" || ok "unknown plan retro is a no-op"

# /iso-push holds a branch, not a plan path, so the same resolver answers both.
: > "$STUB_CALLS"; : > "$STUB_DESC"
MULTICA_STATE_DIR="$S11" bash -c '. "'"$SH"'"; ledger_put FIRE-40 "{\"repo\":\"scratch\",\"branch\":\"feat/by-branch\",\"project\":\"p\",\"opened_by\":\"claude\",\"plan\":\"\"}"'
( cd "$g11" && printf 'landed' | MULTICA_STATE_DIR="$S11" PATH="$BIN11:/usr/bin:/bin" bash "$SH" retro feat/by-branch ) >/dev/null 2>&1
grep -q 'issue status FIRE-40 done --no-start' "$STUB_CALLS" \
  && ok "a branch resolves the ticket too" || bad "branch did not resolve a ticket"

: > "$STUB_CALLS"
MULTICA_STATE_DIR="$S11" bash -c '. "'"$SH"'"; ledger_put FIRE-41 "{\"repo\":\"scratch\",\"branch\":\"feat/moving\",\"project\":\"p\",\"opened_by\":\"claude\",\"plan\":\"\"}"'
( cd "$g11" && MULTICA_STATE_DIR="$S11" PATH="$BIN11:/usr/bin:/bin" bash "$SH" progress feat/moving ) >/dev/null 2>&1
grep -q 'issue status FIRE-41 in_progress --no-start' "$STUB_CALLS" \
  && ok "progress resolves by branch as well" || bad "progress cannot resolve by branch"
rm -rf "$S11" "$BIN11" "$g11"

echo "replan: a second plan lands on the same ticket"
S12=$(mktemp -d); BIN12=$(mktemp -d)
cat > "$BIN12/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
case "$1 $2" in
  "issue get")    printf '{"status":"%s"}\n' "$(cat "$STUB_ST" 2>/dev/null || echo in_review)"; exit 0 ;;
  "issue update") { echo "=== desc $3 ==="; cat; echo; } >> "$STUB_DESC"; exit 0 ;;
  "issue comment") { echo "=== comment $4 ==="; cat; echo; } >> "$STUB_DESC"; exit 0 ;;
  "project list") echo '[{"id":"proj-id","title":"ai"}]'; exit 0 ;;
  "property list") echo '[]'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN12/multica"
export STUB_CALLS="$S12/calls" STUB_DESC="$S12/desc" STUB_ST="$S12/st"
g12=$(mktemp -d)
( cd "$g12" && git init -q -b main . && git commit -q --allow-empty -m x \
    && git checkout -q -b feat/redo )
P_OLD='docs/superpowers/plans/2026-04-01-feat-first-try.md'
P_NEW='docs/superpowers/plans/2026-04-09-feat-second-try.md'
MULTICA_STATE_DIR="$S12" bash -c '. "'"$SH"'"; ledger_put FIRE-50 "{\"repo\":\"scratch\",\"branch\":\"feat/redo\",\"project\":\"p\",\"opened_by\":\"claude\",\"plan\":\"'"$P_OLD"'\"}"'

# ticket-for-branch names the live ticket so /iso-plan can choose replan over open.
echo in_review > "$STUB_ST"
got=$( cd "$g12" && MULTICA_STATE_DIR="$S12" PATH="$BIN12:$PATH" bash "$SH" ticket-for-branch )
check "ticket-for-branch reports key and status" "$got" "$(printf 'FIRE-50\tin_review')"

: > "$STUB_CALLS"; : > "$STUB_DESC"
got=$( cd "$g12" && printf 'Second attempt. The first plan mis-modelled the queue.\n' \
  | MULTICA_STATE_DIR="$S12" PATH="$BIN12:$PATH" bash "$SH" replan s50 --plan "$P_NEW" )
check "replan returns the same ticket" "$got" "FIRE-50"
check "replan sends the ticket back to todo" \
  "$(grep -c 'issue status FIRE-50 todo --no-start' "$STUB_CALLS")" "1"
grep -q '=== desc FIRE-50 ===' "$STUB_DESC" \
  && ok "the description is replaced, not appended" || bad "description not rewritten"
awk '/^=== desc FIRE-50 ===$/{p=1;next} /^=== /{p=0} p' "$STUB_DESC" | grep -qF -- "/iso-write $P_NEW" \
  && ok "the new body points iso-write at the new plan" || bad "new plan missing from body"
awk '/^=== comment FIRE-50 ===$/{p=1;next} /^=== /{p=0} p' "$STUB_DESC" | grep -qF -- "$P_OLD" \
  && ok "a comment records which plan was superseded" || bad "supersession not recorded"
check "the ledger row now points at the new plan" \
  "$(jq -r '."FIRE-50".plan | map(select(.state=="current")) | .[0].path' "$S12/tracked.json")" "$P_NEW"
# --no-start on the description write too: a board write must never enqueue a run.
grep -q 'issue update FIRE-50 --description-stdin --no-start' "$STUB_CALLS" \
  && ok "the description write carries --no-start" || bad "description write could start an agent"

# Shipped work is not replanned - a new plan against it is new work.
for dead in done cancelled; do
  echo "$dead" > "$STUB_ST"; : > "$STUB_CALLS"
  ( cd "$g12" && printf 'x' | MULTICA_STATE_DIR="$S12" PATH="$BIN12:$PATH" \
      bash "$SH" replan s51 --plan "$P_NEW" ) >/dev/null 2>&1
  check "replan refuses a $dead ticket" "$(grep -c 'issue status' "$STUB_CALLS")" "0"
  got=$( cd "$g12" && MULTICA_STATE_DIR="$S12" PATH="$BIN12:$PATH" bash "$SH" ticket-for-branch )
  check "ticket-for-branch hides a $dead ticket" "$got" ""
done

# No ticket for this branch: say so on stderr and exit 0, so /iso-plan opens one.
echo in_review > "$STUB_ST"
gx=$(mktemp -d); ( cd "$gx" && git init -q -b dev . && git commit -q --allow-empty -m x )
err=$( cd "$gx" && printf 'x' | MULTICA_STATE_DIR="$S12" PATH="$BIN12:$PATH" \
       bash "$SH" replan s52 --plan "$P_NEW" 2>&1 >/dev/null )
case "$err" in *"no live ticket"*) ok "replan with no ticket warns and yields" ;;
  *) bad "replan was silent with no ticket" ;; esac

# An explicit --key wins over the branch lookup.
: > "$STUB_CALLS"
( cd "$gx" && printf 'x' | MULTICA_STATE_DIR="$S12" PATH="$BIN12:$PATH" \
    bash "$SH" replan s53 --plan "$P_NEW" --key FIRE-50 ) >/dev/null 2>&1
grep -q 'issue status FIRE-50 todo --no-start' "$STUB_CALLS" \
  && ok "--key replans off-branch" || bad "--key ignored"
rm -rf "$S12" "$BIN12" "$g12" "$gx"

echo "open: --plan and scope labels (stubbed CLI)"
S10=$(mktemp -d); BIN10=$(mktemp -d)
cat > "$BIN10/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
case "$1 $2" in
  "project list")  echo '[{"id":"proj-id","title":"ai-agent"}]'; exit 0 ;;
  "label list")    echo '[]'; exit 0 ;;
  "label create")  echo '{"id":"label-id"}'; exit 0 ;;
  "issue create")
    n=$(( $(cat "$STUB_N" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_N"
    { echo "=== create $n ==="; cat; echo; } >> "$STUB_DESC"
    echo "{\"identifier\":\"FIRE-$n\"}"; exit 0 ;;
  "issue get")     echo '{"status":"todo"}'; exit 0 ;;
  "auth status")   printf 'User:    Test User (t@e.com)\n' >&2; exit 0 ;;
  "property list") echo '[]'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN10/multica"
export STUB_CALLS="$S10/calls" STUB_DESC="$S10/desc" STUB_N="$S10/n"
g10=$(mktemp -d); ( cd "$g10" && git init -q -b main . && git commit -q --allow-empty -m x \
    && git remote add origin https://github.com/IsaiaScope/ai-agent.git )
P10='docs/superpowers/plans/2026-02-02-feat-wiki.md'

: > "$STUB_CALLS"; : > "$STUB_DESC"; : > "$STUB_N"
# One plan, one ticket. A rich multi-section body is still one ticket, and every
# line of it lands on that ticket - the block separator that used to fan out to
# sub-issues is gone, so a literal `---` in a body is now just a rule.
got=$( cd "$g10" && printf '%s\n' \
  'The wiki moves to explicit ingest. The nightly crawl was implicit and' \
  'silent, so pages created after midnight stayed invisible. From here it is' \
  'a command you run and can watch fail.' '' \
  '| Thing | Before | After |' '|---|---|---|' '| ingest | implicit | explicit |' '' \
  '**Why**' '- the crawl skipped every page created after midnight' \
  | MULTICA_STATE_DIR="$S10" PATH="$BIN10:$PATH" bash "$SH" \
      open w1 "wiki ingest" --scope be --scope doc --plan "$P10" )
check "open returns the ticket identifier" "$got" "FIRE-1"
check "one plan opens exactly one ticket" "$(cat "$STUB_N")" "1"
grep -q -- '--parent' "$STUB_CALLS" && bad "open sent a --parent" || ok "no --parent: there is one ticket"
check "each scope labelled on the one ticket" "$(grep -c 'issue label add FIRE-1 label-id' "$STUB_CALLS")" "2"

check "plan path recorded in the ledger row" \
  "$(jq -r '."FIRE-1".plan | map(select(.state=="current")) | .[0].path' "$S10/tracked.json")" "$P10"

grep -q 'stayed invisible' "$STUB_DESC" \
  && ok "multi-sentence prose reaches the ticket whole" || bad "prose truncated"
grep -q '| ingest | implicit | explicit |' "$STUB_DESC" \
  && ok "a Markdown table survives to the ticket" || bad "table mangled"
grep -q 'the crawl skipped every page' "$STUB_DESC" \
  && ok "the tail of a long body is not dropped" || bad "body truncated mid-way"

# --plan appends a second, separately-copyable block carrying the /iso-write
# invocation, so the plan path is never retyped and never written twice.
grep -qF -- "/iso-write $P10" "$STUB_DESC" \
  && ok "a block invokes iso-write on this plan" || bad "iso-write block lost the plan"
grep -q '^\*\*Resume this session:\*\*' "$STUB_DESC" \
  && ok "the resume command is its own block" || bad "resume block missing"
grep -q '^\*\*Then implement the plan:\*\*' "$STUB_DESC" \
  && ok "the invocation is its own block" || bad "invocation not split out"
# The two must not be fused back into one command line.
grep -qF -- 'skip-permissions "/iso-write' "$STUB_DESC" \
  && bad "resume and invocation fused into one line" || ok "resume and invocation stay separate"

# /iso-plan opens at todo; only /iso-write moves it on.
grep -q 'issue status FIRE-1 in_progress' "$STUB_CALLS" \
  && bad "open promoted the ticket past todo" || ok "open leaves the ticket at todo"

# --sub is retired: it must be ignored, not silently mint a second ticket.
: > "$STUB_CALLS"; : > "$STUB_DESC"; : > "$STUB_N"
( cd "$g10" && MULTICA_STATE_DIR="$S10" PATH="$BIN10:$PATH" bash "$SH" \
    open w3 "t" --sub be </dev/null ) >/dev/null 2>&1
check "a stale --sub creates no second ticket" "$(cat "$STUB_N")" "1"

# bind still promotes: attaching a session to existing work means work resumed.
: > "$STUB_CALLS"
( cd "$g10" && MULTICA_STATE_DIR="$S10" PATH="$BIN10:$PATH" bash "$SH" bind b9 FIRE-77 ) >/dev/null 2>&1
grep -q 'issue status FIRE-77 in_progress --no-start' "$STUB_CALLS" \
  && ok "bind still promotes todo to in_progress" || bad "bind stopped promoting"
rm -rf "$S10" "$BIN10" "$g10"

echo "plan transitions (progress / review / blocked)"
S9=$(mktemp -d); BIN9=$(mktemp -d)
cat > "$BIN9/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
exit 0
STUB
chmod +x "$BIN9/multica"
export STUB_CALLS="$S9/calls"
gp=$(mktemp -d); ( cd "$gp" && git init -q -b main . && git commit -q --allow-empty -m x )
PLAN='docs/superpowers/plans/2026-01-01-feat-x.md'
MULTICA_STATE_DIR="$S9" bash -c '. "'"$SH"'"; ledger_put FIRE-10 "{\"repo\":\"scratch\",\"branch\":\"b\",\"project\":\"p\",\"opened_by\":\"claude\",\"plan\":\"'"$PLAN"'\"}"'

for verb in progress review blocked; do
  case "$verb" in
    progress) want=in_progress ;;
    review)   want=in_review ;;
    blocked)  want=blocked ;;
  esac
  : > "$STUB_CALLS"
  ( cd "$gp" && MULTICA_STATE_DIR="$S9" PATH="$BIN9:/usr/bin:/bin" bash "$SH" "$verb" "$PLAN" ) >/dev/null 2>&1
  check "$verb exits 0" "$?" "0"
  grep -q "issue status FIRE-10 $want --no-start" "$STUB_CALLS" \
    && ok "$verb moves the ticket to $want" || bad "$verb did not move the ticket to $want"
  check "$verb writes exactly one status" \
    "$(grep -c 'issue status' "$STUB_CALLS")" "1"
done

# A miss is logged AND surfaced on stderr. It stayed silent once and the board
# sat at in_progress for a day while the run had long finished.
: > "$STUB_CALLS"
err=$( cd "$gp" && MULTICA_STATE_DIR="$S9" PATH="$BIN9:/usr/bin:/bin" \
       bash "$SH" review docs/superpowers/plans/nope.md 2>&1 >/dev/null )
case "$err" in *"no ticket matches"*) ok "a missed transition warns on stderr" ;;
  *) bad "a missed transition was silent" ;; esac

# A plan path that matches nothing must be silent, not a status write on the
# wrong ticket and not a non-zero exit into a hook.
: > "$STUB_CALLS"
( cd "$gp" && MULTICA_STATE_DIR="$S9" PATH="$BIN9:/usr/bin:/bin" bash "$SH" review docs/plans/nope.md ) >/dev/null 2>&1
check "unknown plan path exits 0" "$?" "0"
grep -q "issue status" "$STUB_CALLS" && bad "unknown plan still wrote a status" || ok "unknown plan path is a no-op"
grep -q "no ticket for plan" "$S9/log" && ok "unresolved plan logged" || bad "unresolved plan not logged"

( cd "$gp" && MULTICA_STATE_DIR="$S9" PATH="$BIN9:/usr/bin:/bin" bash "$SH" progress ) >/dev/null 2>&1
check "progress with no plan path exits 0" "$?" "0"

# /iso-plan may record a relative path and /iso-write hand back an absolute one.
: > "$STUB_CALLS"
( cd "$gp" && MULTICA_STATE_DIR="$S9" PATH="$BIN9:/usr/bin:/bin" bash "$SH" progress "/somewhere/else/$PLAN" ) >/dev/null 2>&1
grep -q "issue status FIRE-10 in_progress" "$STUB_CALLS" \
  && ok "absolute plan path resolves the same ticket" || bad "absolute plan path missed the ticket"
rm -rf "$S9" "$BIN9" "$gp"

echo "rebranch"
# Self-contained fixture: $g and $BIN7 are torn down much earlier in this file.
S13=$(mktemp -d); BIN13=$(mktemp -d)
cat > "$BIN13/multica" <<'STUB'
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
chmod +x "$BIN13/multica"
export STUB_CALLS="$S13/calls" STUB_DESC="$S13/desc"
: > "$STUB_CALLS"; : > "$STUB_DESC"
g13=$(mktemp -d); ( cd "$g13" && git init -q -b main . && git commit -q --allow-empty -m x \
    && git remote add origin https://github.com/IsaiaScope/ai-agent.git )
P13=docs/superpowers/plans/2026-08-27-feat-rb.md

( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" \
    open rb1 "t" --plan "$P13" --scope be </dev/null ) >/dev/null 2>&1
check "fixture ticket opened on the base branch" \
  "$(jq -r '.["FIRE-9"].branch' "$S13/tracked.json")" "main"

: > "$STUB_CALLS"
( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" \
    rebranch "$P13" feat/rb ) >/dev/null 2>&1
check "resolves by plan path" "$(jq -r '.["FIRE-9"].branch' "$S13/tracked.json")" "feat/rb"
grep -q -- 'issue property set FIRE-9 --name Branch --value feat/rb' "$STUB_CALLS" \
  && ok "board follows the ledger" || bad "Branch property not rewritten"
check "the plan key survives the move" "$(jq -r '.["FIRE-9"].plan | map(select(.state=="current")) | .[0].path' "$S13/tracked.json")" "$P13"
check "other row fields survive" "$(jq -r '.["FIRE-9"].opened_by' "$S13/tracked.json")" "claude"

# iso-push holds a branch and never a plan path, so the old branch must resolve.
: > "$STUB_CALLS"
( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" \
    rebranch feat/rb feat/rb2 ) >/dev/null 2>&1
check "resolves by old branch name" "$(jq -r '.["FIRE-9"].branch' "$S13/tracked.json")" "feat/rb2"

# Re-running a skill must not be a state change.
( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" \
    rebranch feat/rb2 feat/rb2 ) >/dev/null 2>&1
check "idempotent" "$(jq -r '.["FIRE-9"].branch' "$S13/tracked.json")" "feat/rb2"

# A miss is normal: a repo with no ticket for this work still has to run.
: > "$STUB_CALLS"
( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" \
    rebranch nothing/here feat/x ) >/dev/null 2>&1
check "miss exits 0" "$?" "0"
grep -q 'property set' "$STUB_CALLS" && bad "wrote to the board on a miss" \
                                     || ok "miss writes nothing"
grep -q 'rebranch: no ticket' "$S13/log" && ok "miss is logged" || bad "miss not logged"

: > "$STUB_CALLS"
( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" \
    rebranch "$P13" ) >/dev/null 2>&1
check "missing new-branch argument exits 0" "$?" "0"
grep -q 'property set' "$STUB_CALLS" && bad "wrote with no new branch" \
                                     || ok "missing argument writes nothing"

echo "branch-of"
check "reads back by plan path" \
  "$( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" branch-of "$P13" )" "feat/rb2"
check "reads back by branch name" \
  "$( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" branch-of feat/rb2 )" "feat/rb2"
check "miss prints nothing" \
  "$( cd "$g13" && MULTICA_STATE_DIR="$S13" PATH="$BIN13:$PATH" bash "$SH" branch-of nothing/here )" ""
rm -rf "$S13" "$BIN13" "$g13"

echo "comment (say something, close nothing)"
S14=$(mktemp -d); BIN14=$(mktemp -d)
cat > "$BIN14/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
if [ "$1 $2 $3" = "issue comment add" ]; then cat >> "$STUB_DESC"; fi
exit 0
STUB
chmod +x "$BIN14/multica"
export STUB_CALLS="$S14/calls" STUB_DESC="$S14/desc"
: > "$STUB_CALLS"; : > "$STUB_DESC"
MULTICA_STATE_DIR="$S14" bash -c '. "'"$SH"'"; ledger_put FIRE-30 "{\"repo\":\"scratch\",\"branch\":\"feat/c\",\"project\":\"p\",\"opened_by\":\"claude\"}"'

printf 'summary line\ntoken mul_abcdefghijklmnop1234\n' \
  | ( MULTICA_STATE_DIR="$S14" PATH="$BIN14:/usr/bin:/bin" bash "$SH" comment FIRE-30 ) >/dev/null 2>&1
check "comment exits 0" "$?" "0"
grep -q 'issue comment add FIRE-30' "$STUB_CALLS" \
  && ok "comment reached the board" || bad "comment never reached the board"
grep -q 'summary line' "$STUB_DESC" \
  && ok "the body arrived" || bad "the body did not arrive"
# The reason this goes through redact: a phase transcript can quote anything the
# working tree holds, and the board is read by other people.
grep -q 'mul_abcdefghijklmnop1234' "$STUB_DESC" \
  && bad "a token reached the board unredacted" || ok "the body was redacted"
# The one thing that separates comment from retro, which is otherwise the same
# shape: retro closes the ticket and drops the row, comment must do neither.
check "the ticket is still tracked" \
  "$(MULTICA_STATE_DIR="$S14" bash -c '. "'"$SH"'"; ledger_get FIRE-30' | jq -r '.branch // ""')" "feat/c"
[ "$(grep -c 'status' "$STUB_CALLS")" = "0" ] \
  && ok "no status transition was attempted" || bad "comment moved the ticket"

: > "$STUB_CALLS"
printf 'x\n' | ( MULTICA_STATE_DIR="$S14" PATH="$BIN14:/usr/bin:/bin" bash "$SH" comment ) >/dev/null 2>&1
check "a missing key exits 0" "$?" "0"
[ -s "$STUB_CALLS" ] && bad "a missing key still called the board" \
  || ok "a missing key writes nothing"
rm -rf "$S14" "$BIN14"

rm -rf "$tmp" "$r"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

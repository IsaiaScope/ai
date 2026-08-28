#!/usr/bin/env bash
# notebook.sh orchestrates correctly against a stub CLI. Never calls NotebookLM.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Stub: records every invocation, answers the few reads notebook.sh makes.
cat > "$T/nlm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$NLM_LOG"
case "$1 ${2:-}" in
  "create "*)        echo '{"notebook":{"id":"nb-test-123","title":"T"},"active_notebook_id":"nb-test-123"}' ;;
  "source add"*)     echo '{"id":"src-1"}' ;;
  "source list")     echo '[{"id":"src-1","title":"Attention Is All You Need"}]' ;;
  "source guide")    echo '{"summary":"Transformer.","keywords":["attention"],"topics":["AI"]}' ;;
  "source add-research") echo '{"status":"ok","imported":7}' ;;
  "list "*|"list")   if [ -n "${NLM_UNAUTH:-}" ]; then
                       echo '{"error":true,"code":"UNEXPECTED_ERROR","message":"Unexpected error: Authentication expired or invalid."}'
                     else echo '[]'; fi ;;
  "ask "*|"ask")     printf '1) Primo titolo\n2) Secondo titolo [1]\n3) Da 43.000 a meno di 1\\$ per l'"'"'IA\n4) Quarto titolo\n5) Quinto titolo\n' ;;
  "rename "*)        echo '{"ok":true}' ;;
  *)                 echo '{}' ;;
esac
STUB
chmod +x "$T/nlm"
export NLM_BIN="$T/nlm" NLM_LOG="$T/log"

out=$(./notebook.sh "guarda https://youtu.be/abc e spiega i transformer" --title "Test" 2>&1)
code=$?
[ "$code" -eq 0 ] || { echo "FAIL: notebook.sh exited $code: $out"; rc=1; }
printf '%s' "$out" | grep -q 'nb-test-123' || { echo "FAIL: did not print the notebook id"; rc=1; }

log=$(cat "$NLM_LOG" 2>/dev/null)
printf '%s' "$log" | grep -q 'create'                    || { echo "FAIL: never created a notebook"; rc=1; }
printf '%s' "$log" | grep -q 'source add .*youtu.be/abc' || { echo "FAIL: never added the YouTube source"; rc=1; }
printf '%s' "$log" | grep -q 'source guide'              || { echo "FAIL: never read a Source Guide"; rc=1; }
printf '%s' "$log" | grep -q 'add-research'              || { echo "FAIL: never ran deep research"; rc=1; }
printf '%s' "$log" | grep -q -- '--mode deep'            || { echo "FAIL: research was not deep mode"; rc=1; }
to=$(printf '%s' "$log" | sed -nE 's/.*--timeout ([0-9]+).*/\1/p' | head -1)
[ -n "$to" ] && [ "$to" -ge 86400 ] || { echo "FAIL: research timeout not effectively uncapped (got '${to:-none}')"; rc=1; }
printf '%s' "$log" | grep -q 'ask'                       || { echo "FAIL: never asked for title suggestions"; rc=1; }
printf '%s' "$log" | grep -q -- '--save-as-note'         || { echo "FAIL: suggestions not saved to the notebook"; rc=1; }
printf '%s' "$out" | grep -q 'Primo titolo'              || { echo "FAIL: did not show the suggested titles"; rc=1; }
printf '%s' "$out" | grep -q 'Quinto titolo'             || { echo "FAIL: did not show all five"; rc=1; }
printf '%s' "$out" | grep -q 'meno di 1\$ per' || { echo "FAIL: markdown escapes not stripped from titles"; rc=1; }
printf '%s' "$out" | grep -q '1\\\\\$' && { echo "FAIL: backslash leaked into a title"; rc=1; }
printf '%s' "$out" | grep -q 'Secondo titolo \[1\]'      && { echo "FAIL: citation markers not stripped"; rc=1; }
printf '%s' "$log" | grep -q -- '--import-all'           || { echo "FAIL: did not import results"; rc=1; }
printf '%s' "$log" | grep -qi 'codex'                    && { echo "FAIL: still invokes Codex"; rc=1; }

# --fast opts down; the timeout stays, since fast can still exceed the legacy cap.
: > "$NLM_LOG"
./notebook.sh "solo testo" --title "T2" --fast >/dev/null 2>&1
grep -q -- '--mode fast' "$NLM_LOG" || { echo "FAIL: --fast did not select fast mode"; rc=1; }

# Prose-only input must still research.
: > "$NLM_LOG"
./notebook.sh "come funziona un LLM" --title "T3" >/dev/null 2>&1
grep -q 'add-research' "$NLM_LOG" || { echo "FAIL: prose-only input skipped research"; rc=1; }


# An auto-derived title is replaced by the first suggestion; non-TTY never prompts.
: > "$NLM_LOG"
./notebook.sh "come funziona un LLM" >/dev/null 2>&1
grep -q 'rename Primo titolo' "$NLM_LOG" || { echo "FAIL: auto-titled notebook was not renamed to the top suggestion"; rc=1; }

# An explicit --title is the user's choice and is never overwritten.
: > "$NLM_LOG"
./notebook.sh "come funziona un LLM" --title "Titolo mio" >/dev/null 2>&1
grep -q 'rename' "$NLM_LOG" && { echo "FAIL: --title was overwritten by a suggestion"; rc=1; }
grep -q 'ask' "$NLM_LOG" || { echo "FAIL: --title suppressed the suggestions entirely"; rc=1; }

# No collection configured -> never touch collections. The skill ships without
# one, so an unconfigured run must not invent a destination.
: > "$NLM_LOG"
(unset NOTEBOOKLM_COLLECTION; ./notebook.sh "x" --title "T4" >/dev/null 2>&1)
grep -q 'collection add' "$NLM_LOG" && { echo "FAIL: filed to a collection when none was configured"; rc=1; }

# Flag and env var both file the notebook.
: > "$NLM_LOG"
./notebook.sh "x" --title "T5" --collection social >/dev/null 2>&1
grep -q 'collection add social nb-test-123' "$NLM_LOG" \
  || { echo "FAIL: --collection did not file the notebook"; rc=1; }
# Filed before research: a run that dies mid-research is still findable.
awk '/collection add/{c=NR} /add-research/{r=NR} END{exit !(c && r && c<r)}' "$NLM_LOG" \
  || { echo "FAIL: collection add does not precede research"; rc=1; }

: > "$NLM_LOG"
NOTEBOOKLM_COLLECTION=social ./notebook.sh "x" --title "T6" >/dev/null 2>&1
grep -q 'collection add social' "$NLM_LOG" || { echo "FAIL: NOTEBOOKLM_COLLECTION ignored"; rc=1; }

# A bad collection name warns but must never sink the run: the research is the
# expensive part and a mistyped name is no reason to throw it away.
cat > "$T/nlm-badcoll" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$NLM_LOG"
if [ "$1 ${2:-}" = "collection add" ]; then echo "no such collection" >&2; exit 1; fi
case "$1 ${2:-}" in
  "create "*)      echo '{"notebook":{"id":"nb-test-123"},"active_notebook_id":"nb-test-123"}' ;;
  "list "*|"list") echo '[]' ;;
  "ask "*|"ask")   printf '1) Uno\n2) Due\n3) Tre\n4) Quattro\n5) Cinque\n' ;;
  *)               echo '{}' ;;
esac
STUB
chmod +x "$T/nlm-badcoll"
: > "$NLM_LOG"
out=$(NLM_BIN="$T/nlm-badcoll" ./notebook.sh "x" --title "T7" --collection nope 2>&1); code=$?
[ "$code" -eq 0 ] || { echo "FAIL: a bad collection name killed the run (exit $code)"; rc=1; }
printf '%s' "$out" | grep -q 'warn.*collection' || { echo "FAIL: no warning for a bad collection"; rc=1; }
grep -q 'add-research' "$NLM_LOG" || { echo "FAIL: research skipped after a collection failure"; rc=1; }


# Expired auth is refused up front, before anything is created.
: > "$NLM_LOG"
out=$(NLM_UNAUTH=1 ./notebook.sh "qualcosa" --title "T" 2>&1); code=$?
[ "$code" -ne 0 ] || { echo "FAIL: expired auth did not halt the run"; rc=1; }
printf '%s' "$out" | grep -q 'notebooklm login' || { echo "FAIL: does not name the login command: $out"; rc=1; }
grep -q 'create' "$NLM_LOG" && { echo "FAIL: created a notebook despite expired auth"; rc=1; }

# The gate is a real API call, not `doctor` -- a local cookie can look fine
# while the session is dead server-side.
grep -v '^[[:space:]]*#' ./notebook.sh | grep -qE '(nlm|notebooklm) doctor' \
  && { echo "FAIL: auth gate relies on doctor"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: notebook.sh"
exit "$rc"

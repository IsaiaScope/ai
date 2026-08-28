#!/usr/bin/env bash
# Build a researched NotebookLM notebook from one free-form input.
#
# The input is whatever the user typed: any mix of URLs (YouTube, GitHub, an
# article, anything) and prose explaining what they want. URLs become sources;
# their Source Guides plus the prose compose a deep-research query that
# NotebookLM runs itself. No agent research pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Every CLI call goes through this so tests can substitute a stub.
NLM_BIN="${NLM_BIN:-notebooklm}"
nlm() { "$NLM_BIN" "$@"; }

# Auth is checked with a real read, never with `notebooklm doctor`: doctor only
# reports that a local SID cookie exists, and a cookie sitting on disk looks
# identical whether or not Google still honours it. An expired session passes
# doctor and then fails on the first real call -- after a notebook was created.
require_auth() {
  local out
  out=$(nlm list --json 2>&1) || true
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)                      # not an error object; let the run proceed
sys.exit(1 if isinstance(d, dict) and d.get("error") else 0)
' && return 0
  die "NotebookLM is not authenticated. The local cookie can look fine while the session is dead, so this is checked with a real call. Run: notebooklm login --fresh"
}


MODE=deep
TITLE=""
TITLE_GIVEN=0
RAW=""
# Deep research takes as long as it takes. The CLI has no "no limit" value --
# --timeout is an integer -- so this is a ceiling no real run reaches, chosen to
# stop the wait loop from ever being the thing that abandons a live research.
# The old 1800 was already a workaround for a 5-minute default that gave up
# mid-flight and left NotebookLM showing an unanswered "Add sources?" modal.
RESEARCH_TIMEOUT="${RESEARCH_TIMEOUT:-86400}"
# Which NotebookLM collection new notebooks join. Unset means none: a collection
# name is personal, so this skill ships without one rather than guessing.
COLLECTION="${NOTEBOOKLM_COLLECTION:-}"

die() { printf 'social-notebooklm: %s\n' "$1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fast)  MODE=fast; shift ;;
    --title) TITLE="${2:-}"; TITLE_GIVEN=1; shift 2 ;;
    --title=*) TITLE="${1#--title=}"; TITLE_GIVEN=1; shift ;;
    --collection) COLLECTION="${2:-}"; shift 2 ;;
    --collection=*) COLLECTION="${1#--collection=}"; shift ;;
    -*)      die "unknown flag: $1" ;;
    *)       RAW="${RAW:+$RAW }$1"; shift ;;
  esac
done
[ -n "$RAW" ] || die "nothing to research -- pass a topic, one or more URLs, or both."

require_auth

# Asked AFTER research, never from the raw input: by then the notebook has read
# its sources and whatever the web search imported, so it knows the topic far
# better than the line that was typed to start it.
TITLES_PROMPT="Proponi 5 titoli in italiano per un video YouTube su questo argomento, basandoti SOLO sulle fonti di questo notebook. Devono funzionare come titoli social: concreti, incuriosire senza clickbait vuoto, massimo 60 caratteri, nessun due punti finale, nessun numero di citazione. Rispondi SOLO con 5 righe numerate nel formato '1) titolo', senza altro testo."

suggest_titles() {
  local answer titles n pick reply chosen
  printf '%s' "$TITLES_PROMPT" > "$TMP/titles_prompt.txt"
  answer=$(nlm ask --prompt-file "$TMP/titles_prompt.txt" -n "$NB" \
             --save-as-note --note-title "Titoli proposti" 2>/dev/null) || return 0

  # Keep only the numbered lines; drop the numbering, any [1]/[1-3] markers, and
  # the markdown backslash-escapes NotebookLM puts before punctuation (1\$).
  titles=$(printf '%s\n' "$answer" \
    | sed -E 's/\[[0-9]+(-[0-9]+)?\]//g' \
    | grep -E '^[[:space:]]*[0-9]+[).]' \
    | sed -E 's/^[[:space:]]*[0-9]+[).][[:space:]]*//; s/[[:space:]]+$//' \
    | sed -E 's/\\([^a-zA-Z0-9])/\1/g' \
    | grep -v '^$') || true
  [ -n "$titles" ] || { printf '  warn   no title suggestions parsed\n' >&2; return 0; }

  n=$(printf '%s\n' "$titles" | wc -l | tr -d ' ')
  printf '\n  Titoli suggeriti:\n' >&2
  printf '%s\n' "$titles" | nl -w4 -s') ' >&2

  # A suggestion never overwrites a title the user chose themselves.
  [ "$TITLE_GIVEN" -eq 1 ] && { printf '\n  (titolo esplicito: %s)\n' "$TITLE" >&2; return 0; }

  pick=1
  # Only prompt when someone is there to answer. Spawned unattended by
  # social-new-video there is no tty, and a read would hang the whole run.
  if [ -t 0 ]; then
    printf '\n  Scegli [1-%s, invio = 1]: ' "$n" >&2
    read -r reply || reply=""
    case "$reply" in
      ''|*[!0-9]*) pick=1 ;;
      *) { [ "$reply" -ge 1 ] && [ "$reply" -le "$n" ]; } && pick="$reply" ;;
    esac
  fi
  chosen=$(printf '%s\n' "$titles" | sed -n "${pick}p")
  [ -n "$chosen" ] || return 0
  if nlm rename "$chosen" -n "$NB" >/dev/null 2>&1; then
    printf '  ok     titolo: %s\n' "$chosen" >&2
  else
    printf '  warn   could not rename the notebook\n' >&2
  fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# 1 -- split the input.
printf '%s' "$RAW" | python3 "$HERE/parse_input.py" > "$TMP/parsed.json"
python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prose"])' \
  "$TMP/parsed.json" > "$TMP/prose.txt"
python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["urls"]))' \
  "$TMP/parsed.json" > "$TMP/urls.json"

# 2 -- classify and expand them.
python3 "$HERE/expand_urls.py" < "$TMP/urls.json" > "$TMP/sources.json"

[ -n "$TITLE" ] || TITLE=$(head -c 60 "$TMP/prose.txt")
[ -n "$TITLE" ] || TITLE="Ricerca video"

# 3 -- create the notebook and make it current.
# `|| true`: under `set -e` + pipefail a failing create would abort the script
# here, making the die() below unreachable and the exit silent. Auth expiry is
# the common case and it must say so.
CREATE_OUT=$(nlm create "$TITLE" --use --json 2>&1) || true
NB=$(printf '%s' "$CREATE_OUT" \
     | python3 -c 'import json,sys
# The id has moved between CLI versions: 0.6 returned it top-level, 0.8 nests it
# under "notebook" and also echoes "active_notebook_id". Read all three rather
# than pin one, so an upgrade does not silently break notebook creation.
try: d = json.load(sys.stdin)
except Exception: d = {}
if not isinstance(d, dict) or d.get("error"):
    print("")
else:
    nb = d.get("notebook") or {}
    print(nb.get("id") or d.get("active_notebook_id") or d.get("id") or "")' 2>/dev/null) || true
[ -n "$NB" ] || die "notebook create failed: ${CREATE_OUT:-no output}"
printf 'notebook: %s\n' "$NB" >&2

# Filed right after creation, not at the end: a run that dies during research
# should still leave the notebook where you expect to find it. Never fatal --
# a mistyped collection name is not a reason to throw away the research.
if [ -n "$COLLECTION" ]; then
  if nlm collection add "$COLLECTION" "$NB" >/dev/null 2>&1; then
    printf '  ok     collection %s\n' "$COLLECTION" >&2
  else
    printf '  warn   could not add to collection %s (does it exist?)\n' "$COLLECTION" >&2
  fi
fi

# 4 -- add every URL. Soft failure: one bad link never aborts the run.
python3 -c '
import json,sys
for s in json.load(open(sys.argv[1])):
    print("%s\t%s" % (s["type"], s["url"]))
' "$TMP/sources.json" | while IFS=$'\t' read -r typ url; do
  [ -n "$url" ] || continue
  if nlm source add "$url" --type "$typ" -n "$NB" --json >/dev/null 2>&1; then
    printf '  ok     source %s\n' "$url" >&2
  else
    printf '  warn   could not add %s\n' "$url" >&2
  fi
done

# 5 -- read each Source Guide: NotebookLM's own keywords and topic tags.
nlm source list -n "$NB" --json > "$TMP/list.json" 2>/dev/null || echo '[]' > "$TMP/list.json"
: > "$TMP/guides.jsonl"
python3 -c '
import json,sys
try: rows = json.load(open(sys.argv[1]))
except Exception: rows = []
if isinstance(rows, dict): rows = rows.get("sources", [])
for r in rows: print("%s\t%s" % (r.get("id",""), r.get("title","")))
' "$TMP/list.json" | while IFS=$'\t' read -r sid stitle; do
  [ -n "$sid" ] || continue
  g=$(nlm source guide "$sid" -n "$NB" --json 2>/dev/null) || continue
  printf '%s\n' "$g" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
d["title"] = sys.argv[1]
print(json.dumps(d, ensure_ascii=False))
' "$stitle" >> "$TMP/guides.jsonl"
done
python3 -c '
import json,sys,pathlib
p = pathlib.Path(sys.argv[1])
rows = [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()] if p.exists() else []
print(json.dumps(rows, ensure_ascii=False))
' "$TMP/guides.jsonl" > "$TMP/guides.json"

# 6 -- compose the query and let NotebookLM do the reaching.
python3 "$HERE/build_query.py" "$TMP/prose.txt" "$TMP/guides.json" > "$TMP/query.txt"
printf '  research (%s), up to %ss...\n' "$MODE" "$RESEARCH_TIMEOUT" >&2
nlm source add-research --prompt-file "$TMP/query.txt" \
    -n "$NB" --from web --mode "$MODE" --import-all --cited-only \
    --timeout "$RESEARCH_TIMEOUT" --json >/dev/null 2>&1 \
  || printf '  warn   research did not complete cleanly -- check: notebooklm research status\n' >&2

suggest_titles

printf '%s\n' "$NB"

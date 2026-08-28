#!/usr/bin/env bash

set -uo pipefail


LONG_PROMPT="Scrivi una SCALETTA per un video YouTube in italiano come ELENCO PUNTATO di punti da dire a braccio con parole mie (NON un testo da leggere parola per parola). Usa solo le informazioni nelle fonti di questo notebook; non inventare nulla. Organizza in sezioni: ogni sezione un titolo breve in grassetto; sotto, 3-4 PUNTI CHIAVE come bullet (max ~12 parole, il concetto). SOTTO OGNI punto chiave aggiungi 2-3 SOTTO-BULLET indentati che SVILUPPANO il concetto su piu righe, così da avere abbastanza materiale davanti agli occhi per parlarne senza inventare: uno che SPIEGA il meccanismo o la definizione (come/perché funziona), uno con un ESEMPIO o un DATO CONCRETO ben contestualizzato — non l'esempio nudo: di' cos'è, il numero/la fonte se c'è, e perché dimostra il punto, e facoltativamente uno su perché conta o quale conseguenza ha. I sotto-bullet sono SEMPLICI PUNTI ELENCATI: non numerarli e non etichettarli con (a)/(b)/(c) o lettere o numeri di alcun tipo, solo il punto elenco. REGOLA DELLA SCALA: parti sempre dal semplice. La PRIMA volta che un concetto compare, mettici PRIMA la versione facile o un esempio quotidiano che chi guarda gia' vive (un filtro antispam, le mappe, il correttore del telefono), e SOLO DOPO il nome tecnico. L'approfondimento tecnico viene dopo, e solo dove l'argomento ha davvero qualcosa in piu' da dire: se non ce l'ha, fermati all'esempio. La sezione HOOK in particolare deve aprirsi su qualcosa di concreto e familiare, mai su un termine tecnico nudo. REGOLA FONDAMENTALE: ogni termine tecnico, sigla, legge, teoria, nome proprio o concetto specialistico va SPIEGATO in parole semplici la prima volta che compare, con un breve inciso ('X, cioè ...' / 'X, ovvero ...'), come se chi guarda non sapesse nulla dell'argomento. Non lasciare mai un nome, una sigla o un termine nudi: io devo poterli spiegare a voce partendo da zero. Ogni sotto-bullet è una frase breve e parlabile (max ~22 parole), non un paragrafo: spunti ricchi ma asciutti, niente muri di testo. Il bullet principale è il concetto; i sotto-bullet sono il contesto su cui mi appoggio mentre parlo. Includi una sezione HOOK iniziale e una CTA finale. NIENTE numeri di citazione [1]/[1-3]. Niente frase introduttiva, niente regia."
SHORT_PROMPT="Scrivi una SCALETTA per un Reel/Short verticale in italiano come ELENCO PUNTATO di punti da dire a braccio con parole mie (NON un testo da leggere parola per parola). Usa solo le informazioni nelle fonti di questo notebook; non inventare nulla. Organizza in sezioni: ogni sezione ha un titolo breve in grassetto SU UNA RIGA TUTTA SUA, senza bullet e senza altro testo su quella riga; sotto, i bullet. Servono POCHE sezioni: una HOOK iniziale, 3-4 sezioni di sostanza, una CTA finale. Sotto ogni titolo metti 1-2 PUNTI CHIAVE come bullet (max ~12 parole, il concetto). SOTTO OGNI punto chiave aggiungi 2 SOTTO-BULLET indentati brevi: uno che SPIEGA il concetto in una frase, uno con un ESEMPIO o un DATO CONCRETO ben contestualizzato (cos'e', il numero o la fonte se c'e', e perche' dimostra il punto — non l'esempio nudo). I sotto-bullet sono SEMPLICI PUNTI ELENCATI: non numerarli e non etichettarli con (a)/(b)/(c) o lettere o numeri di alcun tipo, solo il punto elenco. REGOLA DELLA SCALA: parti sempre dal semplice. La PRIMA volta che un concetto compare, mettici PRIMA la versione facile o un esempio quotidiano che chi guarda gia' vive (un filtro antispam, le mappe, il correttore del telefono), e SOLO DOPO il nome tecnico. L'approfondimento tecnico viene dopo, e solo dove l'argomento ha davvero qualcosa in piu' da dire: se non ce l'ha, fermati all'esempio. La sezione HOOK in particolare deve aprirsi su qualcosa di concreto e familiare, mai su un termine tecnico nudo. REGOLA FONDAMENTALE: ogni termine tecnico, sigla, legge, teoria, nome proprio o concetto specialistico va SPIEGATO in parole semplici con un breve inciso ('X, cioe' ...' / 'X, ovvero ...'), come se chi guarda non sapesse nulla dell'argomento. Non lasciare mai un nome, una sigla o un termine nudi. Ogni sotto-bullet e' una frase breve e parlabile (max ~22 parole), non un paragrafo. Tieni il totale corto: e' un Reel da circa 40 secondi. NIENTE numeri di citazione [1]/[1-3]. Niente frase introduttiva, niente regia."

NOTEBOOK_ARG=""
MODE="both"
TMP_DIR=""
NOTEBOOK_ID=""
NOTEBOOK_TITLE=""
OUT_BASE="./content"                    # default base, relative to cwd; override with --out <dir>
AGENT="${AGENT:-codex}"                  # humanizing CLI: codex | claude
HERE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_FILE="./voice/voice.md"           # Voice profile, relative to cwd; override with --voice <file>
OUT_DIR=""
WRITTEN_FILES=""
EDITOR_OK=""
FAILED_LENGTHS=""

usage() {
  echo "  --long|--short        limit the scaletta to one length (default: both)" >&2
  echo "  --out <dir>           base output folder (default: ./content, relative to cwd)" >&2
  echo "  --voice <file>        Voice profile (default: ./voice/voice.md)" >&2
  echo "  --agent codex|claude  CLI used to humanize (default: codex)" >&2
  echo "  folders are named <YYYY-MM-DD>-<notebook title> for chronological order" >&2
}

fail() {
  echo "$1" >&2
  exit 1
}

append_line() {
  if [ -z "$1" ]; then
    printf "%s" "$2"
  else
    printf "%s\n%s" "$1" "$2"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --long)
        [ "$MODE" = "short" ] && fail "social-notebooklm: choose only one of --long or --short."
        MODE="long"
        ;;
      --short)
        [ "$MODE" = "long" ] && fail "social-notebooklm: choose only one of --long or --short."
        MODE="short"
        ;;
      # One shift convention: the loop tail consumes the flag itself, so a
      # two-token form shifts exactly once here and a --flag=value form not at
      # all. --agent and --voice used to `shift 2` on top of the tail shift,
      # which ate the following argument.
      --agent)
        [ "$#" -ge 2 ] || { usage; fail "social-notebooklm: --agent requires codex|claude."; }
        AGENT="$2"; shift ;;
      --agent=*)
        AGENT="${1#--agent=}" ;;
      --voice)
        [ "$#" -ge 2 ] || { usage; fail "social-notebooklm: --voice requires a file."; }
        VOICE_FILE="$2"; shift ;;
      --voice=*)
        VOICE_FILE="${1#--voice=}"
        [ -n "$VOICE_FILE" ] || { usage; fail "social-notebooklm: --voice requires a file."; } ;;
      --out)
        [ "$#" -ge 2 ] || { usage; fail "social-notebooklm: --out requires a directory."; }
        OUT_BASE="$2"; shift ;;
      --out=*)
        OUT_BASE="${1#--out=}"
        [ -n "$OUT_BASE" ] || { usage; fail "social-notebooklm: --out requires a directory."; } ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        usage
        fail "social-notebooklm: unknown flag: $1"
        ;;
      *)
        if [ -z "$NOTEBOOK_ARG" ]; then
          NOTEBOOK_ARG="$1"
        else
          NOTEBOOK_ARG="$NOTEBOOK_ARG $1"
        fi
        ;;
    esac
    shift
  done
}

preflight() {
  # Checked first: a missing dependency must not cost NotebookLM quota.
  command -v "${AGENT_BIN:-$AGENT}" >/dev/null 2>&1 \
    || fail "social-notebooklm: agent CLI not found: $AGENT -- pass --agent claude|codex."
  [ -f "$VOICE_FILE" ] \
    || fail "social-notebooklm: voice profile not found: $VOICE_FILE -- run from a content repo root, or pass --voice <file>."
  command -v notebooklm >/dev/null 2>&1 \
    || fail "notebooklm CLI not found. Install: https://github.com/teng-lin/notebooklm-py"
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 not found."

  # A real read, not a local-cookie check: the cookie on disk looks identical
  # whether or not Google still honours it, so a dead session used to pass here
  # and blow up later -- after quota had been spent.
  notebooklm list --json 2>&1 | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)                      # not an error object; let the run proceed
sys.exit(1 if isinstance(d, dict) and d.get("error") else 0)
' || fail "NotebookLM is not authenticated. Run: notebooklm login --fresh"

  # pwd -P, not the raw path: on macOS $TMPDIR lives under /var, which is a
  # symlink to /private/var, and the unresolved form breaks path comparisons.
  local tmp_root
  tmp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P) \
    || fail "social-notebooklm: unable to resolve temp directory."
  TMP_DIR=$(mktemp -d "$tmp_root/scaletta.XXXXXX") \
    || fail "social-notebooklm: unable to create temp directory."
}

resolve_notebook() {
  local status_file parsed

  if [ -n "$NOTEBOOK_ARG" ]; then
    notebooklm use "$NOTEBOOK_ARG" >/dev/null \
      || fail "social-notebooklm: no notebook — pass an id/title or run 'notebooklm use <id>' first."
  fi

  status_file="$TMP_DIR/status.json"
  notebooklm status --json > "$status_file" 2>/dev/null \
    || fail "social-notebooklm: no notebook — pass an id/title or run 'notebooklm use <id>' first."

  parsed=$(python3 - "$status_file" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
notebook = data.get("notebook") if isinstance(data.get("notebook"), dict) else {}
active = data.get("active_notebook") if isinstance(data.get("active_notebook"), dict) else {}

notebook_id = (
    data.get("notebook_id")
    or data.get("active_notebook_id")
    or notebook.get("notebook_id")
    or notebook.get("id")
    or active.get("notebook_id")
    or active.get("id")
    or ""
)
title = (
    data.get("title")
    or data.get("notebook_title")
    or notebook.get("title")
    or notebook.get("name")
    or active.get("title")
    or active.get("name")
    or ""
)

source_count = None
for key in ("source_count", "sources_count", "num_sources"):
    if isinstance(data.get(key), int):
        source_count = data[key]
        break

source_values = []
for owner in (data, notebook, active):
    if isinstance(owner.get("sources"), list):
        source_values.append(len(owner["sources"]))
    if isinstance(owner.get("source_ids"), list):
        source_values.append(len(owner["source_ids"]))

if source_count is None and source_values:
    source_count = max(source_values)

if not notebook_id or not title:
    sys.exit(2)
if source_count == 0:
    sys.exit(3)

print(notebook_id)
print(title)
PY
  )
  case $? in
    0) ;;
    3) fail "social-notebooklm: notebook empty or not found — nothing to script." ;;
    *) fail "social-notebooklm: no notebook — pass an id/title or run 'notebooklm use <id>' first." ;;
  esac

  # First line is the id, everything after it is the title (which may itself
  # contain newlines). Parameter expansion, not two CPython startups to read
  # two lines of a string the shell is already holding.
  NOTEBOOK_ID=${parsed%%$'\n'*}
  case "$parsed" in
    *$'\n'*) NOTEBOOK_TITLE=${parsed#*$'\n'} ;;
    *)       NOTEBOOK_TITLE="" ;;
  esac

  # Folder name = "<YYYY-MM-DD>-<title>" for chronological ordering, under OUT_BASE.
  OUT_DIR=$(python3 - "$NOTEBOOK_TITLE" "$OUT_BASE" "$(date +%F)" <<'PY'
import os, re, sys
title, base, today = sys.argv[1], sys.argv[2], sys.argv[3]
safe = re.sub(r'\s*[:/]\s*', ' - ', title)
safe = re.sub(r'[\x00-\x1f\x7f]', '-', safe).strip()
safe = re.sub(r'\s+', ' ', safe) or 'notebook'
print(os.path.realpath(os.path.join(os.path.expanduser(base), f"{today} - {safe}")))
PY
  )

  if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
    case "$OUT_DIR" in
      /Volumes/*)
        vol="/Volumes/$(printf '%s' "${OUT_DIR#/Volumes/}" | cut -d/ -f1)"
        [ -d "$vol" ] || fail "social-notebooklm: $vol not mounted."
        ;;
    esac
    fail "social-notebooklm: unable to create output directory: $OUT_DIR"
  fi

}

probe() {
  notebooklm --quiet ask "ok" --timeout 60 --json 2>/dev/null | python3 -c '
import json, sys
try:
    answer = json.load(sys.stdin).get("answer")
except Exception:
    answer = None
sys.exit(0 if answer else 1)
' || fail "NotebookLM non risponde (timeout/rate-limit). Nessun endpoint quota disponibile — riprova."
}

ask_to() {
  local prompt="$1"
  local outfile="$2"
  local i json_file err_file

  for i in 1 2 3; do
    json_file=$(mktemp "$TMP_DIR/ask-json.XXXXXX") || return 1
    err_file=$(mktemp "$TMP_DIR/ask-err.XXXXXX") || return 1

    if notebooklm --quiet ask "$prompt" --timeout 180 --json > "$json_file" 2> "$err_file"; then
      if python3 - "$json_file" > "$outfile" <<'PY'
import json, sys
from pathlib import Path
try:
    answer = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("answer")
except Exception:
    answer = None
if not answer:
    sys.exit(2)
print(answer)
PY
      then
        [ -s "$outfile" ] && return 0
      fi
    fi

    [ "$i" -lt 3 ] && sleep $((i * 8))
  done

  return 1
}

strip_and_write() {
  local ans_file="$1"
  local out_file="$2"
  local kind="$3"
  local today

  today=$(date +%F)
  python3 - "$ans_file" "$out_file" "$NOTEBOOK_TITLE" "$kind" "$today" <<'PY'
import pathlib
import re
import sys

ans, out, title, kind, date = sys.argv[1:6]
t = pathlib.Path(ans).read_text(encoding="utf-8")
t = re.sub(r' ?\[[0-9]+(\s*[,–-]\s*[0-9]+)*\]', '', t)
# Sub-bullets are plain dots. The model labels them "(a) / (b) / (c)" even when
# the prompt never asks for it, so strip the label off the bullet marker rather
# than trusting the instruction: the prompt says don't, this makes sure.
t = re.sub(r'(?m)^(\s*[-*+]\s+)\(?[a-z]\)\s+', r'\1', t)
lines = t.splitlines()
if lines and re.match(r'^\s*(Ecco|Certo|Perfetto|Naturalmente)\b.*:\s*$', lines[0]):
    lines = lines[1:]
body = "\n".join(lines).strip() + "\n"
hdr = f"# {title} — scaletta {kind}\n<!-- focal points + contesto · NotebookLM (solo fonti) · {date} -->\n\n"
pathlib.Path(out).write_text(hdr + body, encoding="utf-8")
PY
}

finish_scaletta() {
  # draft -> humanized -> linted. Bash writes; the agent only returns text.
  # The draft is passed in from the temp dir and the final path is explicit:
  # deriving one from the other would put the deliverable next to the draft.
  local draft="$1" final="$2" tmp
  [ -f "$draft" ] || return 0
  tmp="$TMP_DIR/$(basename "$final").new"
  if humanize "$draft" "$VOICE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$final"
    printf '  ok     %s\n' "$final" >&2
  else
    printf '  warn   humanize failed -- no %s written\n' "$(basename "$final")" >&2
    return 1
  fi
  # Compare against the draft the humanizer was given: the terms are whatever
  # that draft's own HOOK glossed. Nothing is asked of NotebookLM and no term
  # list is written -- this checks the one thing that can regress, the rewrite.
  python3 "$HERE_SCRIPTS/lint_scaletta.py" "$final" --draft "$draft" >&2 || {
    # The lint has already said WHY on stderr -- a dropped gloss, or a HOOK it
    # could not find at all. Restating one cause here sent a reader chasing the
    # wrong one, so name the file and let the lint's own line stand.
    printf '  FAIL   Ramp check failed on %s (see lint_scaletta above)\n' "$final" >&2
    return 1
  }
}

humanize() {
  # Draft in, humanized text out on stdout. The agent never writes a file:
  # bash owns every write, so no permission flags and nothing unattended
  # touching the disk.
  local draft="$1" voice="$2" prompt bin
  [ -f "$draft" ] || { printf 'humanize: no such draft: %s\n' "$draft" >&2; return 1; }
  [ -f "$voice" ] || { printf 'humanize: no such voice profile: %s\n' "$voice" >&2; return 1; }
  prompt=$(cat <<PROMPT
Riscrivi il linguaggio dentro i bullet di questa scaletta perche' suoni come la
persona che parla nel campione di voce qui sotto. NON ristrutturare: mantieni
ogni bullet, ogni livello di annidamento e ogni titolo di sezione in grassetto
esattamente dove sono. I titoli in grassetto e i bullet annidati sono il
formato richiesto di questo documento, non artefatti di scrittura AI.
Non inventare nulla: ogni fatto, numero e nome deve essere gia' nella bozza.
Rispondi SOLO con la scaletta riscritta, senza commenti.

--- CAMPIONE DI VOCE ---
$(cat "$voice")

--- BOZZA ---
$(cat "$draft")
PROMPT
)
  bin="${AGENT_BIN:-}"
  case "${AGENT:-codex}" in
    claude) [ -n "$bin" ] || bin=claude; "$bin" -p "$prompt" --allowed-tools '' </dev/null ;;
    codex)  [ -n "$bin" ] || bin=codex;  "$bin" exec "$prompt" </dev/null ;;
    *)      printf 'humanize: unknown agent: %s\n' "${AGENT:-}" >&2; return 1 ;;
  esac
}

# <kind> <prompt> -- one length, drafted, written, humanized and linted.
# The long and short paths were the same seven lines with the word swapped,
# and had already drifted apart once.
gen() {
  local kind="$1" prompt="$2" ans_file draft_file final_file
  ans_file="$TMP_DIR/answer-$kind.md"
  # The draft is scaffolding, not a deliverable, so it stays in the temp dir:
  # the content folder holds only the two files you actually film from. The
  # lint still reads it -- it is what the humanized text is compared against.
  draft_file="$TMP_DIR/scaletta-$kind.draft.md"
  final_file="$OUT_DIR/scaletta-$kind.md"

  if ask_to "$prompt" "$ans_file"; then
    strip_and_write "$ans_file" "$draft_file" "$kind"
    finish_scaletta "$draft_file" "$final_file" \
      || FAILED_LENGTHS=$(append_line "$FAILED_LENGTHS" "humanize")
    # Listed if it exists: a lint failure still leaves a file worth opening,
    # a humanize failure leaves nothing to list.
    [ -f "$final_file" ] && WRITTEN_FILES=$(append_line "$WRITTEN_FILES" "$final_file")
  else
    FAILED_LENGTHS=$(append_line "$FAILED_LENGTHS" "$kind")
  fi
}

# The Editor stage. Non-fatal by construction: it needs a desktop application
# running, while everything above this point runs headless. A closed Editor
# must never cost a Scaletta that has already been written, humanized and
# linted -- the same policy notebook.sh applies to its collection add.
push_editor() {
  [ -n "${NO_EDITOR:-}" ] && return 0
  [ -n "$WRITTEN_FILES" ] || return 0
  local flag=""
  case "$MODE" in
    long)  flag=--long ;;
    short) flag=--short ;;
  esac
  printf '\n  editor...\n' >&2
  if bash "$HERE_SCRIPTS/editor-script.sh" "$OUT_DIR" $flag; then
    EDITOR_OK=1
  else
    printf '  warn   editor stage failed -- the Scalette are written; is the editor running?\n' >&2
  fi
}

summary() {
  if [ -n "$WRITTEN_FILES" ]; then
    echo "✓ Scaletta pronta (solo contenuto del notebook, punti chiave senza citazioni)."
    echo "  Notebook:  $NOTEBOOK_TITLE ($NOTEBOOK_ID)"
    echo "  File:"
    printf "%s\n" "$WRITTEN_FILES" | while IFS= read -r file; do
      case "$file" in
        *scaletta-long.md) echo "    - $file   (sezioni + bullet)" ;;
        *scaletta-short.md) echo "    - $file  (Reel/Short)" ;;
        *) echo "    - $file" ;;
      esac
    done

    if [ -n "$EDITOR_OK" ]; then
      echo
      echo "  Editor: scene create da $OUT_DIR — apri il progetto e registra."
    fi
    echo
    echo "Apri il file: parla a braccio seguendo i bullet. Rigenera quando vuoi: i file vengono sovrascritti."
  fi

  if [ -n "$FAILED_LENGTHS" ]; then
    echo
    echo "Generazione scaletta saltata dopo 3 tentativi:"
    printf "%s\n" "$FAILED_LENGTHS" | while IFS= read -r length; do
      echo "  - $length"
    done
  fi

}

main() {
  trap '[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"' EXIT
  parse_args "$@"
  preflight
  resolve_notebook
  probe
  case "$MODE" in
    long)  gen long  "$LONG_PROMPT" ;;
    short) gen short "$SHORT_PROMPT" ;;
    both)  gen long  "$LONG_PROMPT"; gen short "$SHORT_PROMPT" ;;
  esac

  push_editor

  summary

  # Success = every requested length was written and none failed.
  [ -z "$FAILED_LENGTHS" ] && [ -n "$WRITTEN_FILES" ]
}

main "$@"

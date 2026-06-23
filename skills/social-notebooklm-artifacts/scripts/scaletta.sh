#!/usr/bin/env bash

set -uo pipefail

LONG_PROMPT="Scrivi una SCALETTA per un video YouTube in italiano come ELENCO PUNTATO di punti da dire a braccio con parole mie (NON un testo da leggere parola per parola). Usa solo le informazioni nelle fonti di questo notebook; non inventare nulla. Organizza in sezioni: ogni sezione un titolo breve in grassetto; sotto, 3-4 PUNTI CHIAVE come bullet (max ~12 parole, il concetto). SOTTO OGNI punto chiave aggiungi 2-3 SOTTO-BULLET indentati che SVILUPPANO il concetto su piu righe, così da avere abbastanza materiale davanti agli occhi per parlarne senza inventare: (a) un sotto-bullet che SPIEGA il meccanismo o la definizione (come/perché funziona), (b) un sotto-bullet con un ESEMPIO o un DATO CONCRETO ben contestualizzato — non l'esempio nudo: di' cos'è, il numero/la fonte se c'è, e perché dimostra il punto, (c) facoltativo: perché conta o quale conseguenza ha. REGOLA FONDAMENTALE: ogni termine tecnico, sigla, legge, teoria, nome proprio o concetto specialistico va SPIEGATO in parole semplici la prima volta che compare, con un breve inciso ('X, cioè ...' / 'X, ovvero ...'), come se chi guarda non sapesse nulla dell'argomento. Non lasciare mai un nome, una sigla o un termine nudi: io devo poterli spiegare a voce partendo da zero. Ogni sotto-bullet è una frase breve e parlabile (max ~22 parole), non un paragrafo: spunti ricchi ma asciutti, niente muri di testo. Il bullet principale è il concetto; i sotto-bullet sono il contesto su cui mi appoggio mentre parlo. Includi una sezione HOOK iniziale e una CTA finale. NIENTE numeri di citazione [1]/[1-3]. Niente frase introduttiva, niente regia."
SHORT_PROMPT="Scrivi una SCALETTA per un Reel/Short verticale in italiano come ELENCO PUNTATO da dire a braccio con parole mie (non un testo da leggere). Solo dalle fonti del notebook, niente invenzioni. Formato: 1 bullet HOOK, 3-4 bullet di sostanza, 1 bullet CTA; per ogni bullet di sostanza aggiungi 2 SOTTO-BULLET indentati brevi: uno che SPIEGA il concetto in una frase, uno con un ESEMPIO o DATO contestualizzato (cos'è + il numero/perché conta, non l'esempio nudo). REGOLA FONDAMENTALE: ogni termine tecnico, sigla, legge, teoria, nome proprio o concetto specialistico va SPIEGATO in parole semplici con un breve inciso ('X, cioè ...'), come se chi guarda non sapesse nulla dell'argomento. Mai un nome, una sigla o un termine nudi: io devo poterli spiegare a voce da zero. Sotto-bullet parlabili (max ~20 parole), un concetto per bullet. NIENTE numeri di citazione [1]/[1-3]. Niente frase introduttiva, niente regia."

NOTEBOOK_ARG=""
MODE="both"
KIND="both"                              # both | scripts | images
TMP_DIR=""
NOTEBOOK_ID=""
NOTEBOOK_TITLE=""
OUT_BASE="/Volumes/Crucial-4T/social"   # default base; override with --out <dir>
OUT_DIR=""
WRITTEN_FILES=""
FAILED_LENGTHS=""
IMAGES_DONE=""
IMAGES_FAILED=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Infographic generation needs the notebooklm-py library (the CLI does NOT
# expose it), so it runs under a dedicated venv python. Override with NBLM_PYTHON.
NBLM_PYTHON="${NBLM_PYTHON:-$HOME/.venvs/nblm/bin/python}"
# Ask the notebook for exactly 4 visual concepts (2x2 matrix), grounded ONLY in
# its sources. One per line, "TITOLO :: dettaglio", no numbering, no preamble.
CONCEPTS_PROMPT="Dalle SOLE fonti di questo notebook, estrai i 4 concetti visivi piu importanti per delle infografiche, dal piu semplice/d'impatto al piu ricco di dettagli. Rispondi SOLO con 4 righe, una per concetto, nel formato esatto 'TITOLO :: dettaglio breve' (il titolo max ~8 parole in italiano, il dettaglio una frase breve di contesto in italiano). NIENTE numeri, NIENTE elenchi puntati, NIENTE frase introduttiva, NIENTE citazioni [1]."

usage() {
  echo "Usage: scaletta.sh [<notebook id|title>] [--long|--short] [--script-only|--images-only] [--out <dir>]" >&2
  echo "  --long|--short        limit the scaletta to one length (default: both)" >&2
  echo "  --script-only         only the scaletta(s), no infographics" >&2
  echo "  --images-only         only the 4 infographics, no scaletta" >&2
  echo "  --out <dir>           base output folder (default: $OUT_BASE)" >&2
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
        [ "$MODE" = "short" ] && fail "social-notebooklm-artifacts: choose only one of --long or --short."
        MODE="long"
        ;;
      --short)
        [ "$MODE" = "long" ] && fail "social-notebooklm-artifacts: choose only one of --long or --short."
        MODE="short"
        ;;
      --script-only)
        [ "$KIND" = "images" ] && fail "social-notebooklm-artifacts: choose only one of --script-only or --images-only."
        KIND="scripts"
        ;;
      --images-only)
        [ "$KIND" = "scripts" ] && fail "social-notebooklm-artifacts: choose only one of --script-only or --images-only."
        KIND="images"
        ;;
      --out)
        [ "$#" -ge 2 ] || { usage; fail "social-notebooklm-artifacts: --out requires a directory."; }
        OUT_BASE="$2"
        shift
        ;;
      --out=*)
        OUT_BASE="${1#--out=}"
        [ -n "$OUT_BASE" ] || { usage; fail "social-notebooklm-artifacts: --out requires a directory."; }
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        usage
        fail "social-notebooklm-artifacts: unknown flag: $1"
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
  command -v notebooklm >/dev/null 2>&1 \
    || fail "notebooklm CLI not found. Install: https://github.com/teng-lin/notebooklm-py"
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 not found."

  notebooklm doctor 2>&1 | python3 -c '
import re, sys
text = sys.stdin.read()
for line in text.splitlines():
    if re.search(r"\bAuth\b", line, re.I):
        sys.exit(0 if re.search(r"\bpass\b", line, re.I) else 1)
sys.exit(1)
' || fail "NotebookLM not authenticated. Run: notebooklm login"

  local tmp_root
  tmp_root=$(python3 -c 'import tempfile,os;print(os.path.realpath(tempfile.gettempdir()))') \
    || fail "social-notebooklm-artifacts: unable to resolve temp directory."
  TMP_DIR=$(mktemp -d "$tmp_root/scaletta.XXXXXX") \
    || fail "social-notebooklm-artifacts: unable to create temp directory."
}

resolve_notebook() {
  local status_file parsed

  if [ -n "$NOTEBOOK_ARG" ]; then
    notebooklm use "$NOTEBOOK_ARG" >/dev/null \
      || fail "social-notebooklm-artifacts: no notebook — pass an id/title or run 'notebooklm use <id>' first."
  fi

  status_file="$TMP_DIR/status.json"
  notebooklm status --json > "$status_file" 2>/dev/null \
    || fail "social-notebooklm-artifacts: no notebook — pass an id/title or run 'notebooklm use <id>' first."

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
    3) fail "social-notebooklm-artifacts: notebook empty or not found — nothing to script." ;;
    *) fail "social-notebooklm-artifacts: no notebook — pass an id/title or run 'notebooklm use <id>' first." ;;
  esac

  NOTEBOOK_ID=$(printf "%s\n" "$parsed" | python3 -c 'import sys; print(sys.stdin.readline().rstrip("\n"))')
  NOTEBOOK_TITLE=$(printf "%s\n" "$parsed" | python3 -c 'import sys; sys.stdin.readline(); print(sys.stdin.read().rstrip("\n"))')

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
        [ -d "$vol" ] || fail "social-notebooklm-artifacts: $vol not mounted."
        ;;
    esac
    fail "social-notebooklm-artifacts: unable to create output directory: $OUT_DIR"
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
lines = t.splitlines()
if lines and re.match(r'^\s*(Ecco|Certo|Perfetto|Naturalmente)\b.*:\s*$', lines[0]):
    lines = lines[1:]
body = "\n".join(lines).strip() + "\n"
hdr = f"# {title} — scaletta {kind}\n<!-- focal points + contesto · NotebookLM (solo fonti) · {date} -->\n\n"
pathlib.Path(out).write_text(hdr + body, encoding="utf-8")
PY
}

gen_long() {
  local ans_file out_file
  ans_file="$TMP_DIR/answer-long.md"
  out_file="$OUT_DIR/script-long.md"

  if ask_to "$LONG_PROMPT" "$ans_file"; then
    strip_and_write "$ans_file" "$out_file" "long"
    WRITTEN_FILES=$(append_line "$WRITTEN_FILES" "$out_file")
  else
    FAILED_LENGTHS=$(append_line "$FAILED_LENGTHS" "long")
  fi
}

gen_short() {
  local ans_file out_file
  ans_file="$TMP_DIR/answer-short.md"
  out_file="$OUT_DIR/script-short.md"

  if ask_to "$SHORT_PROMPT" "$ans_file"; then
    strip_and_write "$ans_file" "$out_file" "short"
    WRITTEN_FILES=$(append_line "$WRITTEN_FILES" "$out_file")
  else
    FAILED_LENGTHS=$(append_line "$FAILED_LENGTHS" "short")
  fi
}

images_preflight() {
  [ -x "$NBLM_PYTHON" ] \
    || fail "social-notebooklm-artifacts: venv python not found at '$NBLM_PYTHON'. Create it (uv venv --python 3.13 ~/.venvs/nblm && uv pip install --python ~/.venvs/nblm \"notebooklm-py[browser]\") or set NBLM_PYTHON."
  "$NBLM_PYTHON" -c 'import notebooklm' 2>/dev/null \
    || fail "social-notebooklm-artifacts: notebooklm library not importable by '$NBLM_PYTHON'. Run: uv pip install --python \"\$(dirname \$(dirname $NBLM_PYTHON))\" \"notebooklm-py[browser]\"."
}

derive_concepts() {
  # Ask the notebook for 4 "TITOLO :: dettaglio" concept lines; write to file.
  local ans_file="$1"
  local concepts_file="$2"

  if ! ask_to "$CONCEPTS_PROMPT" "$ans_file"; then
    return 1
  fi
  # Keep only well-formed concept lines (must contain '::'); strip stray citations.
  python3 - "$ans_file" "$concepts_file" <<'PY'
import pathlib, re, sys
src, dst = sys.argv[1], sys.argv[2]
out = []
for line in pathlib.Path(src).read_text(encoding="utf-8").splitlines():
    line = re.sub(r' ?\[[0-9]+(\s*[,–-]\s*[0-9]+)*\]', '', line).strip()
    line = re.sub(r'^[\-\*\d\.\)\s]+', '', line)  # drop bullet/number prefixes
    if '::' in line:
        out.append(line)
if not out:
    sys.exit(1)
pathlib.Path(dst).write_text("\n".join(out[:4]) + "\n", encoding="utf-8")
PY
}

gen_images() {
  local ans_file concepts_file img_log
  ans_file="$TMP_DIR/answer-concepts.txt"
  concepts_file="$TMP_DIR/concepts.txt"
  img_log="$TMP_DIR/images.log"

  if ! derive_concepts "$ans_file" "$concepts_file"; then
    IMAGES_FAILED="concept-derivation-failed"
    return 1
  fi

  # images.py emits IMAGES_DONE=... / IMAGES_FAILED=... on its final two lines.
  NBLM_NOTEBOOK="$NOTEBOOK_ID" "$NBLM_PYTHON" "$SCRIPT_DIR/images.py" "$OUT_DIR" "$concepts_file" 2>&1 | tee "$img_log"
  IMAGES_DONE=$(grep '^IMAGES_DONE=' "$img_log" | tail -1 | sed 's/^IMAGES_DONE=//')
  IMAGES_FAILED=$(grep '^IMAGES_FAILED=' "$img_log" | tail -1 | sed 's/^IMAGES_FAILED=//')
}

summary() {
  if [ -n "$WRITTEN_FILES" ]; then
    echo "✓ Scaletta pronta (solo contenuto del notebook, punti chiave senza citazioni)."
    echo "  Notebook:  $NOTEBOOK_TITLE ($NOTEBOOK_ID)"
    echo "  File:"
    printf "%s\n" "$WRITTEN_FILES" | while IFS= read -r file; do
      case "$file" in
        *script-long.md) echo "    - $file   (sezioni + bullet)" ;;
        *script-short.md) echo "    - $file  (Reel/Short)" ;;
        *) echo "    - $file" ;;
      esac
    done
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

  if [ -n "$IMAGES_DONE" ]; then
    echo
    echo "✓ Infografiche generate (matrice 2x2, solo contenuto del notebook):"
    printf "%s" "$IMAGES_DONE" | tr ',' '\n' | while IFS= read -r name; do
      [ -n "$name" ] && echo "    - $OUT_DIR/$name.png"
    done
  fi
  if [ -n "$IMAGES_FAILED" ]; then
    echo
    echo "Infografiche non generate (quota giornaliera / rifiuto — riprova domani):"
    printf "%s" "$IMAGES_FAILED" | tr ',' '\n' | while IFS= read -r name; do
      [ -n "$name" ] && echo "    - $name"
    done
  fi
}

main() {
  trap '[ -n "${TMP_DIR:-}" ] && rm -rf "$TMP_DIR"' EXIT
  parse_args "$@"
  preflight
  [ "$KIND" != "scripts" ] && images_preflight
  resolve_notebook
  probe

  if [ "$KIND" != "images" ]; then
    case "$MODE" in
      long)  gen_long ;;
      short) gen_short ;;
      both)  gen_long; gen_short ;;
    esac
  fi

  if [ "$KIND" != "scripts" ]; then
    gen_images
  fi

  summary

  # Success = every requested artifact class produced at least its core output.
  local scripts_ok=1 images_ok=1
  if [ "$KIND" != "images" ]; then
    { [ -z "$FAILED_LENGTHS" ] && [ -n "$WRITTEN_FILES" ]; } || scripts_ok=0
  fi
  if [ "$KIND" != "scripts" ]; then
    [ -n "$IMAGES_DONE" ] || images_ok=0
  fi
  [ "$scripts_ok" -eq 1 ] && [ "$images_ok" -eq 1 ]
}

main "$@"

---
name: social-notebooklm-artifacts
description: Turn an existing NotebookLM notebook into video assets — a bulleted SCALETTA (focal-point talking points, NOT a verbatim script) AND a 2×2 matrix of 4 Italian infographics (simple+detailed × landscape+portrait). Content comes ENTIRELY from the notebook's sources (scaletta via notebooklm ask; image concepts derived from the notebook too) — you pass nothing, no persona. No citation numbers. By default produces long+short scaletta AND 4 PNGs, in Italian, under a chronological folder <YYYY-MM-DD> - <notebook-title>/ inside a base dir (default /Volumes/Crucial-4T/social, override with --out). Use when invoked as /social-notebooklm-artifacts [<notebook>] [--long | --short] [--script-only | --images-only] [--out <dir>], or asked to turn a NotebookLM project into a video script/scaletta and/or infographics. Agent-independent (Claude Code or Codex). Pairs with social-new-notebooklm-project (which builds the notebook).
---

# social-notebooklm-artifacts

Turn an existing NotebookLM notebook into **video assets**:

1. A **scaletta** — a bulleted list of focal points / talking points to glance at while filming and expand in your own words (**not** a verbatim teleprompter script).
2. A **2×2 infographic matrix** — exactly 4 Italian PNGs: `simple_landscape`, `detailed_landscape`, `simple_portrait`, `detailed_portrait`. Simple = one concept, huge text, mobile-readable B-roll; detailed = richer/accurate, reusable as overlays/reference. Landscape for normal videos, portrait for Shorts/Reels.

Both are grounded **entirely in the notebook's own sources** — the scaletta via `notebooklm ask`, the 4 image concepts derived from the notebook the same way. Do not supply a topic, persona, or voice file.

Companion to **`social-new-notebooklm-project`** (which researches a topic and builds the notebook). This skill is the next step: notebook → assets.

## Input

Invoked as `/social-notebooklm-artifacts [<notebook>] [--long | --short] [--script-only | --images-only] [--out <dir>]`.

- `<notebook>` — **optional**. Notebook **id or title** (partial match works). If omitted, use the **active** notebook (`notebooklm status`). If neither resolves, halt: `social-notebooklm-artifacts: no notebook — pass an id/title or run 'notebooklm use <id>' first.`
- `--long` / `--short` — **optional**. Limit the **scaletta** to one length. **Default: both.** (Ignored under `--images-only`.)
- `--script-only` / `--images-only` — **optional**, mutually exclusive. Restrict to one artifact class. **Default (neither): generate scaletta(s) AND the 4 infographics.**
- `--out <dir>` — **optional**. Base output folder. **Default `/Volumes/Crucial-4T/social`.** `~` is expanded. Also accepts `--out=<dir>`.

The per-run folder is named **`<YYYY-MM-DD> - <notebook title>`** (today's date first) under the base, so folders sort chronologically.

## Run

Run the bundled script from this skill directory:

```bash
cd skills/social-notebooklm-artifacts
scripts/scaletta.sh [<notebook id|title>] [--long|--short] [--script-only|--images-only] [--out <dir>]
```

The script implements the full stable flow: preflight, notebook resolution, availability probe, scaletta `ask` generation (`--quiet`, `--timeout 180`, retry/backoff, Python citation stripping), then image generation (derive 4 concepts → `images.py`), Markdown/PNG writing, and summary. Output is written under `<out-base>/<YYYY-MM-DD> - <notebook-title>/`:

- `script-long.md` and/or `script-short.md` (scaletta)
- `simple_landscape.png`, `detailed_landscape.png`, `simple_portrait.png`, `detailed_portrait.png` (infographics)

(default `<out-base>` = `/Volumes/Crucial-4T/social`; override with `--out`).

## Infographics (the 4-image 2×2 matrix)

The `notebooklm` CLI exposes **no** infographic generation (only artifact *management*), so image generation runs the **notebooklm-py library** under a dedicated venv. The script invokes `images.py` with `$NBLM_PYTHON` (default `~/.venvs/nblm/bin/python`; override via the `NBLM_PYTHON` env var). If that interpreter is missing or can't `import notebooklm`, the script halts with the install command — so a missing venv fails fast before any generation.

Flow:
1. **Derive concepts** — one `notebooklm ask` pulls the 4 most important visual concepts from the notebook's sources, as `TITOLO :: dettaglio` lines (Italian, no numbering/citations). Concepts are **never hardcoded** — they fit whatever the notebook is about.
2. **Generate paced** — `images.py` produces the 2×2 matrix: same `PROFESSIONAL` style across all 4 for a consistent channel look; the only knobs separating quadrants are orientation (landscape/portrait) and `detail_level` (simple=`CONCISE` + one-concept hard instructions; detailed=`DETAILED` + "completa e accurata"). All instructions are Italian.
3. **Quota-safe** — free tier is ~8 generations / rolling-24h. Budget-capped at 4/run (`NBLM_BUDGET`), spaced (`NBLM_SPACING`, default 60s), exponential backoff on rate-limit refusals (`NBLM_BACKOFF_START`→`NBLM_BACKOFF_MAX`, `NBLM_MAX_RETRIES`). A refused/quota-exhausted run stops cleanly and lists what didn't generate so you retry tomorrow — it never blind-retries past the cap.

Watermark "Made with NotebookLM" is burned in server-side; crop/cover it in your editor.

## Format Rules

- Italian, first person framing, bullet list of focal points. Each top bullet is one short concept, speakable from memory.
- Each focal point is **developed over multiple sub-bullets** so there's enough material to speak from without inventing — not a bare headline. Sub-bullets stay short, speakable phrases (not paragraphs): rich but lean, no walls of text.
- A **real example is never bare**: say what it is, the number/source if any, and why it proves the point.
- **Every technical term, acronym, law, theory, proper noun, or specialist concept is glossed in plain Italian the first time it appears**, as a short aside ("X, cioè …") — assume the viewer knows nothing about the topic, so the speaker can explain it from scratch. Never drop a bare name, acronym, or term. (Domain-agnostic: the glossed terms come from whatever the notebook is about.)
- Long: bold section titles, 3–4 focal points per section, each with 2–3 sub-bullets — (a) the mechanism/definition, (b) a contextualized example or data point, (c) optional: why it matters / the consequence. HOOK section, final CTA.
- Short: 1 HOOK bullet, 3–4 substance bullets, 1 CTA bullet; each substance bullet gets 2 sub-bullets — one explaining the concept, one with a contextualized example/data point.
- No citation numbers (`[1]`, `[1-3]`, etc.), no chatty preamble, no b-roll or production jargon.

Each file header is:

```markdown
# <title> — scaletta <long|short>
<!-- focal points + contesto · NotebookLM (solo fonti) · <iso-date> -->
```

## Prompts

Long:

> Scrivi una SCALETTA per un video YouTube in italiano come ELENCO PUNTATO di punti da dire a braccio con parole mie (NON un testo da leggere parola per parola). Usa solo le informazioni nelle fonti di questo notebook; non inventare nulla. Organizza in sezioni: ogni sezione un titolo breve in grassetto; sotto, 3-4 PUNTI CHIAVE come bullet (max ~12 parole, il concetto). SOTTO OGNI punto chiave aggiungi 2-3 SOTTO-BULLET indentati che SVILUPPANO il concetto su piu righe, così da avere abbastanza materiale davanti agli occhi per parlarne senza inventare: (a) un sotto-bullet che SPIEGA il meccanismo o la definizione (come/perché funziona), (b) un sotto-bullet con un ESEMPIO o un DATO CONCRETO ben contestualizzato — non l'esempio nudo: di' cos'è, il numero/la fonte se c'è, e perché dimostra il punto, (c) facoltativo: perché conta o quale conseguenza ha. REGOLA FONDAMENTALE: ogni termine tecnico, sigla, legge, teoria, nome proprio o concetto specialistico va SPIEGATO in parole semplici la prima volta che compare, con un breve inciso ('X, cioè ...' / 'X, ovvero ...'), come se chi guarda non sapesse nulla dell'argomento. Non lasciare mai un nome, una sigla o un termine nudi: io devo poterli spiegare a voce partendo da zero. Ogni sotto-bullet è una frase breve e parlabile (max ~22 parole), non un paragrafo: spunti ricchi ma asciutti, niente muri di testo. Il bullet principale è il concetto; i sotto-bullet sono il contesto su cui mi appoggio mentre parlo. Includi una sezione HOOK iniziale e una CTA finale. NIENTE numeri di citazione [1]/[1-3]. Niente frase introduttiva, niente regia.

Short:

> Scrivi una SCALETTA per un Reel/Short verticale in italiano come ELENCO PUNTATO da dire a braccio con parole mie (non un testo da leggere). Solo dalle fonti del notebook, niente invenzioni. Formato: 1 bullet HOOK, 3-4 bullet di sostanza, 1 bullet CTA; per ogni bullet di sostanza aggiungi 2 SOTTO-BULLET indentati brevi: uno che SPIEGA il concetto in una frase, uno con un ESEMPIO o DATO contestualizzato (cos'è + il numero/perché conta, non l'esempio nudo). REGOLA FONDAMENTALE: ogni termine tecnico, sigla, legge, teoria, nome proprio o concetto specialistico va SPIEGATO in parole semplici con un breve inciso ('X, cioè ...'), come se chi guarda non sapesse nulla dell'argomento. Mai un nome, una sigla o un termine nudi: io devo poterli spiegare a voce da zero. Sotto-bullet parlabili (max ~20 parole), un concetto per bullet. NIENTE numeri di citazione [1]/[1-3]. Niente frase introduttiva, niente regia.

## Known failure modes

| Symptom | Cause | Handling |
|---|---|---|
| report text won't save locally | `generate report` body not exposed by CLI; `artifact export` is Docs/Sheets-only | use `notebooklm ask` and capture the `answer` field (Step 2) |
| `Unknown language code: Italian` | language wants a code | use `it` (`notebooklm language list`); the `ask` prompt itself also requests Italian |
| long script cut off | chat answer length cap | stage it: outline → one ask per beat → concatenate (Step 3) |
| `NETWORK_ERROR: chat.ask timed out after retries` | flaky/soft-rate-limited NotebookLM backend (NOT a fixable timeout) | `--timeout 180` + `ask_to` retry/backoff; availability probe first; halt cleanly if the backend is down |
| empty/`KeyError: answer` when parsing | status line on stdout, or an error JSON | always `--quiet`; parse with `.get('answer')` and treat missing as failure (retry) |
| want to know "API calls left" | notebooklm-py exposes no quota/usage endpoint | not possible to query; the cheap `ask "ok"` probe is the only availability signal |
| `._script-*.md` files appear | macOS AppleDouble metadata on external/exFAT volumes | harmless; ignore (or `dot_clean` the folder) |
| `[1]`/`[1-3]` numbers or "Ecco… :" preamble in output | NotebookLM adds citations + a lead-in even when told not to | `strip_cites` post-process removes both before writing (Step 3) — never ship raw `ask` text |
| user reads verbatim, loses his place | prose paragraphs are unspeakable | output is a **bulleted scaletta** of short focal points, not a verbatim script (the whole point) |
| bare headlines, nothing to say | focal points with no supporting detail | each top bullet gets **1–2 context sub-bullets** (data/example/term) to speak from |
| `sed: extra characters at the end of d command` | BSD/macOS sed can't do `1{/…/d}` | do citation+preamble strip in **Python**, not sed (Step 3 writer) |
| wrong notebook scripted | ambiguous/unset active notebook | Step 1 resolves + confirms via `notebooklm status` before generating |
| output base on an unmounted `/Volumes/*` | external volume not mounted | `mkdir -p` fails → script detects the missing volume root and halts "`<vol> not mounted`" |
| want folders sorted by date | flat title-only folders | folder name is `<YYYY-MM-DD> - <title>`; base dir overridable via `--out` |
| `notebooklm: No such command 'infographic'` | CLI exposes artifact *management* only, not generation | image step uses the notebooklm-py **library** via `$NBLM_PYTHON`, not the CLI |
| `notebooklm library not importable` | venv missing / lib not installed | `uv venv --python 3.13 ~/.venvs/nblm && uv pip install --python ~/.venvs/nblm "notebooklm-py[browser]"`, or set `NBLM_PYTHON` |
| infographic text too small / too busy | NotebookLM auto-fits the whole topic into one poster | scope is the dial: simple quadrants use one concept + `CONCISE` + hard Italian "testo ENORME, max 3 elementi" instructions |
| `RateLimitError` / "Resource exhausted" mid-batch | ~8 gen / rolling-24h free-tier quota | budget-capped at 4/run + spacing + backoff; stops cleanly, lists ungenerated quadrants, retry tomorrow — never blind-retries |
| only some of the 4 PNGs appear | quota hit partway, or a quadrant refused | summary lists `IMAGES_DONE` vs failed; rerun `--images-only` next day for the rest |
| empty `task_id` then a bogus duplicate PNG | a refused generate returns empty id; download-latest then grabs a stale artifact | `is_refusal()` guard in `images.py` treats empty `task_id` as a failure, never downloads |

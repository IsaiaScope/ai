---
name: social-new-notebooklm-project
description: Research-first prep for your next YouTube video. Accepts EITHER a text topic OR one-or-more seed YouTube URLs (topics auto-derived and clustered from the videos — same topic → one research, different topics → one research per cluster, all in one notebook). Runs TOKEN-BOUNDED deep research, picks an Italian title from 6 research-grounded options, then creates a NotebookLM notebook (titled with your pick) and loads it with the research report(s), cited sources, the seed videos, and any extra video/PDF/doc sources you supply. Use when invoked as /social-new-notebooklm-project <topic | youtube-url...> [--deep] [extra-source ...], or asked to spin up a NotebookLM research notebook for a new video. Agent-independent (Claude Code or Codex). Title and generated content are Italian; sources may be Italian or English. Does not generate NotebookLM artifacts.
---

# social-new-notebooklm-project

Prepare the research backing for your next YouTube video. The skill researches a topic, lets **you** pick the video title (Italian) from research-grounded options, creates a NotebookLM notebook named with that title, and fills it with sources. It does **not** create the video and does **not** generate NotebookLM artifacts (audio/video/report) — that is a separate skill.

**Language rules (hard):**
- The 6 title options and any **generated/synthesized** content (research report framing, summaries) → **Italian**.
- Ingested **sources** (the cited URLs, your PDFs/videos/docs) → **Italian or English, as-is**. Never translate sources.

## Input

Invoked as `/social-new-notebooklm-project <topic-or-youtube-url> [--deep] [extra-source ...]`.

- `<topic-or-youtube-url>` — **required**. EITHER:
  - a **text topic** (any language) → *topic mode*; or
  - a **YouTube URL** (`youtube.com/watch`, `youtu.be/`, `youtube.com/shorts/`) → *video-seed mode*: the research topic is **auto-derived from the video** (Step 0), and the video itself becomes a starter source in the notebook.
- `--deep` — **optional flag**. Escalate Step 1 to the expensive multi-agent harness (see Step 1). **Off by default** — the default is a token-bounded research that does NOT spawn a workflow.
- `[extra-source ...]` — **optional**, zero or more. Each is a file path, web URL, or YouTube URL to add to the notebook. Added immediately after the notebook exists; the Step 6 prompt catches any you didn't pass here.

If the first argument is missing, halt: `social-new-notebooklm-project: topic or YouTube URL required. Usage: /social-new-notebooklm-project <topic-or-youtube-url> [--deep] [extra-source ...]`.

## Pre-flight

The only hard dependency is the `notebooklm` CLI, authenticated.

```bash
command -v notebooklm &>/dev/null || { echo "✗ notebooklm CLI not found. Install: https://github.com/teng-lin/notebooklm-py"; exit 1; }
notebooklm doctor 2>&1 | grep -q "Auth" && notebooklm doctor 2>&1 | grep -A0 "Auth" | grep -q "pass" \
  || { echo "✗ NotebookLM not authenticated. Run: notebooklm login"; exit 1; }
```

If `notebooklm doctor` shows Auth not passing, halt with the login instruction above. Do **not** proceed to research — a failed auth means no notebook can be created, so fail fast before spending research time.

## Step 0: Resolve input → research topic(s)

Parse the arguments into three buckets: a **text topic** (the non-flag, non-URL tokens joined), **YouTube URLs** (one or more), and **other sources** (file paths / non-YouTube URLs).

**Topic mode** — a text topic is present: the research topic **is** that text (one research). Any YouTube URLs and other sources are just sources (Step 6), not topic drivers. Skip to Step 1.

**Video-seed mode** — no text topic, but ≥1 YouTube URL: derive the research topic(s) from the videos. **All** these URLs are seed videos (drivers *and* sources).

1. For **each** seed URL: normalize `youtube.com/shorts/<id>` → `https://www.youtube.com/watch?v=<id>`, then pull metadata + transcript (cheap, no Whisper):
   ```bash
   yt-dlp --skip-download --print "%(title)s\n%(uploader)s\n%(description)s" "<url>"
   yt-dlp --skip-download --write-auto-subs --write-subs --sub-lang "en.*,it.*" \
          --sub-format vtt -o "$tmpdir/seed-<i>.%(ext)s" "<url>" 2>/dev/null || true
   ```
   (`$tmpdir` = realpath temp dir, see Step 5a.) A single unavailable video (private/deleted) is skipped with a warning; if **every** seed fails, halt: `social-new-notebooklm-project: no readable seed video — pass a text topic instead.` If `yt-dlp` is missing, halt likewise.
2. **Derive a one-sentence topic per video** from title + description (+ captions if present). No audio transcription here.
3. **Auto-cluster the per-video topics** by semantic similarity — **no confirmation, proceed straight to research**:
   - All videos share one main topic → **one cluster** → one research, one report.
   - Videos split into distinct topics → **K clusters** → K researches, K reports — but **one notebook** (this is prep for a single video project). Print the detected grouping (transparency, non-blocking).
   - Keep K sane: if you detect more than ~4 clusters, **merge the smallest into the nearest** and note it — too many parallel researches thin the budget (Step 1).

The output of Step 0 is a list of **1..K research topics** plus the list of seed videos.

## Step 1: Deep research — TOKEN-BOUNDED by default

Run **one research per topic** from Step 0 (1 in topic mode / single-cluster; K when videos clustered into K topics). Each produces **one cited markdown report, written in Italian** (prose, headings, executive summary, conclusions in Italian; quoted source material stays in its original language). Keep per report: (a) the full Italian text, (b) its list of **cited source URLs**.

> **COST RULE (do not skip).** "Deep research" here means *thorough but bounded*, NOT *maximum-depth multi-agent*. **Do NOT launch the `deep-research` Workflow harness unless the user passed `--deep`.** The harness fans out dozens of subagents and can burn hundreds of thousands of tokens — that is the failure this skill exists to avoid.

**Default mode (no `--deep`) — bounded inline fan-out.** Per topic, same on Claude Code and Codex:

1. Decompose the topic into **6–8 search angles** (definitions, key entities/products, evidence/benchmarks, risks, future/adoption — adapt to topic).
2. Run those as **parallel web searches in a single batch** (Claude Code: parallel `WebSearch` calls; Codex: built-in `web_search`, `web_search="live"` for fresh results). One pass — do not re-run angles that already returned enough.
3. **Fetch full text only for the 3–6 highest-value sources** (primary docs, papers, vendor docs, independent evaluations) where the snippet is not enough — `WebFetch` (Claude) / fetch (Codex). Skip pages whose snippet already gives the claim.
4. Synthesize the Italian report from snippets + the few fetched pages. Cite every major claim.

Soft budget target: **~500k output tokens TOTAL across all researches** (the bounded-mode ceiling), **divided across the K topics** — not 500k each. More clusters → each research is shallower; that is why Step 0 caps K at ~4. Once findings are solid or the total budget is approached, stop and proceed — do not loop past ~500k.

**`--deep` mode — explicit opt-in only.** The user accepted the cost. Invoke the built-in **`/deep-research`** skill (Claude Code) / the installed `Deep-Research-skills` (Codex, if present) **once per topic**, instructing an Italian synthesis. Use this only when `--deep` is present.

**Hard stop on research failure.** If **all** researches fail or come back too thin to ground a video (no usable findings, no citable sources), halt: `social-new-notebooklm-project: research failed or too thin — no notebook created.` Create nothing. (If only *some* clusters fail, keep the ones that succeeded and note the rest.) This is the only point where the whole run aborts.

## Step 2: Generate 6 Italian title options (research-grounded)

From the **actual findings across all reports** (surprising stats, tensions, angles the research surfaced — when there are K reports, draw on the union, leaning on the dominant cluster), generate **6 video title options in Italian**, **YouTube-biased** but spanning distinct angles — one per angle, not synonyms:

1. **Curiosity-gap** — opens a loop the viewer needs closed.
2. **Myth-bust / contrarian** — challenges a common belief.
3. **Number / listicle** — "N modi…", "I 5…".
4. **How-to / payoff** — promises a concrete result.
5. **Bold claim** — a strong, defensible assertion from the findings.
6. **Plain-descriptive** — clear, SEO-friendly, no gimmick.

Each option must be grounded in something the research actually found (no generic filler). Pair each with a one-line *why this hooks* (also Italian).

## Step 3: Let the user pick the title

Present the **6 options as a numbered Markdown list** (each: bold title + one-line *why* in Italian), then ask the user to reply with a number `1–6` or paste a custom title.

> **Do NOT use `AskUserQuestion` for this** — that tool caps at **4 options**, so 6 titles will not fit. A numbered text list is the portable path and works identically on Claude Code and Codex.

The result is the **chosen title string** — this becomes both the video title and the notebook name. Do not proceed until the user has picked.

## Step 4: Create the notebook

```bash
notebooklm create "<chosen title>" --use --json
```

Parse the JSON to capture the notebook **id** (and URL if present). `--use` makes it the active context so later `source add` calls target it without `-n`. If create fails, halt: `social-new-notebooklm-project: notebook create failed — <stderr>.` (Research already succeeded; surface the error so the user can retry create without re-researching.)

## Step 5: Add the research report(s) + cited sources

### 5a. Write each report to a NON-symlink path

macOS `/tmp` is a symlink to `/private/tmp`, and the CLI **refuses symlinked paths** (anti-exfiltration guard). Write to the resolved real temp dir, not `/tmp`. Write **one file per research report** (1 in topic mode; K when clustered) and add each as its own source, titled with that report's topic:

```bash
tmpdir="$(python3 -c 'import tempfile,os;print(os.path.realpath(tempfile.gettempdir()))')"   # -> /private/tmp on macOS
# for each report i (slugged topic):
report_file="$tmpdir/social-new-notebooklm-project-report-<i>.md"
# write the Italian report markdown into "$report_file"
notebooklm source add "$report_file" --type file --title "<topic-i> — ricerca (it)" --json
```

(If a path is genuinely a symlink you intend to follow, `--follow-symlinks` exists — but never use it to dodge this; just write to a real path.)

### 5b. Add cited URLs — dedupe, add ONCE, never blind-retry

Pool the cited URLs **across all reports** before adding (so the cap and dedup are global, not per-report).

```bash
notebooklm source add "<url>" --json   # one call per UNIQUE cited URL; collect failures, do NOT retry
```

- **Dedupe the URL list first.** Adding the same URL twice creates duplicate source rows.
- **Cap at 15** cited URLs. If the report cites more, add the 15 most-cited/most-relevant and **log every dropped URL** in the final summary (no silent truncation).
- **Do NOT retry a failed add.** A failed add (Cloudflare wall, paywall, caption-less video) often *still creates an empty stub source row*; retrying just spawns duplicates. Record the failure and move on.
- Per-URL failure is **tolerated** — skip, record, keep going.

### 5c. YouTube specifics

- Normalize `https://www.youtube.com/shorts/<id>` → `https://www.youtube.com/watch?v=<id>` before adding, and pass `--type youtube`.
- **NotebookLM rejects caption-less videos and most Shorts** (`RPCError rpc_code=9`). Regular `watch?v=` videos with captions ingest fine. If it fails, do **not** retry; record it. (Optional, only if the user opts in: pull captions via `yt-dlp --write-auto-subs` and add the transcript as a `--type text` source. Do not auto-transcribe audio — that is scope creep.)

## Step 6: Add the seed video + extra sources (args + interactive)

1. **Seed videos (video-seed mode only):** add **every** seed YouTube URL as a source — the videos that started this notebook. For each: watch-normalized URL + `--type youtube` (5c). If NotebookLM rejects one (caption-less/Shorts, `rpc_code=9`), fall back to adding **that video's captions** pulled in Step 0 as a `--type text` source titled `<title> — trascrizione`; if it had no captions either, record it as a failed source in the summary (do not auto-transcribe audio). No seed video is ever silently dropped.
2. **From args:** add every `[extra-source ...]` passed at invocation now, each via `notebooklm source add "<arg>" --json` (type auto-detected). A missing/unreadable **file** is tolerated but **warned loudly** in the summary — it's the user's own file. Apply the 5c YouTube normalization to video URLs.
3. **Interactive catch-all:** prompt the user to paste more sources, one per line (file path / URL / YouTube), or `skip` to finish. Add each as above.

Symlinked files are rejected by default (safety). Only pass `--follow-symlinks` if the user explicitly opts in for a given file.

Failure policy across all source adds: **soft** — collect failures, never abort the run for an individual source, never blind-retry.

## Step 6.5: Cleanup pass — prune dead stub sources

Failed/blocked adds leave **empty stub rows** that pollute the notebook. After all adds, list sources and delete the dead ones. `source delete` **requires `-y`** in non-interactive use.

```bash
notebooklm source list --json   # inspect id + title + type
```

Delete a source whose title/content indicates a dead fetch (note the `--json` `id`):

```bash
notebooklm source delete "<source-id>" -y --json
```

Dead-stub signals to prune:
- Title is a **Cloudflare interstitial**: `Just a moment...` (and similar challenge pages).
- A **paywalled / anti-bot** page that returned no real content (e.g. some `medium.com` posts).
- A **caption-less YouTube** row that registered but has no transcript.
- **Exact-duplicate** rows for the same URL/title (keep one).

Track the source ids you add (from each `--json` result) so the cleanup is precise rather than guesswork. Re-list afterward to confirm the final count.

## Step 7: Print summary and stop

```
✓ NotebookLM pronto — nessun artifact generato.
  Input:           <topic mode | video-seed: N video → K topic>
  Topic ricercati: <topic 1; topic 2; …>   (K researches)
  Modalità ricerca: <bounded | --deep>
  Titolo video:  <chosen title>
  Notebook:      <id / URL>
  Fonti aggiunte (<N>):
    - <K> report ricerca (it)
    - <V> video seed          (solo video-seed mode)
    - <n> URL citati
    - <m> fonti extra
  Fonti fallite:   <list with reason, or "nessuna">
  Stub rimossi:    <count>
  URL citati scartati (oltre il cap 15): <list, or "nessuno">

Apri il notebook su https://notebooklm.google.com per lavorare allo script del video.
```

Then halt. The skill's contract ends at a populated notebook. **Do not** generate audio/video/report/mind-map artifacts — that is a separate skill. **Do not** create the video.

## Known failure modes (learned)

| Symptom | Cause | Handling |
|---|---|---|
| Step 1 burns huge token counts | launched the multi-agent `deep-research` Workflow | default to bounded inline fan-out; gate the harness behind `--deep` |
| `Path is a symlink … Refusing to upload` | `/tmp` → `/private/tmp` symlink + CLI guard | write report to the realpath temp dir (5a) |
| `RPCError rpc_code=9` on a YouTube add | Shorts / caption-less video | normalize shorts→watch; if still failing, record, optional captions-as-text |
| Notebook fills with `Just a moment...` rows | Cloudflare-walled URL still created a stub | cleanup pass (6.5) deletes dead stubs |
| Duplicate source rows | blind-retrying a "failed" add that actually registered | add once, never blind-retry; dedupe URL list |
| `source delete` does nothing | missing confirmation | pass `-y` |
| seed video can't be ingested | caption-less / Shorts | add Step 0 captions as `--type text`; else record as failed (never silently drop) |
| too many parallel researches drain budget | seed videos clustered into many topics | Step 0 caps K at ~4 (merge smallest); ~500k budget is shared across clusters, not per-cluster |
| one seed video is private/deleted | unavailable URL | skip it with a warning; halt only if *every* seed fails |

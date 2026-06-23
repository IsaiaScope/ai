---
name: social-new-notebooklm-project
description: Research-first prep for a new Italian YouTube video: derive topic(s), run Codex-agent deep research by default with source-credibility tiering and adversarial fact-verification (verified vs contested claims), offer 6 grounded Italian titles, create a NotebookLM notebook, and add reports plus only trustworthy (T1–T3) sources. Use when invoked as /social-new-notebooklm-project <topic | youtube-url...> [--bounded] [extra-source ...], or when asked to spin up a NotebookLM research notebook for a video. --bounded opts down to a smaller research pass. Does not generate NotebookLM artifacts.
---

# social-new-notebooklm-project

Prepare the research backing for your next YouTube video. The skill researches a topic, lets **you** pick the video title (Italian) from research-grounded options, creates a NotebookLM notebook named with that title, and fills it with sources. It does **not** create the video and does **not** generate NotebookLM artifacts (audio/video/report) — that is a separate skill.

**Language rules (hard):**
- The 6 title options and any **generated/synthesized** content (research report framing, summaries) → **Italian**.
- Ingested **sources** (the cited URLs, your PDFs/videos/docs) → **Italian or English, as-is**. Never translate sources.

## Input

Invoked as `/social-new-notebooklm-project <topic-or-youtube-url> [--bounded] [extra-source ...]`.

- `<topic-or-youtube-url>` — **required**. EITHER:
  - a **text topic** (any language) → *topic mode*; or
  - a **YouTube URL** (`youtube.com/watch`, `youtu.be/`, `youtube.com/shorts/`) → *video-seed mode*: the research topic is **auto-derived from the video** (Step 0), and the video itself becomes a starter source in the notebook.
- `--bounded` — **optional flag**. Opt down to a smaller research pass (see Step 1). **Off by default** — the default is Codex-agent deep research using Codex's own search/fetch tools, with no API key requirement.
- `[extra-source ...]` — **optional**, zero or more. Each is a file path, web URL, or YouTube URL to add to the notebook. Added immediately after the notebook exists; the Step 6 prompt catches any you didn't pass here.

If the first argument is missing, halt: `social-new-notebooklm-project: topic or YouTube URL required. Usage: /social-new-notebooklm-project <topic-or-youtube-url> [--bounded] [extra-source ...]`.

## Pre-flight

The only hard dependency is the `notebooklm` CLI, authenticated.

```bash
command -v notebooklm &>/dev/null || { echo "✗ notebooklm CLI not found. Install: https://github.com/teng-lin/notebooklm-py"; exit 1; }
notebooklm doctor 2>&1 | grep -q "Auth" && notebooklm doctor 2>&1 | grep -A0 "Auth" | grep -q "pass" \
  || { echo "✗ NotebookLM not authenticated. Run: notebooklm login"; exit 1; }
```

If `notebooklm doctor` shows Auth not passing, halt with the login instruction above. Do **not** proceed to research — a failed auth means no notebook can be created, so fail fast before spending research time.

No OpenAI API key is required by this skill. Research is performed by the current agent runtime using its available search, fetch, browsing, file-reading, and synthesis tools.

## Step 0: Resolve input → research topic(s)

Parse the arguments into three buckets: a **text topic** (the non-flag, non-URL tokens joined), **YouTube URLs** (one or more), and **other sources** (file paths / non-YouTube URLs). Treat `--bounded` as a flag, not topic text.

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

## Step 1: Research — Codex-agent deep research by default, smaller pass on `--bounded`

Run **one research per topic** from Step 0 (1 in topic mode / single-cluster; K when videos clustered into K topics). Each produces **one cited markdown report, written in Italian** (prose, headings, executive summary, conclusions in Italian; quoted source material stays in its original language). Keep per report: (a) the full Italian text, (b) its list of **cited source URLs**.

> **COST RULE (do not skip).** Default research is thorough Codex-agent research, not the OpenAI Deep Research API and not a maximum-depth multi-agent workflow harness. It spends agent time/tokens, not API-key billed Deep Research calls. Use the staged loop below and stop when the evidence is strong enough for a grounded NotebookLM source pack.

### Source credibility + verification (BOTH modes — do not skip)

The purpose of this research is to ground a public video, so every claim that reaches the report must be **traceable to a credible source and survive a refute attempt**. Apply the following to both default and `--bounded` research.

**Credibility tiers.** Tag every source you keep with a tier:

| Tier | What | Use |
|---|---|---|
| **T1 — primary/official** | official docs, product docs, specs, release notes, the entity's own data, peer-reviewed papers, primary datasets, court/government filings | preferred for any factual/technical claim |
| **T2 — independent expert** | reputable independent evaluations, benchmark labs, established engineering blogs, named domain experts, quality journalism with named authors + sourcing | required as the cross-check against T1 vendor claims |
| **T3 — secondary/aggregator** | summaries, encyclopedic entries, well-known news aggregators | context and leads only — **never the sole support** for a central claim |
| **T4 — reject** | SEO content farms, undated/anonymous listicles, AI-generated slop, marketing fluff with no data, forum/Reddit/social posts as fact, sites that just restate other pages | **do not use, do not cite, do not add to the notebook** |

**Reject T4 outright.** If a strong-looking claim only traces back to T4, treat it as **unverified** — do not state it as fact in the report.

**Adversarial verification of central claims.** A *central claim* is anything the video would assert as true (stats, capabilities, cause→effect, "X is better than Y", dates, prices). For each:
1. Require **≥2 independent sources** (different owners/orgs — a vendor and its own reseller are NOT independent), at least one **T1 or T2**.
2. Actively **try to refute it**: search for the opposite, for corrections/retractions, for "X debunked / wrong / outdated". A claim that survives a genuine refute attempt is **verified**; one that does not is **contested**.
3. **Recency gate:** for any time-sensitive claim (versions, prices, "newest", market share, who-leads), confirm the source is current and note the date. Stale source on a moving fact → **contested**.

**Single-source, T1-only-vendor, or refuted/contradicted claims are NOT promoted to fact** — they go in the contested bucket (below) so the user knows not to assert them on camera.

**Default mode — Codex-agent deep research.** Use this unless `--bounded` is present.

This is **not** the ChatGPT UI Deep research picker and not an OpenAI API call. It is a disciplined agent research workflow that Codex can run directly:

1. Write a compact research plan for each topic: 8-12 angles covering definitions, primary entities/products, official docs, technical architecture, independent evaluations, risks, adoption, and future outlook. For software-engineering topics, include product docs and benchmark/evaluation angles.
2. Run parallel web searches across the angles in one or two batches. In Codex, use `web.search_query` with multiple queries and current/fresh filters when recency matters. Prefer primary sources first: official docs, product docs, technical papers, benchmark reports, security docs, engineering blogs, and release notes.
3. Select **10-20 high-value sources** per topic, balancing primary sources and independent verification. **Tier each source (T1–T4); discard T4 immediately — do not fetch, cite, or carry it forward.** Fetch/open the strongest sources and record source URLs as you go. Avoid using snippets alone for central claims.
4. **Adversarially verify every central claim** per the verification rules above: ≥2 independent sources (≥1 T1/T2), an explicit refute attempt, and a recency check on time-sensitive facts. Cross-check vendor docs vs independent evaluations, papers vs production docs, benchmark claims vs real-world reports. A claim that fails any of these is **contested**, not fact.
5. Build an evidence matrix before writing, one row per central claim: **claim, support URL(s), tier(s) of those sources, independent? (y/n), refute-attempt result, recency, verdict (verified | contested)**.
6. Synthesize one Italian markdown report per topic with the required deliverable structure. Cite every major claim with links. The report **must** contain two clearly separated sections (Italian): **`## Verificato — sicuro da affermare`** (only claims with verdict=verified) and **`## Conteso / incerto — non affermare senza riserve`** (single-source, vendor-only, refuted, contradicted, or stale claims — each with *why* it's uncertain). Inside the body, keep labeling established facts vs vendor claims vs independent findings vs speculation. **Nothing from the contested section may be phrased as established fact.**
7. Save the report to the real temp directory path described in Step 5a, and keep the cited URL list for Step 5b.

**`--bounded` mode — cheaper manual web research.** Use this only when `--bounded` is present.

1. Decompose the topic into **6-8 search angles** (definitions, key entities/products, evidence/benchmarks, risks, future/adoption — adapt to topic).
2. Run those as **parallel web searches in a single batch** (Claude Code: parallel `WebSearch` calls; Codex: built-in `web_search`, `web_search="live"` for fresh results). One pass — do not re-run angles that already returned enough.
3. **Fetch full text only for the 3-6 highest-value sources** (T1/T2: primary docs, papers, vendor docs, independent evaluations) where the snippet is not enough — `WebFetch` (Claude) / fetch (Codex). Skip pages whose snippet already gives the claim. **Discard T4 sources** even here.
4. Synthesize the Italian report from snippets + the few fetched pages. Cite every major claim. Lighter bar than default, but still tier sources and still produce the two-section split — **`## Verificato — sicuro da affermare`** (claim has ≥2 independent sources, ≥1 T1/T2, no contradiction found) vs **`## Conteso / incerto — non affermare senza riserve`** (everything single-source, vendor-only, or unchecked). When the budget didn't allow a refute pass, default a claim to *contested*, not verified.

Soft budget target for default mode: **enough depth to support the video with citations, usually 10-20 sources per topic**. Soft budget target for `--bounded`: **6-10 sources per topic** and fewer fetched pages. More clusters → each research is shallower; that is why Step 0 caps K at ~4. Once findings are solid, stop and proceed.

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

> **Correct Italian diacritics are mandatory.** Write accented letters as real Unicode characters — `è à ò ù é ì` (e.g. `è`, not `e`; `perché`, not `perche`). Never ASCII-fold. This title flows verbatim into the notebook name, the output folder, and every artifact header, so a stripped accent propagates everywhere downstream.

## Step 3: Let the user pick the title

Present the **6 options as a numbered Markdown list** (each: bold title + one-line *why* in Italian), then ask the user to reply with a number `1–6` or paste a custom title.

> **Do NOT use `AskUserQuestion` for this** — that tool caps at **4 options**, so 6 titles will not fit. A numbered text list is the portable path and works identically on Claude Code and Codex.

The result is the **chosen title string** — this becomes both the video title and the notebook name. Do not proceed until the user has picked.

## Step 4: Create the notebook

```bash
notebooklm create "<chosen title>" --use --json
```

Parse the JSON to capture the notebook **id** (and URL if present). `--use` makes it the active context so later `source add` calls target it without `-n`. If create fails, halt: `social-new-notebooklm-project: notebook create failed — <stderr>.` (Research already succeeded; surface the error so the user can retry create without re-researching.)

> **Pass the title verbatim (UTF-8).** Quote the chosen title exactly as written, accents intact — do not run it through `iconv`, `tr`, ASCII transliteration, or any folding. After create, verify with `notebooklm status` (or `list`) that the stored `Title` still shows the accented characters; if they were dropped, `notebooklm rename "<accented title>" -n <id>` to fix before adding sources.

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

- **Only add T1–T3 sources.** Never add a T4 (rejected) URL to the notebook — if one survived into the cited list, drop it here and log it under discarded-low-credibility in the summary.
- **Dedupe the URL list first.** Adding the same URL twice creates duplicate source rows.
- **Cap at 15** cited URLs. If the report cites more, add the 15 most-cited/most-relevant **T1/T2 first**, then T3, and **log every dropped URL** in the final summary (no silent truncation).
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

## Step 6.5: Cleanup pass — prune dead stubs AND low-credibility sources

Failed/blocked adds leave **empty stub rows**, and a weak source can slip past tiering — both pollute the notebook the user will share from. After all adds, list sources and delete the dead **and the low-credibility** ones. `source delete` **requires `-y`** in non-interactive use.

```bash
notebooklm source list --json   # inspect id + title + type
```

Delete a source whose title/content indicates a dead fetch (note the `--json` `id`):

```bash
notebooklm source delete "<source-id>" -y --json
```

Signals to prune:
- Title is a **Cloudflare interstitial**: `Just a moment...` (and similar challenge pages).
- A **paywalled / anti-bot** page that returned no real content (e.g. some `medium.com` posts).
- A **caption-less YouTube** row that registered but has no transcript.
- **Exact-duplicate** rows for the same URL/title (keep one).
- **Low-credibility (T4)** sources that slipped in — SEO content farms, anonymous/undated listicles, AI-slop, marketing fluff, forum/social posts cited as fact. Delete them; the notebook should only hold T1–T3.

Track the source ids you add (from each `--json` result) **with their tier** so the cleanup is precise rather than guesswork. Re-list afterward to confirm the final count.

## Step 7: Print summary and stop

```
✓ NotebookLM pronto — nessun artifact generato.
  Input:           <topic mode | video-seed: N video → K topic>
  Topic ricercati: <topic 1; topic 2; …>   (K researches)
  Modalità ricerca: <codex-agent-deep-research | bounded>
  Titolo video:  <chosen title>
  Notebook:      <id / URL>
  Fonti aggiunte (<N>):
    - <K> report ricerca (it)
    - <V> video seed          (solo video-seed mode)
    - <n> URL citati          (solo T1–T3)
    - <m> fonti extra
  Verifica:        <V verificate; C contese/incerte>   ← rivedi la sezione "Conteso" prima di affermarle nel video
  Fonti fallite:   <list with reason, or "nessuna">
  Stub rimossi:    <count>
  Fonti scartate (bassa credibilità / T4): <list with reason, or "nessuna">
  URL citati scartati (oltre il cap 15): <list, or "nessuno">

Apri il notebook su https://notebooklm.google.com per lavorare allo script del video.
```

Then halt. The skill's contract ends at a populated notebook. **Do not** generate audio/video/report/mind-map artifacts — that is a separate skill. **Do not** create the video.

## Known failure modes (learned)

| Symptom | Cause | Handling |
|---|---|---|
| Step 1 burns huge token counts | launched a maximum-depth multi-agent `deep-research` Workflow | never use that harness; default to the staged Codex-agent research loop, or use `--bounded` for a smaller pass |
| Deep research silently became shallow search | agent used snippets only or one search batch | default path must plan angles, fetch high-value sources, cross-check claims, and produce an evidence matrix |
| User expects ChatGPT UI Deep Research | Codex does not expose that picker as a native skill action | run Codex-agent deep research directly; no `OPENAI_API_KEY` or Responses API helper |
| `Path is a symlink … Refusing to upload` | `/tmp` → `/private/tmp` symlink + CLI guard | write report to the realpath temp dir (5a) |
| `RPCError rpc_code=9` on a YouTube add | Shorts / caption-less video | normalize shorts→watch; if still failing, record, optional captions-as-text |
| Notebook fills with `Just a moment...` rows | Cloudflare-walled URL still created a stub | cleanup pass (6.5) deletes dead stubs |
| Duplicate source rows | blind-retrying a "failed" add that actually registered | add once, never blind-retry; dedupe URL list |
| `source delete` does nothing | missing confirmation | pass `-y` |
| seed video can't be ingested | caption-less / Shorts | add Step 0 captions as `--type text`; else record as failed (never silently drop) |
| too many parallel researches drain budget | seed videos clustered into many topics | Step 0 caps K at ~4 (merge smallest); ~500k budget is shared across clusters, not per-cluster |
| one seed video is private/deleted | unavailable URL | skip it with a warning; halt only if *every* seed fails |
| video states a claim that turns out false/outdated | claim entered report on one source / vendor-only / stale, unrefuted | adversarial verification: ≥2 independent sources (≥1 T1/T2) + refute attempt + recency gate; unverified → contested section, never asserted as fact |
| low-quality source (SEO farm, AI-slop, forum-as-fact) backs a claim | no credibility tiering | tier every source T1–T4; reject T4 in research; never add T4 to notebook; Step 6.5 prunes any that slipped in |
| user can't tell what's safe to say on camera | report mixed fact + speculation | report must split `## Verificato — sicuro da affermare` vs `## Conteso / incerto`; summary prints the verified/contested counts |

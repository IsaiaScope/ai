---
name: social-notebooklm
description: Build a researched NotebookLM notebook from one free-form input — any mix of URLs (YouTube, GitHub, articles, anything) and prose explaining what you want. URLs become sources; their Source Guides plus your prose compose a query that NotebookLM researches itself with native deep research. Use when invoked as /social-notebooklm <free-form input> [--fast] [--title <t>], or when asked to spin up a research notebook for a video. Then turns that notebook into the Scaletta: scaletta-long.md and scaletta-short.md, humanized against your voice profile and checked by the Ramp lint. One skill, notebook through deliverable.
---

# social-notebooklm

One input, any shape. These are all valid:

```
/social-notebooklm come funziona un LLM sotto il cofano
/social-notebooklm https://youtu.be/abc https://youtu.be/def
/social-notebooklm https://github.com/foo/bar spiega a cosa serve, taglio pratico
```

## Why the input does not need to be good

Your phrasing is usually thin, and that is fine. The URLs you pass already
know what they are about: NotebookLM generates a summary, keywords and topic
tags for every source it ingests. The research query is composed from those
plus your prose, so the depth comes from the material rather than from how
well you described it.

That is also why sources are added **before** research runs. Research expands
around what the videos and pages actually say, not around your sentence.

### Prose with no URLs is a different query

With sources present the query ends by asking for what the existing material
does *not* cover — a **narrowing** instruction, since there is something to
subtract. With no sources that same sentence means "everything", and the search
spreads sideways instead of going deep: a prose-only run for *AI vs Machine
Learning vs Deep Learning vs LLM* returned 85 sources, 16 of them about Italian
AI legislation and datacentre energy consumption.

So `build_query.py` switches on whether any Source Guide exists. Both branches
chase the same axes — historical context, objections and criticism, current
data, common misconceptions — but with no sources the framing becomes "go deeper
on the requested topic, do not spread to adjacent ones".

Passing even one URL still gives better results: the guides tell the search what
the material actually says, which no amount of prose does as precisely.

## Run

```bash
cd skills/social-notebooklm
scripts/notebook.sh "<free-form input>" [--title <t>] [--fast]
```

Prints the notebook id on stdout; progress goes to stderr.

Pipeline:

1. `parse_input.py` splits URLs from prose.
2. `expand_urls.py` types each URL for `source add`. A bare GitHub repo URL also
   contributes its raw README — the repo page alone is mostly navigation chrome.
3. `notebooklm create --use` makes the notebook current.
4. Every URL is added. Failures are warned, never fatal.
5. `notebooklm source guide` per source supplies keywords and topic tags.
6. `build_query.py` composes an Italian research query from prose + guides,
   including an explicit instruction to find what the existing sources do *not*
   cover.
7. `notebooklm source add-research --mode deep --import-all --cited-only` does
   the reaching, with a wait budget high enough not to interrupt it.
8. The researched notebook is asked for five social-video titles; you pick one.

## Deep research is not on a clock

Deep research takes as long as it takes, so nothing here cuts it short. The
CLI has no "no limit" value — `--timeout` is an integer — so the wait budget
defaults to `86400`, a ceiling no real run reaches. Override with
`RESEARCH_TIMEOUT` if you want a hard stop.

The number matters because too *small* a value is destructive, not merely
impatient: the CLI's original 5-minute default gave up before `IMPORT_RESEARCH`
fired, and NotebookLM was left showing an unanswered "Add sources?" modal with
the research abandoned mid-flight.

`--fast` selects `--mode fast`. It is cheaper and shallower.

## Filing the notebook in a collection

```bash
scripts/notebook.sh "<input>" --collection social
NOTEBOOKLM_COLLECTION=social scripts/notebook.sh "<input>"     # or set it once
```

Unset, nothing is filed — a collection name is personal, so the skill ships
without one rather than guessing at a destination in someone else's account.
The collection must already exist (`notebooklm collection list` to see them,
`notebooklm collection create` to make one); it is matched by id, id prefix, or
exact name.

Filing happens immediately after the notebook is created, not at the end, so a
run that dies during research still leaves the notebook where you look for it.
A name that does not resolve warns and continues — research is the expensive
part of the run and a typo is no reason to discard it.

## Titles are suggested, not typed

Once research finishes, the notebook is asked for five Italian titles that
would work on social. They are printed, and saved into the notebook as a note
(`--save-as-note`) so they survive to upload time.

The suggestions come from the *researched* notebook, never from the input line
— by then it has read its sources and everything the web search imported, so it
knows the topic far better than whatever was typed to start it.

At a terminal you pick one (Enter takes the first). Spawned unattended by
`social-new-video` there is no tty, so the first is taken silently. Passing
`--title` explicitly suppresses the rename entirely — the suggestions are still
printed and saved, but your title stands.

The chosen title becomes the notebook's name, which the Scaletta half below
turns into the content folder `<YYYY-MM-DD> - <title>`.

## What this no longer does

Codex-agent research is **removed**. Earlier versions ran an external agent
with its own search tools, wrote a report, and added that report as a single
source — with credibility tiering and adversarial fact-verification layered on
top. NotebookLM's native research replaces it: no agent tokens, and real web
sources instead of one summarising report. The tiering and verification went
with it. If a video needs that scrutiny, do it by hand against the imported
sources.

## Known failure modes

| Symptom | Cause | Handling |
|---|---|---|
| `notebooklm login` opens a window then reports "window was closed" or "login not detected" | the bundled Chromium crashes on macOS 15+ | `notebooklm login --browser chrome` (system Chrome) |
| `NotebookLM is not authenticated` before anything runs | the session expired; `notebooklm doctor` still says pass because the local cookie is present | `notebooklm login --fresh` |
| "Add sources?" modal left open in the web UI | the wait budget was cut short | leave `RESEARCH_TIMEOUT` alone; check `notebooklm research status` |
| a URL adds but the source is empty | the page is JS-rendered or gated | pass a direct link to the content, or a raw file URL |
| a GitHub repo yields almost nothing | the repo page is navigation chrome | handled: bare repo URLs also add the raw README |
| research imports nothing | the query was too narrow, or the web search found only already-cited pages | re-run without `--cited-only`, or widen the prose |
| research imports far more than expected, on adjacent topics | a prose-only run with no sources to scope against | handled: the query scopes instead of widening when no Source Guide exists. Prune the strays with `notebooklm source delete <id>`, or pass a URL next time |
| the CLI pegs one core and imports nothing for minutes | catastrophic backtracking in `notebooklm-py` 0.8.1's citation-URL regex (`_URL_RE` is `(?:A+\|B)+`, so cost doubles per character) | patched locally in `research.py` by making the inner quantifiers possessive (`++`, `*+`). **A `uv tool upgrade` erases it** — re-apply, or check whether upstream fixed it |
| the editor stage warns and skips every run | the editor application is not running | open it; the stage needs a live app and cannot launch one for you |
| a re-run lost recorded takes | by design — `delete_recordings` is `true` | rename the project in the editor before regenerating, or pass `NO_EDITOR=1` |

---

# From notebook to Scaletta

`scaletta.sh` is the second half of this skill. It reads the notebook built
above and writes the files you actually film from.

```bash
cd <your content repo root>
<path to this skill>/scripts/scaletta.sh [<notebook id|title>] [--long|--short] [--agent codex|claude] [--voice <file>] [--out <dir>]
```

Run it **from the content repo root**: paths resolve by convention — output to
`./content`, voice profile from `./voice/voice.md`. No notebook argument means
the current one, which is the one just created. The script itself lives in this
skill, not in the content repo, so call it by path.

## What it writes

Into `content/<YYYY-MM-DD> - <notebook title>/`, exactly two files:

```
scaletta-long.md     humanized against voice/voice.md
scaletta-short.md
```

The raw NotebookLM draft is written to the run's temp directory, never to the
content folder — it is scaffolding the lint reads, not something to film from.

## Format rules

- Italian, first person, a bullet list of focal points — talking points expanded
  aloud while filming, never a script read word for word.
- Each focal point is **developed over sub-bullets**, so there is enough in front
  of you to speak from without inventing: the mechanism or definition, a
  contextualized example or data point, and optionally why it matters.
- **Sub-bullets are plain dots** — never lettered or numbered. The model reaches
  for `(a)`/`(b)`/`(c)` even when the prompt does not ask, so `strip_and_write`
  removes the label as well: the prompt says don't, the strip makes sure.
- **A real example is never bare**: what it is, the number or source if there is
  one, and why it proves the point.
- **The Ramp.** At a term's first mention the everyday version or a familiar
  example comes first, the technical name after — and technical depth follows
  only where the topic has depth to give. The HOOK especially must open on
  something concrete, never on a bare technical term.
- **Every** technical term, acronym, law, theory or proper noun is glossed in
  plain Italian at first mention ("X, cioè …").
- No citation numbers, no preamble, no production jargon.

The full Italian prompts live in `scripts/scaletta.sh` (`LONG_PROMPT`,
`SHORT_PROMPT`). They are not duplicated here — a prompt
written in two places is a prompt that drifts.

## Humanize and lint (automatic)

For each length the script writes a draft into its temp directory, pipes it
through the `humanizer` skill via `--agent` (default `codex`, also `claude`),
writes `scaletta-<len>.md` into the content folder, and runs the Ramp lint
(`scripts/lint_scaletta.py`) comparing the two.

The lint has exactly one job: the generation prompts already tell NotebookLM to
gloss every technical term at first mention, and humanizing is a *second* model
rewriting that text. The check is that the rewrite did not drop a gloss the
draft had. Terms come from the draft's own HOOK, so nothing is asked of
NotebookLM and no term list is written.

The agent is called headless with the draft in the prompt and its answer read
from stdout. It never writes a file, so no permission flags are needed and
nothing unattended touches the disk.

A humanize failure writes no final at all. A lint failure keeps the humanized
file and exits non-zero, naming the term whose gloss went missing.

Requires the `humanizer` skill, project-local:

```bash
npx skills add blader/humanizer     # do NOT use --global
```

## Into the editor (automatic)

Once both Scalette are written, `scaletta.sh` calls `editor-script.sh`, which
puts each one into the video editor as ordered **Scenes** — the editor's word
for what you would call chapters. You film a Scene at a time instead of reading
off a markdown file.

Two projects per Content, because aspect ratio is a property of a whole project:

| | project name | canvas | from |
|---|---|---|---|
| long | `<content folder> - long` | landscape | `scaletta-long.md` |
| short | `<content folder> - short` | vertical | `scaletta-short.md` |

The project name is the Content folder whole (`2026-08-28 - Titolo - long`), not
the title alone: the date is what stops two Contents sharing a title from
overwriting one another.

A Scene boundary is a bold line on its own (`**La Matrioska Tecnologica**`).
Both prompts ask for that layout, which is why one rule reads both files. The
heading stays inside the scene's text as well as naming it; nothing else is
altered, so what you film from is byte-for-byte what the lint passed.

### Re-running destroys recordings

**Running this again for a Content deletes that project's existing Scenes and
the Takes recorded against them** — `delete_recordings` is `true`, the `.mov`
and `.wav` media is deleted rather than orphaned, and there is no undo. The
trade is that one Content owns exactly one project per length, always matching
the current Scaletta, with nothing accumulating.

Regenerate Scalette freely *before* recording. After recording, rename the
project by hand in the editor first, or pass `NO_EDITOR=1`.

### Configuration

```bash
NO_EDITOR=1 scripts/scaletta.sh          # skip the stage entirely
EDITOR_TIMEOUT=120 scripts/scaletta.sh   # default 60s
scripts/editor-script.sh "content/2026-08-28 - Titolo"   # run it alone
```

The editor comes from `iso-config`: `editor.bin` and `editor.kind` in
`~/.config/iso/iso.json`, overridable with `SOCIAL_EDITOR_BIN`. Only
`kind: borumi` is implemented; any other value refuses rather than sending
Borumi's tool names to something that does not speak them.

The editor application must be **running** — it is a desktop app, and this is
the one stage that cannot work headless. The stage is therefore non-fatal: a
closed editor warns and the Scalette are still yours.

## Infographics are gone

Earlier versions also generated a 2×2 matrix of four Italian infographics
through a separate `~/.venvs/nblm` Python venv. That was Layer B work living in
a Layer A skill, it carried a quota nobody budgeted, and the venv was a second
NotebookLM install to keep in sync. Removed. `notebooklm generate infographic`
now exists natively if it is ever wanted back.

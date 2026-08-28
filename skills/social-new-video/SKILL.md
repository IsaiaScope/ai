---
name: social-new-video
description: One-shot launcher for a new Italian YouTube video. Spawns a single codex|claude tab (via iso-spawn) that runs social-notebooklm inside itself (free-form input: URLs of any kind and prose, mixed → native deep research). Fire-and-focus: async spawn with --focus, no kill; you own the tab. Use when invoked as /social-new-video <free-form input> [--agent codex|claude] [--fast] [extra-source ...], or asked to spin up a whole new video (notebook + assets) in one go. Default agent codex. Wraps social-notebooklm, which it runs. Requires the iso-spawn skill + a herdr workspace.
---

# social-new-video

The single entry point for a new video. It does **not** do the work itself — it **spawns one agent tab** that runs the whole chain end-to-end, and **focuses you into that tab** so you can pick the title. The chain is:

```
social-new-video  (this skill — the launcher, runs where you invoke it)
   └─ iso-spawn → new codex|claude tab, runs:
        social-notebooklm "<free-form input>"
             sources → native deep research → 5 Italian titles → YOU PICK
             → scaletta long/short, humanized and Ramp-linted
```

Why a spawned tab? Deep research runs uncapped and the humanize pass is another agent call, so the whole thing is long. Isolating it in its own tab keeps your launching session clean. **Topology: everything runs in the spawned tab; you drive the interactive title pick there.** The launcher is fire-and-focus — it spawns async with `--focus` and **does not** kill or babysit the tab. You own its lifecycle afterward.

## Input

Invoked as `/social-new-video <free-form input> [--agent codex|claude] [--fast] [extra-source ...]`.

- `<free-form input>` — **required**. A text topic or one/more YouTube URLs. Forwarded verbatim to `social-notebooklm` (topic mode vs video-seed mode is decided there).
- `--agent codex|claude` — **optional**. Which agent the spawned tab runs. **Default `codex`** (matches the notebook skill's Codex-agent deep-research default).
- `--fast` — **optional**. Selects `--mode fast` instead of deep research. Cheaper and shallower. Forwarded to `social-notebooklm`.
- `[extra-source ...]` — **optional**, zero or more files/URLs. Forwarded as extra sources for the notebook.

If no topic/URL is given, halt: `social-new-video: topic or YouTube URL required.`

## Pre-flight

- The **iso-spawn** skill must be installed (the launcher locates its `scripts/spawn.sh`).
- You must be inside a **herdr** workspace (iso-spawn resolves the tab from `$HERDR_PANE_ID`).
- The spawned agent needs the two chained skills + the `notebooklm` CLI (authenticated) available — they run **inside the tab**, so their own pre-flights apply there, not here. The launcher itself only needs to find `spawn.sh`.

## Run

```bash
cd skills/social-new-video
scripts/run.sh <free-form input> [--agent codex|claude] [--fast] [extra-source ...]
```

`run.sh`:
1. Parses args — splits its own knobs (`--agent`) from what is forwarded to the notebook skill (the free-form input, `--fast`, extra-sources).
2. Locates `iso-spawn/scripts/spawn.sh` (sibling skill dir, then `~/.claude/skills`, then `~/.codex/skills`).
3. Builds an Italian chained prompt instructing the spawned agent to run skill 1 → **stop for the title pick** → run skill 2 on the now-active notebook.
4. Spawns the tab **async with `--focus`** (no `--kill`): `spawn.sh <agent> --prompt "<chain>" --focus`. stdout is the `TERM` handle.

After it returns: **switch to the focused tab**, pick your title when the 5 options appear, and let it finish. It writes both scalette to `content/<YYYY-MM-DD> - <title>/`, humanized against `voice/voice.md`. Each humanized file is checked against its own draft: if the rewrite dropped a gloss, it stops and names the term.

## Lifecycle (you own the tab)

The launcher exits right after spawning; it never polls or kills. When the chain is done and you've collected the assets, tear the tab down yourself with iso-spawn:

```bash
# from the launcher's iso-spawn, using the printed TERM:
<iso-spawn>/scripts/spawn.sh cleanup "<TERM>" --kill
# or the end-of-run safety net:
<iso-spawn>/scripts/spawn.sh cleanup --orphaned
```

## Known failure modes (learned)

| Symptom | Cause | Handling |
|---|---|---|
| `could not find iso-spawn/scripts/spawn.sh` | iso-spawn skill not installed | install the engineering plugin / run `node scripts/install.js` so iso-spawn is symlinked |
| spawn does nothing / no tab | not inside a herdr workspace | run from a herdr pane (iso-spawn needs `$HERDR_PANE_ID`) |
| title prompt never answered, chain stalls | you didn't switch to the spawned tab | the pick is interactive **in the tab**; `--focus` jumps you there — answer with a number 1–6 |
| agent skipped the title pick / auto-chose | prompt not followed | the injected prompt says "NON saltare la scelta del titolo"; if an agent still rushes, send it `social-notebooklm` again or pick manually |
| tab left running after you're done | launcher never kills (by design) | tear down manually with iso-spawn `cleanup --kill` / `cleanup --orphaned` |

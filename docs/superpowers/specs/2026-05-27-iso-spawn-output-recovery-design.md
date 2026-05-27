# iso-spawn output recovery — design

**Date:** 2026-05-27
**Skill:** `skills/iso-spawn` (`scripts/spawn.sh`)
**Status:** approved design, pending implementation plan

## Problem

`iso-spawn` launches a `codex`/`claude` agent in its own herdr tab, injects a prompt,
and reports lifecycle status. When the agent finishes there is **no way to recover
what it produced**. The caller (an LLM running in discrete turns) keeps only the
`terminal_id` (`TERM`) handle; the agent's actual work lives only in:

- herdr's terminal **scrollback** — bounded (~27 KB observed live), ANSI/TUI chrome,
  no turn boundaries, evicts early turns on long runs; and
- the agent's own **JSONL transcript** on disk — complete, but outside herdr.

`--wait` blocks until the agent goes idle but returns only the status word, never content.

**Goal:** recover a spawned agent's output via a `--recover` command — the clean final
answer by default, the full transcript on demand — keyed off the stable `TERM` handle,
working both as a `--wait` companion and standalone for background spawns recovered later.

## Findings (verified empirically, 2026-05-27)

herdr's only agent-content surface is screen-scraping; there is **no** structured
output/event/transcript API:

| herdr command | content? | limit |
|---|---|---|
| `agent read` / `pane read` (visible\|recent\|recent-unwrapped) | screen scrape | bounded scrollback, ANSI/TUI chrome |
| `agent get` / `list` | status word only | no content |
| `agent wait` / `wait agent-status` | block on status | no content |
| `wait output <pane> --match <text> [--regex]` | block until text on screen | unblocks on match; returns no content |
| `agent attach` | human takeover | not programmatic |

The complete record lives in per-agent JSONL:

- **codex** → `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl`.
  Line 1 is `session_meta` carrying `cwd` and `id` (== filename uuid).
  Final answer = the `event_msg` line with `payload.type == "agent_message"`
  (`payload.message`). Verified: extracted exact one-line answer, zero chrome,
  single occurrence — vs scrollback which showed it twice (prompt echo + answer)
  inside box-drawing chrome.
- **claude** → `~/.claude/projects/<slug>/<session-uuid>.jsonl`,
  `slug` = cwd with `/` → `-` (e.g. `/Volumes/Crucial-4T/repo/ai` →
  `-Volumes-Crucial-4T-repo-ai`). Final answer = last line with `type == "assistant"`,
  text in `message.content[].text`.

**Verdict:** native JSONL is the primary source (complete + clean, serves both
"final output" and "entire chat" tiers); scrollback is a degraded fallback only.

## Scope

**In scope**
- `--recover <TERM> [--what output|chat] [--format text|json]` — standalone.
- `--wait --recover[=output|chat]` — block until idle, then print recovered output.
- Spawn-time `TERM → session_file` mapping, captured race-free.
- Merge the existing `.log` and the new mapping into one `.spawn` sidecar per spawn.
- Scrollback fallback when the JSONL cannot be mapped.
- `.gitignore` `.iso/`.

**Out of scope** (separate future specs)
- Interactive multi-turn answering / driving the agent (modality detection +
  semantic verify loop). Mechanism is mapped but materially larger than recovery.
- Sentinel-based completion (`<<SPAWN_DONE>>` + `wait output --match`) as a sharper
  trigger than `--status idle`. Optional future enhancement.

## Design

### Output delivery
`--recover` prints to **stdout only** (no persisted recovery file). The caller captures
the Bash tool result directly. The transcript JSONL already persists on disk as the
durable artifact; re-running `--recover` re-reads it.

### Component 1 — spawn-time mapping capture
Capture which JSONL belongs to this spawn, race-free, via snapshot-diff:

1. **Parent**, before `agent start` (spawn.sh:122): snapshot the existing candidate
   transcript set for this agent+cwd and record it **inline** in the sidecar (no
   separate snapshot file):
   - codex → set of existing `~/.codex/sessions/**/rollout-*.jsonl`
   - claude → set of existing `~/.claude/projects/<slug>/*.jsonl`
2. **`__deliver`** (runs in *both* `--wait` foreground and background paths): once the
   prompt is confirmed accepted (agent is live → its JSONL now exists), compute
   `new = post-set − pre-set` and append `session_file=<abs path>` to the sidecar.
   - Resolve the *path* early; read the *content* late. The JSONL keeps growing as the
     agent works, so a background spawn recovered minutes later still reads the complete,
     final transcript.

Snapshot-diff is race-proof even with concurrent same-cwd spawns: each spawn's "new
file" is the one that appeared between its own pre and post snapshots.

### Component 2 — the `.spawn` sidecar (merges `.log` + mapping)
One file per spawn replaces today's background-only `.log`:

```
.iso/logs/spawn/<date>__<agent>__<name>__<TERM>.spawn
  [meta]                          # always, both --wait and background
    term=<TERM>
    agent=codex|claude-code
    cwd=<abs>
    slug=<claude slug>            # claude only
    pre=<newline-joined pre-snapshot paths>   # fallback if session_file unresolved
    session_file=<abs path>       # appended by __deliver once resolved
  [trace]                         # delivery xtrace
    ...                           # background: always; --wait: only if ISO_TRACE=1
```

| path | meta block | trace block |
|---|---|---|
| `--wait` | written by `__deliver` | only if `ISO_TRACE=1` |
| background | written by `__deliver` | always (preserves today's diagnostic) |

- `--recover` reads the **meta block** → `session_file` → transcript.
- Debugging a stuck spawn reads the **trace block** (unchanged purpose: diagnose a
  silently-lost prompt / `set -e` worker death / unrecognised trust modal).
- File **count is unchanged** vs today — one sidecar per spawn, not two.

### Component 3 — `--recover` mode
New top-of-script branch beside `__deliver`:

```
spawn.sh --recover <TERM> [--what output|chat] [--format text|json]
```

Resolution order for the transcript file:
1. `session_file=` from the `.spawn` meta block (O(1), normal path).
2. else `post-set − pre` (recompute from the `pre=` block).
3. else newest-by-mtime JSONL in the agent's dir matching `cwd`.
4. else **scrollback fallback**: `herdr agent read <TERM> --source recent --lines <BIG>
   --format text`, strip the JSON envelope, print with a header
   `# source: scrollback (jsonl unmapped; may be truncated)`.

Extraction:
- `--what output` (default) → last assistant turn → clean final answer.
- `--what chat` → full ordered transcript, role-prefixed (user / assistant turns).
- `--format text` (default) → plain text. `--format json` → structured `[{role,text}]`.

### Component 4 — per-agent adapters
Two small functions per agent, isolated so a third agent later = one adapter:
- `locate_<agent>` — produce the candidate-set glob (capture) and parse `session_meta`
  for verification (codex `cwd`/`id`).
- `parse_<agent>` — extract `output` (last assistant message) and `chat` (all turns):
  - codex: output = last `event_msg`/`agent_message`; chat = ordered `response_item`/
    `message` lines (+ user `event_msg`).
  - claude: output = last `type==assistant` text; chat = ordered user+assistant lines.

### Component 5 — hygiene
- Add `.iso/` to the repo `.gitignore` (`.iso/` is currently **not** ignored, so the
  existing `.log` and the new `.spawn` would otherwise pollute `git status` / risk
  accidental commits).
- **Retention prune** (optional): on each spawn, delete `.iso/logs/spawn/*` older than
  7 days to bound growth of the per-spawn sidecars.

## Data flow

```
parent:    snapshot pre-set → write .spawn [meta] (term,agent,cwd,slug,pre)
__deliver: confirm accepted → new = post − pre → append session_file=
           (background also writes [trace]; --wait writes [trace] only if ISO_TRACE=1)

--recover <TERM>:
  read .spawn [meta] → session_file
    └─ unresolved → post−pre → newest-by-mtime → scrollback fallback
  parse(output|chat) per agent adapter
  → stdout   (text | json)
```

## Error handling

- **Agent not idle** at `--recover` → warn on stderr ("output may be partial"), still
  extract what is on disk.
- **No assistant text found** → print `# (no assistant output found)`, non-zero exit.
- **JSONL gone / unmappable** → scrollback fallback with the header note above.
- All herdr calls in any worker context keep the existing `|| true` guarding
  (REFERENCE.md:86-92) — a non-zero command must not silently kill the process.

## Testing (TDD)

1. **codex output**: spawn with a known token, `--recover output` → asserts the exact
   token, **single** occurrence, no box chrome (contrast: scrollback returns it 2× with
   chrome).
2. **codex chat**: `--recover chat` → contains the prompt and the answer, ordered.
3. **claude output / chat**: same shape against the claude adapter.
4. **Mapping race**: two concurrent same-cwd spawns → each `.spawn` resolves to a
   distinct `session_file`.
5. **Fallback**: hide/remove the JSONL and the `session_file=` line → `--recover` falls
   back to scrollback and emits the header note.
6. **`--wait --recover`**: one blocking call returns the answer to stdout after idle.
7. **Sidecar**: meta block written on both `--wait` and background paths; trace block
   present in background, absent under `--wait` without `ISO_TRACE`.

## Open questions

None blocking. Retention prune (Component 5) is optional and can ship in a follow-up if
the implementation plan prefers to keep the first change minimal.

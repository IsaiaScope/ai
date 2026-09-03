# One branch, one ticket — multi-plan accumulation in `iso-issue-tracking`

**Status: designed, 2026-08-28. Not implemented.** Grilled to an empty frontier; every decision below
was put to Iso and confirmed. Implementation belongs in this repo
(`skills/iso-issue-tracking/`), on its own branch, tracked by its own ticket in project `ai`.

**Goal:** a branch maps to exactly one ticket, no matter how many plans land on it or how far those
plans diverge. Today it does not, and the failure is silent.

---

## What went wrong

Two rows, one branch:

| key | repo | branch | status |
|---|---|---|---|
| `FIRE-20` | social | `feat/script-layer` | in_review |
| `FIRE-21` | social | `feat/script-layer` | in_review |

Timeline from `~/.claude/multica/log`:

| when (UTC) | event |
|---|---|
| 2026-08-28 07:34 | `replan` fires correctly on FIRE-20 — plan `2026-08-28-feat-notebooklm-native-pipeline.md`, status back to `todo` |
| 2026-08-28 07:53 | FIRE-20 → `in_review` |
| 2026-08-28 19:26:02 | `open needs <session_id> <title>` — a malformed, hand-assembled `open` |
| 2026-08-28 19:31:57 | FIRE-21 exists |

`replan` is not broken. Plan 2 went through it correctly. Plan 3 bypassed it 11.5 hours later, while
FIRE-20 was live, in the ledger, in the right repo, on the exact branch.

### Three causes, one shape

1. **`open` never looks.** `tracking.sh:483-540` resolves the project, builds the body, and calls
   `tk_issue_create` unconditionally. No branch lookup, no ledger check.
2. **The rule lives in prose.** `iso-plan/SKILL.md:103-109` instructs the agent to run
   `ticket-for-branch` and branch on the result. `iso-issue-tracking/SKILL.md:97`, `:112` and
   `:381-383` present `open` with no gate beside them at all, and `:97` states the precondition as
   "no matching issue" — left entirely to the model's judgement.
3. **No caller is a script.** Grepping every `*.sh` under `skills/` and `~/.claude/` for the `open`
   or `replan` subcommand returns zero non-test hits. Every caller is a model typing a command out
   of a document.

A rule enforced by prose holds exactly as long as the agent reads the right document.

### Two aggravating bugs

- **`ticket_for` ends in `head -1`** (`tracking.sh:129`), so `ticket-for-branch` reports FIRE-20 and
  FIRE-21 is invisible. `/iso-plan` would replan onto FIRE-20 forever and never surface the duplicate.
  `rebranch` would move FIRE-20 and strand FIRE-21 on the old branch name without a warning.
- **`ticket_for` scopes on `.repo == project_for($PWD)`** (`tracking.sh:126`), so the lookup returns
  empty from any checkout other than the one that opened the ticket — the dedupe fails silently and
  a duplicate is minted. (Not the cause here: exactly one `social` checkout exists.)

### And a data-loss bug behind it

`replan` **destroys the superseded plan.** `tracking.sh:456-464` rebuilds the description from
scratch via `ticket_body` and pushes it with `tk_issue_describe` — replace, not patch. The only
surviving trace of the previous plan is one comment naming its path (`:465-467`). Plan 1's
description on FIRE-20 is already gone.

Two further defects in the same arm: `do_bind` constructs a fresh ledger row rather than patching
(`tracking.sh:257-258`), silently dropping the `pr` field the reconciler wrote at `:604`; and the
title is never updated, because `tk_issue_describe` sends only `--description-stdin --no-start`
(`adapters/multica.sh:68-70`) though CLI 0.4.36 does support `issue update --title`.

---

## Design

### The core move: ledger is truth, board is a projection

`plan` stops being a string and becomes an array:

```json
"FIRE-20": {
  "repo": "social",
  "branch": "feat/script-layer",
  "project": "social",
  "opened_by": "claude",
  "plan": [
    { "path": "docs/superpowers/plans/2026-08-27-feat-script-layer.md",            "state": "done" },
    { "path": "docs/superpowers/plans/2026-08-28-feat-notebooklm-native-pipeline.md", "state": "superseded" },
    { "path": "docs/superpowers/plans/2026-08-28-feat-editor-script.md",           "state": "current" }
  ]
}
```

`state` is one of `done` (implemented), `current` (being worked), `superseded` (abandoned mid-way).

`ticket_body` (`tracking.sh:284-309`) already builds the description from scratch — it just builds it
from one plan. It loops the array instead, emitting one section per plan, chronological. The body is
therefore a **pure function of `tracked.json`**: it is never read back off the board, so there is no
read-modify-write and a bad render is repaired by re-rendering. This is what makes a multi-section
body safe, and it is the load-bearing decision of the whole design.

The `/iso-write <path>` command is emitted **only on the `current` section**; `done` and
`superseded` sections keep the plan path as plain text. A runnable command on a stale plan is a trap.

### Two verbs, because there are two truths

| verb | means | previous plan becomes |
|---|---|---|
| `addplan` | the last plan finished; here is the next one | `done` |
| `replan` | the last plan was wrong; this replaces it | `superseded` |

Both re-render the body from the array. Both accept an optional `--title` so the title can be
broadened to an umbrella as the topics on a branch diverge; omitted, the title stands, so plan 2 on
the same topic does not churn it. This needs a new adapter verb wrapping `issue update --title`.

`replan` marking rather than deleting is what ends the data loss described above.

### `open` enforces, and cannot be talked out of it

`open` calls `ticket_for_branch` itself. On a live hit it **auto-redirects** to `addplan`, returns
the existing key, and logs loudly to stderr and to the log.

Refusal was considered and rejected: a refusal hands the decision back to the thing that already
skipped a decision point, and a model that cannot create a ticket may cut a new branch or retry with
a different title. The redirect makes the wrong outcome unreachable rather than merely reported.

There is **no `--force-new`**. A hatch is the same gate one layer down, and the forgetfulness that
skipped `ticket-for-branch` will reach for the hatch when the redirect is inconvenient. Work that
truly deserves its own row deserves its own branch.

"Live" excludes `done` and `cancelled`, which `ticket_for` already suppresses (`:118-133`) and
`reconcile` already `ledger_del`s on close (`:624`). So a branch name reused after a merge finds
nothing and opens a fresh ticket — correct: finished work is finished.

### Status

A plan landing on a row that is `in_review` moves it to `in_progress`. `in_review` while code is
being written is false; `todo` claims nothing has started, also false. The reconciler may push it
back to `in_review` while the PR is genuinely open — that is the reconciler doing its job, and this
design accepts a row that oscillates over one that lies.

### Silence removed

Every operation that reports success must have achieved it, and every mutation must leave a trace.

- Successful `open` / `addplan` / `replan` each log one line. Today a successful `open` logs
  nothing — which is why the cause of FIRE-21 is inferred from a typo rather than read from a record.
- `tracking.sh:333` — the guard that makes every subcommand `exit 0` outside a git repo — logs
  instead of vanishing.
- `set_status` stops returning success it did not achieve (see FIRE-19 below).

### Fixes riding along

- `.repo` scope filter (`tracking.sh:126`) so the lookup works from any checkout.
- `head -1` (`tracking.sh:129`) so a second row on a branch is visible at all.
- Stale `CLI 0.4.26` comments in `adapters/multica.sh:27-28` and `:44`; installed is **0.4.36**
  (commit `c1a61e1e8`, built 2026-08-28).

### Migration

The ledger reader coerces a string `plan` into `[{path, state:"current"}]`. Rows upgrade lazily on
next write. No migration script: two live rows, and the coercion is needed anyway for any ledger
predating this change.

### Documentation

`iso-plan/SKILL.md:103-109` **keeps** its gate — a redirect that never fires is cheaper than one
that does.

`iso-issue-tracking/SKILL.md:97`, `:112` and `:381-383` are rewritten: `open` is now always safe to
call and redirects if the branch is held. The "no matching issue" precondition at `:97` is deleted —
a document describing a precondition the code no longer has is how the next model gets confused.

### Tests

`tracking.test.sh:182-197` looks like it covers this and does not: it builds two rows on the same
branch name in *different* repos and asserts that `.repo` scoping keeps them apart. Same repo, same
branch is never exercised. Add three cases:

1. **same repo + same branch → `open` redirects, does not create.** This is the case that would have
   caught FIRE-21.
2. **render idempotence** — same ledger in, same body out.
3. **string → array coercion** on read.

---

## Cleanup

| row | action |
|---|---|
| `FIRE-20` | keeps everything; plan 3 lands via `addplan` |
| `FIRE-21` | → `cancelled`. No delete or archive exists in the adapter *or* in CLI 0.4.36; `cancelled` is the only disposal |
| `FIRE-19` | ledger correctly empty (reconciler closed it at 17:01 and `ledger_del`'d). Board still reads `in_review` while `set_status` logged success at `log:287` — push the row to `done` and root-cause the lying return code |

## Out of scope

`reconcile: gh unavailable - no cancellation this run` ×9 (08-28 08:54–08:58), during which
reconciliation silently did nothing. Arguably correct — no network, no judgement — but it deserves
its own look, not a rider on this change.

## Environment note

This checkout emits AppleDouble noise on every git invocation:

```
error: non-monotonic index .git/objects/pack/._pack-a616baffbb05d2d538596c8c9a169ed66d301b60.idx
```

macOS resource forks on the external drive. Commands still return, but it will pollute anything that
parses git output. Clear with:

```sh
dot_clean -m /Volumes/Crucial-4T/repo/ai/.git && rm -f /Volumes/Crucial-4T/repo/ai/.git/objects/pack/._*
```

---

## Worked example: FIRE-20 + FIRE-21, merged

The real rows, rendered under this design. Three plans, one branch
(`feat/script-layer`, repo `social`), one ticket.

### Ledger

```json
"FIRE-20": {
  "repo": "social",
  "branch": "feat/script-layer",
  "project": "social",
  "opened_by": "claude",
  "plan": [
    { "path": "docs/superpowers/plans/2026-08-27-script-layer.md",                   "state": "done" },
    { "path": "docs/superpowers/plans/2026-08-28-feat-notebooklm-native-pipeline.md", "state": "done" },
    { "path": "docs/superpowers/plans/2026-08-28-feat-editor-script.md",             "state": "current" }
  ]
}
```

Note plan 1 is `done`, not `superseded`. It was implemented and moved to `in_review` on
2026-08-27 16:07 (`log:285`) *before* `replan` ran against it on 2026-08-28 07:34. `replan` was the
only verb available, so the board recorded "superseded by" for work that had actually shipped. This
is precisely the case `addplan` exists for.

### Section states

| marker | state | `/iso-write` line |
|---|---|---|
| `✅` | done | omitted |
| `▶` | current | emitted |
| `⊘` | superseded | omitted |

### Rendered title

Today: `🎬 Scalette get a voice and a ramp` — written for plan 1, still on the row while the body
describes plan 2. The umbrella replaces it, supplied via `--title` on the `addplan` that added
plan 3:

```
🎬 The script layer: research, voice, and Scenes
```

### Rendered body

```markdown
The `feat/script-layer` branch turns a hand-driven scripting process into a pipeline. Three plans
land on it: the Scaletta gains a voice profile and a Ramp lint, its research stops depending on a
Codex agent and moves to NotebookLM's own deep research, and the resulting sections become ordered
Scenes inside the video editor. Each plan builds on the one before it; none replaces another.

## ✅ Scalette get a voice and a ramp

`docs/superpowers/plans/2026-08-27-script-layer.md` — done

> Description not recoverable: this plan's body was overwritten by `replan` on 2026-08-28 before
> section states existed. Under this design it would have been preserved.

## ✅ NotebookLM native pipeline

`docs/superpowers/plans/2026-08-28-feat-notebooklm-native-pipeline.md` — done

The pipeline stops depending on an external research agent and on the operator writing a good
prompt. One free-form input — any mix of URLs and prose — becomes a notebook NotebookLM researches
itself in depth, then a humanized, lint-checked Scaletta with no manual step. The previous plan
shipped a hand-written Brief, a Codex research pass, and an agent-in-the-loop humanize step; all
three are removed here.

| Thing | Before | After |
|---|---|---|
| research | Codex agent + report file | `notebooklm add-research --mode deep` |
| input | topic OR youtube-url | free-form: any URLs + any prose, mixed |
| query | operator typed it | prose + Source Guide keywords and tags |
| github URL | one thin repo page | repo page + raw README |
| term list | hand-written `brief.md` | `termini.md`, asked of the notebook |
| humanize | manual agent step in SKILL.md | `codex exec` / `claude -p`, stdout only |
| lint | run by hand afterwards | run by `scaletta.sh`, hard fail |

**Why**
- no brief means nothing to write and nothing to keep in sync
- a term list asked of the sources cannot contradict them
- the manual step was the only thing between draft and deliverable

**Watch out**
- reverses the earlier decision that headless would break agent-independence
- every generation now spends agent tokens on two humanize passes

## ▶ Scaletta becomes Scenes in the video editor

`docs/superpowers/plans/2026-08-28-feat-editor-script.md` — current

The Scaletta stops being something you read off a markdown file while filming and becomes ordered
Scenes inside the video editor, pushed automatically at the end of every `scaletta.sh` run. Until
now the editor had no idea a Content was divided into sections at all, so every recording started as
one undifferentiated take. From here each Content owns two editor projects — one landscape for the
long video, one vertical for the Short — and you film a chapter at a time.

| Thing | Before | After |
|---|---|---|
| after `scaletta.sh` | two markdown files, nothing else | plus two editor projects |
| filming unit | whole video, one take | one Scene per section |
| short scaletta layout | inline bullets | bold section headings, same as long |
| editor binary | not addressed at all | `editor.kind` / `editor.bin` in iso-config |

**Why**
- the editor already models the missing structure: a Scene is an ordered, scripted section recorded and edited independently
- canvas format is a project-level property, so the vertical Short and the horizontal long video cannot share one project
- two split rules were only needed because two prompts emitted two different layouts

**Watch out**
- **Re-running destroys recordings.** Existing Scenes are deleted with `delete_recordings: true`, so any Takes recorded against them are gone, not orphaned. There is no undo. Deliberate — see ADR 0002.

---

**Resume the session:**

```bash
cd /Volumes/Crucial-4T/repo/social && claude --resume <session-id> --dangerously-skip-permissions
```

**Then implement the plan:**

```
/iso-write docs/superpowers/plans/2026-08-28-feat-editor-script.md
```
```

### What this demonstrates

- **One `/iso-write` line, not three.** Only the `current` section carries a runnable command; the
  two `done` sections keep their paths as text.
- **The umbrella title covers three topics** that no single plan's title could.
- **Plan 1's body is a hole**, and the hole is the point: `replan` deleted it on 2026-08-28, and
  nothing in the current design can bring it back. Every future plan is preserved.
- **The resume block appears once**, at the end, not once per plan.

### Cleanup to reach this state

1. `addplan` plan 3 onto FIRE-20 with the umbrella `--title`, marking plan 2 `done`.
2. Correct plan 1's state from `superseded` to `done` in the ledger.
3. FIRE-21 → `cancelled` with a comment pointing at FIRE-20. No delete exists in the adapter or in
   CLI 0.4.36.

FIRE-21's own description carries a corrupted tail — `editor is adsff/iso-write docs/...` — a
mangled paste from the hand-assembled `open` at `log:311`. Further evidence that the create path had
no gate in front of it.

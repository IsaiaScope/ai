---
name: iso-plan
description: Planning-only chain. Runs brainstorming → grilling → (prototype, only when needed) → writing-plans in order, then renders a visual summary of the finished plan file. Inside a repo the grill step uses grill-with-docs and halts if setup-matt-pocock-skills has not been run; outside a repo it uses grill-me. No state, no implementation. Use when the user runs /iso-plan, optionally with a seed idea as the argument.
---

# iso-plan

Take a raw idea and turn it into a written implementation plan by running four skills in order. The only artefact is the plan file — nothing is implemented and nothing is committed. The one piece of state it writes is the Multica ticket that tracks the plan, and only inside a repo. When the plan is written, tell the user where it lives.

## Pipeline

```
brainstorming   → superpowers:brainstorming   (always)
grilling        → grill-with-docs | grill-me  (always — gated, see step 2)
prototype       → prototype                   (only when needed — agent's call)
writing         → superpowers:writing-plans   (always)
```

## Steps

Run each via the Skill tool, in order. The skills share this conversation's context, so the design carries forward automatically — there is no handoff artifact between steps.

If the user passed an argument, it is the seed idea — hand it to brainstorming. If not, brainstorming starts from the conversation so far.

1. **brainstorming** — invoke `superpowers:brainstorming`. Explore intent, requirements, and shape of the idea.

2. **grilling** (gated) — which grill skill runs depends on where you are. Resolve it with one check, before invoking anything:

```bash
scripts/plan.sh gate     # -> no-repo | setup-done | setup-missing
```

   | state | action |
   |---|---|
   | no-repo | invoke `grill-me` — no domain model to grill against |
   | repo + setup-done | invoke `grill-with-docs` — stress-test against `CONTEXT.md` + ADRs, sharpen terminology, update docs inline |
   | repo + setup-missing | **halt the chain** |

   `docs/agents/domain.md` is written by `setup-matt-pocock-skills`; its absence means `grill-with-docs` has no configured domain-doc layout to read, so it would invent one. Do not fall back to `grill-me` inside a repo, and do not run setup yourself — the user picks the issue tracker and label vocabulary. Print this and stop:

   ```
   iso-plan: halted — repo not set up for grill-with-docs.
   Run /setup-matt-pocock-skills first, then re-run /iso-plan.
   ```

   No plan file is produced, so the chain stops cleanly on its own.

3. **prototype** (conditional) — the agent decides autonomously whether it's needed; **do not ask for approval**. Run `prototype` only when grilling left a question that can't be settled by talking (UI feel, viability of a state machine / data model). Otherwise skip it. Its learnings carry forward into writing.

4. **writing** — before invoking, snapshot the current newest plan so you can tell what's new:

```bash
before=$(scripts/plan.sh newest)
```

   Then invoke `superpowers:writing-plans` to turn the agreed design into a step-by-step plan file.

## Output

`superpowers:writing-plans` saves the plan under `docs/superpowers/plans/`. After it returns, find the newest file and confirm it is actually new:

```bash
after=$(scripts/plan.sh newest)
```

If `after` is empty or equals `before`, `writing-plans` produced no new plan — say so and stop; do not render a ticket for a stale file. Otherwise `after` is the plan to summarize.

Read that file and extract, for the summary:

- **Title** — the first `#` heading.
- **Goal** — the text after `**Goal:**` (or the first paragraph if absent).
- **Phases / sections** — the `##` headings (skip boilerplate like "Goal", "Status").
- **Tasks** — count of checkbox lines (`- [ ]`). Group counts per phase if the plan is phased.
- **Files touched** — any file paths the plan names as created/modified, if listed.
- **Covers** — 3–6 dots naming what the plan actually delivers. Derive these from the phases and task titles you already read; do not re-read the plan. Write outcomes, not headings retyped — "auth tokens rotate on refresh", not "Phase 2: Auth". Skip pure-chore tasks (rename, tidy, bump). Fewer than 3 real outcomes → list what there is.

## Tracking

Open the Multica ticket for this plan, before rendering the summary. This is the
only step in the chain that can judge scopes: a model is live and has just read
the plan. A `SessionEnd` file scan can count `### Task N:` headings but cannot
tell `be` from `ci`.

**Guard it.** Run the open only when both hold, and carry on silently when
either does not — outside a repo there is no project to file against, and a
missing script is not an error here:

```bash
S=$(scripts/plan.sh tracker) || S=""   # empty when tracking cannot run
```

Tracking must never be able to fail a planning run. No ticket is a small loss; a
`/iso-plan` that dies because a board was unreachable is a large one.

**One plan, one ticket.** No sub-issues, no `--parent`. A plan across three scopes
is one ticket carrying three scope labels.

**But a ticket can outlive its plan.** When the first attempt was wrong, or came
back from review needing a different approach, the second plan is the *same*
piece of work — so it goes on the same ticket. Ask before writing:

```bash
existing=$("$S" ticket-for-branch)   # "<KEY>\t<status>", or empty
```

| result | what to do |
|---|---|
| empty | `open` — no live ticket for this branch, this is new work |
| `FIRE-13\tin_review` | `replan` — attach to that ticket and send it back to `todo` |

`ticket-for-branch` only names tickets that are still live; `done` and `cancelled`
read as empty, because a new plan against shipped work is new work. Say which
one you took, and which ticket:

> Attaching to **FIRE-13** (was `in_review`) — this supersedes the earlier plan.

`replan` takes the same stdin body as `open`, replaces the description with it,
posts a comment naming the plan it superseded, and moves the ticket to `todo`.
Nothing has been implemented against the new plan yet, so `todo` is the honest
status — `/iso-write` still owns the move to `in_progress`.

```bash
printf '%s\n' … | "$S" replan "$SESSION_ID" --plan "$after"
```

Pass `--key FIRE-13` when the user names a ticket the branch lookup would miss —
an explicit key always wins. Everything below applies to both verbs.

**Write the ticket as a briefing.** You have just read the whole plan — this is
the only moment anything can. Follow the shape `iso-issue-tracking` defines: three or
four sentences of prose first, then whatever makes it concrete.

The prose is the part that must not be skimped. Four sentences drawn straight
from the plan: what it changes, what it replaces, why the old thing was wrong,
and what it means going forward. Below that, append the shapes the plan actually
gives you — its before/after pairs become the table, its motivation section
becomes **Why**, its prerequisites and irreversible steps become **Watch out**.
Everything in **English**. Write no scope line and no plan path: scopes are a
structured field already, and `--plan` makes `open` append two copy-ready blocks
under the body — the `claude --resume` command, then the `/iso-write <plan>`
slash command to paste into it.

**A plan spanning different parts of the app repeats the pattern per topic.**
Give each a `##` heading — `## Ingest`, `## Scheduling` — then the same shape
underneath: three or four sentences, then its own table and dot lists. Two or
three topics is the useful range; past that the headings are a table of contents
and belong in the plan file. This is the job sub-issues used to do, without the
four rows nobody ever moved.

Roughly 40 lines per topic. Prose gets the room it needs — the thing that does
not belong on the ticket is step-by-step detail, which `--plan` already links.

```bash
printf '%s\n' \
  'The wiki stops relying on a nightly crawl and gets an explicit `wiki ingest`' \
  'command, plus a scheduled push at 03:07. The crawl was implicit and silent,' \
  'so any page created after midnight stayed invisible until the following' \
  'night. From here, ingest is something you run and can watch fail.' \
  '' \
  '| Thing | Before | After |' \
  '|---|---|---|' \
  '| ingest | implicit nightly crawl | `wiki ingest <path>` |' \
  '| push | by hand | cron 03:07 |' \
  '' \
  '**Why**' \
  '- the crawl skipped every page created after midnight' \
  '- no way to force a reindex without waiting for the night' \
  '' \
  '**Watch out**' \
  '- `WIKI_INGEST_TOKEN` must be in secrets **before** the deploy' \
  | "$S" open "$SESSION_ID" "🌱 Wiki ingest becomes explicit" \
      --plan "$after" --scope be --scope ci --scope doc
```

Title and emoji follow `iso-issue-tracking`: a plain sentence a human understands,
emoji for the type of change. Everything is piped on stdin — multi-line safe, no
quoting, and redacted before it reaches the board.

The ticket opens at `todo` and stays there. `/iso-write` moves it to
`in_progress`; nothing here promotes it.

## Summary ticket

Render a summary ticket (do not just print the path). Use a left-rule style — a header line with an underline rule, then indented sections. **No right-side border and no box frame** — never pad lines to a fixed width, since that aligns unreliably. Shape:

```
  PLAN READY
  ────────────────────────────────────────
  <Title>

  Goal
    <one-line goal>

  Covers
    • <outcome>
    • <outcome>
    • <outcome>

  Breakdown                        <N> tasks
    ├─ <Phase 1>     (<n>)
    ├─ <Phase 2>     (<n>)
    └─ <Phase 3>     (<n>)

  Files
    • <path/to/file>        (new)
    • <path/to/other>       (modified)

  📄  docs/superpowers/plans/<YYYY-MM-DD-...>.md

  Next
    /iso-write docs/superpowers/plans/<YYYY-MM-DD-...>.md
```

Keep it scannable — truncate long titles to one line. If a plan is flat (no phases), list tasks directly under **Breakdown** instead of the phase tree. Omit a section entirely (e.g. **Files**) if the plan doesn't specify it rather than printing it empty — but **Covers** and **Next** always render.

**Next** carries the real plan path, not a placeholder — the user should be able to copy the line as-is. It is a suggestion only: print it and stop. Never invoke `iso-write` yourself, and never offer to; iso-plan implements nothing.

Then halt.

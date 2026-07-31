---
name: iso-plan
description: Planning-only chain. Runs brainstorming → grilling → (prototype, only when needed) → writing-plans in order, then renders a visual summary of the finished plan file. Inside a repo the grill step uses grill-with-docs and halts if setup-matt-pocock-skills has not been run; outside a repo it uses grill-me. No state, no implementation. Use when the user runs /iso-plan, optionally with a seed idea as the argument.
---

# iso-plan

Take a raw idea and turn it into a written implementation plan by running four skills in order. The only output is the plan file. Nothing is implemented, nothing is committed, no state is tracked. When the plan is written, tell the user where it lives.

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
   git rev-parse --git-dir >/dev/null 2>&1 && echo repo || echo no-repo
   [ -f docs/agents/domain.md ] && echo setup-done || echo setup-missing
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

   No plan file is produced, so `iso-todo` stops cleanly on its own.

3. **prototype** (conditional) — the agent decides autonomously whether it's needed; **do not ask for approval**. Run `prototype` only when grilling left a question that can't be settled by talking (UI feel, viability of a state machine / data model). Otherwise skip it. Its learnings carry forward into writing.

4. **writing** — before invoking, snapshot the current newest plan so you can tell what's new:

   ```bash
   before=$(ls -t docs/superpowers/plans/*.md 2>/dev/null | head -1)
   ```

   Then invoke `superpowers:writing-plans` to turn the agreed design into a step-by-step plan file.

## Output

`superpowers:writing-plans` saves the plan under `docs/superpowers/plans/`. After it returns, find the newest file and confirm it is actually new:

```bash
after=$(ls -t docs/superpowers/plans/*.md 2>/dev/null | head -1)
```

If `after` is empty or equals `before`, `writing-plans` produced no new plan — say so and stop; do not render a card for a stale file. Otherwise `after` is the plan to summarize.

Read that file and extract, for the summary:

- **Title** — the first `#` heading.
- **Goal** — the text after `**Goal:**` (or the first paragraph if absent).
- **Phases / sections** — the `##` headings (skip boilerplate like "Goal", "Status").
- **Tasks** — count of checkbox lines (`- [ ]`). Group counts per phase if the plan is phased.
- **Files touched** — any file paths the plan names as created/modified, if listed.
- **Covers** — 3–6 dots naming what the plan actually delivers. Derive these from the phases and task titles you already read; do not re-read the plan. Write outcomes, not headings retyped — "auth tokens rotate on refresh", not "Phase 2: Auth". Skip pure-chore tasks (rename, tidy, bump). Fewer than 3 real outcomes → list what there is.

Then render a summary card (do not just print the path). Use a left-rule style — a header line with an underline rule, then indented sections. **No right-side border and no box frame** — never pad lines to a fixed width, since that aligns unreliably. Shape:

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

**Next** carries the real plan path, not a placeholder — the user should be able to copy the line as-is. It is a suggestion only: print it and stop. Never invoke `iso-write` yourself, and never offer to; iso-plan implements nothing. (When `iso-todo` drives this chain it reads the plan path itself and spawns its own implementation tab, so the line is inert there.)

Then halt.

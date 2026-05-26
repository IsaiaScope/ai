---
name: iso-plan
description: Planning-only chain. Runs brainstorming → grill-with-docs → (prototype, only when needed) → writing-plans in order, then renders a visual summary of the finished plan file. No state, no implementation. Use when the user runs /iso-plan, optionally with a seed idea as the argument.
---

# iso-plan

Take a raw idea and turn it into a written implementation plan by running four skills in order. The only output is the plan file. Nothing is implemented, nothing is committed, no state is tracked. When the plan is written, tell the user where it lives.

## Pipeline

```
brainstorming   → superpowers:brainstorming   (always)
grill-with-docs → grill-with-docs             (always)
prototype       → prototype                   (only when needed — agent's call)
writing         → superpowers:writing-plans   (always)
```

## Steps

Run each via the Skill tool, in order. The skills share this conversation's context, so the design carries forward automatically — there is no handoff artifact between steps.

If the user passed an argument, it is the seed idea — hand it to brainstorming. If not, brainstorming starts from the conversation so far.

1. **brainstorming** — invoke `superpowers:brainstorming`. Explore intent, requirements, and shape of the idea.

2. **grill-with-docs** — invoke `grill-with-docs`. Stress-test the design against the existing domain model (`CONTEXT.md` + ADRs), sharpen terminology, update docs inline.

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

Then render a summary card (do not just print the path). Use a left-rule style — a header line with an underline rule, then indented sections. **No right-side border and no box frame** — never pad lines to a fixed width, since that aligns unreliably. Shape:

```
  PLAN READY
  ────────────────────────────────────────
  <Title>

  Goal
    <one-line goal>

  Breakdown                        <N> tasks
    ├─ <Phase 1>     (<n>)
    ├─ <Phase 2>     (<n>)
    └─ <Phase 3>     (<n>)

  Files
    • <path/to/file>        (new)
    • <path/to/other>       (modified)

  📄  docs/superpowers/plans/<YYYY-MM-DD-...>.md
```

Keep it scannable — truncate long titles to one line. If a plan is flat (no phases), list tasks directly under **Breakdown** instead of the phase tree. Omit a section entirely (e.g. **Files**) if the plan doesn't specify it rather than printing it empty.

Then halt.

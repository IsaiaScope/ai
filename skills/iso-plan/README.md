# 🧭 iso-plan

> Turn a raw idea into a written implementation plan — runs four planning skills in order, then shows you a visual summary. **Plans only. Nothing is built, nothing is committed.**

---

## 🧩 What It Does

Chains four skills back-to-back in one conversation. Each step sharpens the idea; the last one writes it down. They share context, so the design carries forward automatically — no handoff files between steps.

```
1. brainstorming     →  explore intent, requirements, shape of the idea     (always)
2. grilling          →  stress-test the design                             (always, gated)
3. prototype         →  only if a question can't be settled by talking      (agent decides)
4. writing-plans     →  turn the agreed design into a step-by-step plan      (always)
```

Step 2 picks its grill skill from where you are:

| where | runs |
|---|---|
| outside a repo | `grill-me` |
| in a repo, `docs/agents/domain.md` present | `grill-with-docs` |
| in a repo, no `docs/agents/domain.md` | **halts** — run `/setup-matt-pocock-skills` first |

The halt is deliberate. Inside a repo the plan should be grilled against your actual domain model, and `grill-with-docs` can't find one until setup has recorded the doc layout. It won't quietly fall back to `grill-me` and let you plan against an invented glossary.

Step 3 is the only conditional one — the agent runs it on its own judgment (e.g. UI feel, or a risky data model worth a quick spike) and **never asks for approval**. Otherwise it's skipped.

---

## ▶️ Trigger

```
/iso-plan
/iso-plan <seed idea>
```

Or ask: *"plan this feature"*, *"let's design X before building"*

With an argument, that text is the seed handed to brainstorming. Without one, planning starts from the conversation so far.

---

## ✅ Output

One plan file under `docs/superpowers/plans/`, then a summary card:

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
    └─ <Phase 2>     (<n>)

  Files
    • <path>        (new)

  📄  docs/superpowers/plans/<YYYY-MM-DD-...>.md

  Next
    /iso-write docs/superpowers/plans/<YYYY-MM-DD-...>.md
```

**Covers** is 3–6 dots of what the plan delivers, phrased as outcomes rather than phase names. **Next** carries the real path — copy-pasteable. iso-plan never runs it for you; planning and building stay separate commands.

The card is only rendered if a **new** plan file actually appeared — a stale file never gets a card.

---

## 🔧 Dependencies

| Skill | Role | Source |
|-------|------|--------|
| `superpowers:brainstorming` | Step 1 — explore the idea | [obra/superpowers](https://github.com/obra/superpowers) |
| `grill-with-docs` | Step 2 — challenge against domain docs (in a repo) | [mattpocock/skills](https://github.com/mattpocock/skills) |
| `grill-me` | Step 2 — challenge without domain docs (outside a repo) | [mattpocock/skills](https://github.com/mattpocock/skills) |
| `setup-matt-pocock-skills` | Prerequisite for step 2 inside a repo | [mattpocock/skills](https://github.com/mattpocock/skills) |
| `prototype` | Step 3 — optional spike | [mattpocock/skills](https://github.com/mattpocock/skills) |
| `superpowers:writing-plans` | Step 4 — write the plan file | [obra/superpowers](https://github.com/obra/superpowers) |

---

## 🔗 Related

- [`iso‑write`](../iso-write/) — the next step: build the plan this skill produced, on a feature branch, with TDD.
- [`iso‑init‑repo`](../iso-init-repo/) — repo governance for the branches your plan lands on.

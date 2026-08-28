# Refine phases run as headless subprocesses, not agent tabs

> **Renamed.** The skill discussed here now ships as `iso-review`
> (`/iso-review`); it was `iso-refine` when this was written.

> **Superseded by [ADR 0006](0006-refine-phases-run-in-the-calling-session.md).**
> The phases now run in the calling session. The record below stands as the
> reason the tab machinery is not coming back — that finding outlived the
> decision it was made for.

`iso-refine` drives each of its three phases with `claude -p "<slash command>"
--permission-mode acceptEdits` and a wall clock, one process per phase. It
spawns no herdr tab, injects no keystrokes, and recovers no transcript. This
supersedes ADR 0001, and retires the premise of ADR 0002 for this skill.

A tab-driven design existed and worked. `iso-review` spawned reviewer tabs
through `iso-spawn`, navigated the codex `/review` preset menu with `send-text`
and arrow keys, polled agent status for a `working` transition to confirm the
command had actually started, recovered the transcript when it finished, parsed
it into findings, merged them across two reviewers, and handed the survivors to
a third tab that applied them. It is recorded here because someone who finds a
skill shelling out to `claude -p` will otherwise rebuild it.

Three findings ended it. Headless `claude -p` runs slash commands, inherits the
user's installed skills, and writes files to disk under `acceptEdits` — verified
by running it, not inferred. Two of the three phases have no codex equivalent,
so the reviewer-adapter seam had one implementation. And `/review --fix` applies
its own findings, so the parse-merge-handoff machinery had nothing left to hand
off.

## Considered Options

- **Headless subprocess per phase** (chosen) — deletes the keystroke injection,
  the preset-menu navigation, the start-transition gate, the transcript
  recovery and the findings parser in one move. Each phase gets its own revert
  boundary, its own diff scope and its own clock, all of which are per-process
  properties. Cost: three cold starts, each re-reading the diff, and no visible
  tab to watch work happen.
- **Keep tabs, drop to one agent** (rejected) — would have kept visibility and
  removed only the codex-specific menu navigation. But the remaining tab
  machinery — spawn, readiness poll, status transition, recovery, teardown —
  exists to talk to a TUI, and there is no longer a reason to talk to a TUI.
- **One subprocess, all three phases chained in one prompt** (rejected) —
  cheaper in tokens and cold starts. Forfeits the per-phase revert on a red
  suite, the per-phase scope split, and the per-phase timeout, none of which can
  be expressed inside a single process.

## Consequences

Visibility is gone: a phase runs to completion or its timeout with nothing to
watch. The unstaged diff is the only progress signal, and it only arrives at the
end.

`iso-spawn` keeps its verbs and its lifecycle libraries but loses its last
in-repo consumer, so it is now a skill you invoke rather than a layer other
skills build on. ADR 0002's statement that lifecycle robustness lives in
`iso-spawn` rather than in each skill remains true of `iso-spawn`; it simply no
longer describes how any other skill works.

The architecture phase's non-interactivity now rests on prompt text rather than
on a human being present to answer it. `improve-codebase-architecture` ends its
report step by asking which candidate to explore; under a headless run that
question has no reader, so a phase that ignores the override hangs until its
timeout rather than blocking visibly in a tab.

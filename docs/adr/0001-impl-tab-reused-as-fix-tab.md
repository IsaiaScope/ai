# Implementation tab is reused as the review fix tab in iso-todo

In an `iso-todo` development cycle the codex implementation tab finishes `iso-write`, stays alive, and is reused to apply accepted review fixes. `iso-review` still remains runnable standalone: by default it spawns its own fix tab, but callers can pass an existing implementation `TERM` to apply fixes in that tab. `iso-todo` also kills the short-lived reviewer tabs after their findings are saved, keeping the visible tab set small.

## Considered Options

- **Reuse the impl tab as the fix tab** (chosen) — the implementer already knows why it built the feature, saves one spawned tab, and keeps the full write→fix history in one place. Risk: long `iso-write` runs can leave a large context, so the fix prompt must stay tightly scoped to accepted findings.
- **Fresh fix tab, impl tab kept alive** (rejected) — cleaner context for fixes and simple black-box review, but leaves more tabs around and loses the implementer's local context for follow-up edits.

## Consequences

A full cycle leaves the implementation/fix tab alive and kills the reviewer tabs once their transcripts are persisted. Standalone `iso-review` keeps its default fresh-fix-tab behavior unless a caller provides `--fix-term <TERM>`.

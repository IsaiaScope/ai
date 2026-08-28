# iso-refine design

Replaces `iso-review` with a three-phase pipeline that improves the branch's
changes, then checks them, unattended, leaving everything readable as `git diff`.

**Goal:** one command that shapes, simplifies and reviews the work on a branch
without asking a question, without committing, and without a herdr tab.

**Supersedes:** `skills/iso-review` (deleted), `skills/iso-todo` (deleted),
ADR 0001, ADR 0002.

---

## Why this exists

`iso-review` drove two agents through herdr tabs by injecting keystrokes,
recovering transcripts, parsing them into findings, merging and de-duplicating
across reviewers, then handing an accepted-fixes ledger to a third tab that
applied them. Roughly 1000 lines, of which the fragile third was TUI menu
navigation.

Three facts collapsed that design:

1. `claude -p "/review HEAD" --permission-mode acceptEdits` works. Slash
   commands run in headless mode, the session inherits `~/.claude` skills, and
   edits land on disk. Verified by running it, not read in docs.
2. Two of the three phases exist only for Claude. `improve-codebase-architecture`
   is not installed for codex; `/simplify` and `/review` are Claude Code
   built-ins. One agent kind means the reviewer adapter seam has one
   implementation, which is not a seam.
3. `/review --fix` applies its own findings. The parse-merge-dedupe-handoff
   machinery existed to move findings between agents. With one agent applying
   its own output, there is nothing to hand off.

## Pipeline

Three phases, fixed order, each on by default.

| # | phase | command |
|---|---|---|
| 1 | architecture | `/improve-codebase-architecture <override>` |
| 2 | simplify | `/simplify` |
| 3 | review | `/review medium --fix` |

Each phase is a separate `claude -p` process with `--permission-mode
acceptEdits` and a wall-clock `timeout`. Three processes, not one: a revert
boundary and a clock are both per-process properties.

**Every phase sees the working tree as the phase before it left it.** No phase
is given a narrower scope, and that is a limitation rather than a choice: a
phase's edits are unstaged working-tree changes, and no ref range excludes them.
Hiding them between phases would mean stashing mid-run, which costs the property
the whole design rests on — that the index is a clean snapshot of the state
before the run.

What the ordering buys is the half that matters. Review is last, so it sees
everything the other two changed; that is the reason it exists in this pipeline
at all. What it costs is that simplify reads the architecture phase's fresh
output as if it were hand-written code, and may polish a refactor nobody has
looked at yet.

`--max-turns` is not used. It errors mid-turn, which stops a phase with files
half-written — indistinguishable from a phase error but leaving a partial tree.
A wall clock kills cleanly and the unstaged diff shows how far it got.

### The architecture phase's non-interactivity

`improve-codebase-architecture` ends its step 2 with *"ask the user: Which of
these would you like to explore?"* and its step 3 is a dialogue. There is no
flag. The phase is forced non-interactive by prompt text that suppresses the
HTML report and the grilling loop.

This is the softest joint in the design and is recorded as such: the guarantee
is prose the skill is free to ignore, not a contract. A phase that stops to ask
a question hangs until its timeout.

## Preflight

Ordered, all pure shell, all testable without spending a token.

1. **Snapshot the index.** `git write-tree` records the pre-existing index tree.
   Printed in the summary; recovery is `git read-tree <sha>`. Without this,
   `git add -A` destroys a deliberate partial stage unrecoverably.
2. **Stage everything.** `git add -A`. The index becomes the "before" snapshot.
3. **Resolve the base.** `git merge-base <integration> HEAD`, where
   `<integration>` comes from `iso-config` (`dev`, then `develop`), never
   hardcoded.
4. **Staleness.** Fetch, compute `behind`.
   - `behind = 0` — proceed.
   - `behind > 0`, branch is local — rebase through the seam, then continue in
     the same run.
   - `behind > 0`, branch is on origin — stop, report how to proceed.
   - rebase conflict — leave the rebase in progress, exit 2. Aborting would
     discard commits that already applied cleanly.
5. **Refuse an empty branch.** Nothing between the base and HEAD means nothing
   to refine.

"Local" is tested as no configured upstream. **Known weakness:** `git push
origin <branch>` without `-u` writes no upstream, so a genuinely published
branch reads as local and would be rewritten. `git ls-remote --exit-code origin
<branch>` is the correct test. Deferred to `iso-rebase`.

The rebase is reached through a seam. Day one it calls `push.sh rebase`, which
already runs unattended and has the right conflict behaviour. When `iso-rebase`
exists, the seam points at it and nothing else changes.

## Output

Nothing the skill produces is staged. After each phase, `git add -N` marks new
files intent-to-add so they render in `git diff` as additions with content
unstaged — without it, a file the architecture phase creates is untracked and
invisible to the diff.

- `git diff --cached` — your work, as it was before the skill ran
- `git diff` — everything the skill did, all three phases

### Summary

Goes to the terminal, and to a ticket comment when one is open for the branch.
Nothing is written to disk.

Contents:
- per-phase file lists, derived from git by diffing between phase snapshots
- per-phase outcome: pass, reverted, or skipped
- test-command result, or a statement that no gate ran
- the `git write-tree` sha from preflight
- each phase's closing prose, truncated to a fixed per-phase cap

The prose is included because a diff cannot say *why* the architecture phase
moved a function, and that sentence is the value of running it. The cap exists
because this text crosses into a ticket comment through `redact`.

The ticket comment needs a new `comment <key>` verb in `tracking.sh` reading the
body from stdin, behind `redact`. `iso-refine` reaches it through `iso_track`,
never by resolving `tracking.sh` by hand.

## Failure

| case | behaviour |
|---|---|
| phase errors | abort, name the phase, leave the tree as it is |
| phase finds nothing | not a failure — continue |
| phase's edits break the suite | `git checkout -- .` restores that phase from the index, continue |

The revert is free because of the staging rule: the index already holds the
pre-phase state, so no stash bookkeeping is needed.

### The phase gate

The suite comes from a new `test.command` key in `iso-config`. **Absent means no
gate**, stated plainly in the summary rather than silently skipped.

This repo is that case today: no `package.json`, no `Makefile`, no pytest
config. `AGENTS.md` says tests are two hand-run globs. A gate that probes for
npm/make/pytest would be vacuous in the repo it lives in, which is why the
command is configuration rather than detection.

### Exit codes

| code | meaning |
|---|---|
| 0 | completed — including a run that found nothing |
| 1 | preflight refusal, or a phase errored |
| 2 | rebase conflict, left in progress |

Zero findings exiting 0 fixes a live bug: `rv_run` returns 3 today and
`todo.sh` dies on it under `set -e`, contradicting `iso-todo/SKILL.md:115`,
which documents that case as a normal close.

## Surface

```
/iso-refine [--no-architecture] [--no-simplify] [--no-review]
```

All three phases on by default; each flag turns one off independently. No list
parsing, and each flag reads as what it does.

Script verbs, dispatched from `scripts/refine.sh`:

| verb | does |
|---|---|
| `preflight` | index snapshot, staging, base resolution, staleness, refusals |
| `scope` | prints the base and the file list it would act on — no agent, no tokens |
| `run` | preflight, then the phases in order |

`scope` exists so the diff-range decision is assertable without invoking an
agent, and `preflight` so the git manipulation is assertable at all.

## No session dependency

`iso-refine` runs from a bare shell. No `HERDR_PANE_ID`, no tab, no pane. You
will normally launch it by typing `/iso-refine`, but nothing in it requires a
session — which is what makes `preflight` and `scope` testable from a shell
script.

## What is deleted

- `skills/iso-review/` — `git rm -r`. `skills/iso-refine/` is written fresh; not
  a `git mv`, because the two share nothing but a purpose and a rename would
  report a ~90% rewrite as an edit history that did not happen.
- `skills/iso-todo/` — entirely. Nothing replaces it; the plan/write/review
  chain is three commands you type. Lost with it: automatic implementation-agent
  classification.
- All herdr coupling: `reviewer_dispatch`, `rv_spawn`, `rv_wait_ready`,
  `rv_kill_term`, `rv_demote_scrollback`, the `HERDR_PANE_ID` preflight, the
  `working`-transition start gate.
- `--agent`, `--fix-term`, `--kill-review-tabs`, `--kill-fix-tab`,
  `--kill-tabs`, `--claude-review-effort`.
- The findings parser, the merge/dedupe pass, `accepted-fixes.md`, the
  `__DISPATCH_FAILED__` / `__RECOVER_FAILED__` sentinel vocabulary.

`iso-spawn` stays as a standalone skill. It stops being a library — nothing in
the repo calls it after this.

## Callers to update

| file | change |
|---|---|
| `plugins/isaiascope-eng/.claude-plugin/plugin.json` | `iso-review` and `iso-todo` out, `iso-refine` in (regenerated by `install.js`) |
| `AGENTS.md` | tree lines for both deleted skills, one line for `iso-refine` |
| `CONTEXT.md` | glossary — see below |
| `README.md` | references to both deleted skills |
| `skills/iso-plan/SKILL.md` | `iso-todo` references |
| `skills/iso-issue-tracking/SKILL.md` | `iso-todo` references |
| `docs/adr/0001`, `docs/adr/0002` | marked superseded |
| `docs/adr/0004` | mentions `iso-todo` in passing |

Historical specs and plans under `docs/superpowers/` are left as written.

## Glossary changes

Delete — nothing defines them any more:
- **Reviewer adapter** — one adapter is not a seam
- **Reviewer** — folded into *refine phase*
- **Accepted fix** and **Dropped finding** — there is no merge and no filter;
  `/review --fix` applies its own findings
- **Fix tab**, **Implementation tab** — no tabs
- **Development cycle** — that was `iso-todo`

Rename and redefine:
- **Review scope** to **Refine scope** — now the branch's changes against the
  merge-base, not the uncommitted working tree
- **Review run** to **Refine run**

Add:
- **Refine phase** — one of exactly three, in fixed order
- **Phase gate** — the `test.command` check deciding whether a phase's edits
  survive

Also deleted: **Phase**. It was defined as "one stage of a development cycle:
plan, write or review", and with the development cycle gone a bare *phase* is a
fuzzy leftover next to *refine phase*. One term, not two.

Redefined: **Finding** — was a reviewer's report of a location, problem and
proposed fix, collected into a ledger. Under `/review --fix` a finding is
applied, so it is read in the diff and never collected.

Kept: **Agent kind** — still `iso-spawn`'s term, and `iso-spawn` still spawns
both codex and claude. **Spawn** and its lifecycle terms, **Tab**, **Skill**,
and the config and init terms are untouched. **Run artifact** keeps its
definition but loses review transcripts from its examples.

## Deferred

`iso-rebase` — a skill owning rebase and merge conflict handling, attachable to
every `iso-*` skill that touches a branch. Its own design session. `iso-refine`
ships with the seam and the `push.sh rebase` fallback, so it does not block on
that skill existing.

## Open risk, accepted

With no ticket open and the terminal closed, the `git write-tree` sha survives
only as a dangling object in `.git/objects`, recoverable via `git fsck
--lost-found` until the next `gc`. Accepted deliberately: nothing is written to
disk.

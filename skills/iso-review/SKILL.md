# iso-review

Take the work sitting on this branch and make it better, then check it. Three
phases, in one order:

| # | phase | what it asks | runs |
|---|---|---|---|
| 1 | architecture | is this the right shape? | here, in this session |
| 2 | simplify | can this read plainer? | here, in this session |
| 3 | review | is this wrong? | a subagent |

Invocation: `/iso-review [--no-architecture] [--no-simplify] [--no-review]`.
All three run by default.

Mechanics live in `skills/iso-review/scripts/review.sh`. Run it by absolute
path. It gives you six verbs and no orchestration — the order below is the
orchestration.

| verb | does |
|---|---|
| `preflight` | stage, resolve the base, deal with staleness. Prints `index=` and `base=` |
| `scope [base]` | print what a run would act on, without acting and without spending a token. Without `base` it re-runs preflight, so it stages, and prints `index=` too |
| `skill-check <name>...` | is each phase's skill invocable by a model? Non-zero if any is blocked |
| `snapshot` | print a tree sha for the current working tree. One phase's undo point |
| `gate <name> [snap]` | run the repo's tests; on red, undo back to `<snap>`. Prints one `phase=` line. `<snap>` is also what `files=` is measured from |
| `report` | summary on stdin: echo it, and post it as one ticket comment |

## The run

**Preflight.** `review.sh preflight`. Non-zero: print its message and stop.
Read the `index=`, `base=` and `note=` lines and leave them in the terminal.
They do not go in the report — see below.

**Skill gate.** `review.sh skill-check improve-codebase-architecture simplify review`.

A phase **is** its skill, so this asks whether each one can actually be
invoked by a model. It reports one line per name:

| state | means | do |
|---|---|---|
| `ok` | one copy on disk, invocable | carry on |
| `ok copies=N` | several copies, all invocable | carry on; N>1 is worth a glance, since you cannot tell which one answers |
| `builtin` | no file on disk | carry on — the harness ships skills with no `SKILL.md`. **Also how a mistyped phase name looks**, so read it |
| `blocked` | every copy carries `disable-model-invocation: true` | stop and fix, below |
| `split` | copies **disagree** — some blocked, some not | stop. Which one answers decides whether the phase runs at all, and nothing here can predict the resolution order |

`blocked` and `split` exit non-zero. So does finding *no* file for any name when
several were asked for — that is a broken search, not five clean passes.

**Stop there.** Do not work around it by following the skill from memory: that
produces a phase which reports a result without having run the thing it names,
and it is not a hypothetical — this skill once reported three green phases, not
one of which invoked a skill. The `phase=` line looked identical either way,
which is exactly why the gate is mechanical and not a reminder.

The fix is one line. Remove `disable-model-invocation: true` from the file the
check names — for `split`, that is the one listed after `blocked=` — keep a
`.bak` beside it, re-run the check, then carry on. That edits a file outside the
repository, so say plainly what you changed and where.

Two things about the `.bak`. It still carries the flag, which is the point, and
it sits in the directory the check searches — so it must not be named to match
`<name>.md`. And a plugin **cache** is not permanent: `/plugin update` or a
version bump restores the original, flag included. The check is what notices.

What the check reads is the filesystem: `<name>/SKILL.md` and `<name>.md`,
across the skills dir and the plugin cache. That is a guess about where the
harness keeps things, which is why "found nothing anywhere" is an error rather
than a pass.

**Scope.** `review.sh scope <base>`, using the base preflight just printed.
That file list is what every phase works against, and it does not move for the
rest of the run. Read it once.

**Each phase, in the table's order**, skipping any the user turned off:

1. `snap=$(review.sh snapshot)` — before touching anything.
2. Do the phase's work **across the whole scope** — every file the list names,
   not the hot spots and not the files you happen to have context on. A scope
   too large for one pass gets worked in batches until all of them are done; it
   does not get sampled.
3. `review.sh gate <name> "$snap"` — keep the `phase=` line it prints.

`snap` is optional, and omitting it changes what a red gate does: with a
snapshot the phase is restored to that tree, without one the revert falls back
to `git checkout -- :/`, which undoes *every* unstaged change in the tree — the
earlier phases' output included. Pass it.

"Do the phase's work" means **invoke that phase's skill with the Skill tool** —
`improve-codebase-architecture`, then `simplify`, then `review`. Not read them,
not approximate them, not do what you remember them doing. The skill is the
phase; anything else is your own judgement wearing the phase's name.

Architecture and simplify run **here, in this session**: you have the branch's
context already, and a fresh reader would spend its first minutes re-deriving
what you know.

Review runs in a **subagent**, which wants the opposite — the session that just
wrote the code is the worst possible reader of it, and the whole value of a
review phase is eyes with no stake in the choices being reviewed. Pass it the
scope and let it invoke `review` itself.

**Report.** Write the summary, then pipe it to `review.sh report`. What belongs
in it is what each phase *found* — the change, in a sentence someone who was not
here can act on. The `phase=` lines say a phase ran and how much it touched;
they never say what it did, and a summary carrying only them is a receipt.

`report` refuses one. A summary whose every line matches `index=`, `base=`,
`note=` or `phase=` is echoed to the terminal — the phases have already spent
their tokens and the text is not thrown away — and then rejected before it
reaches the ticket. The rule was prose here first, and runs posted the receipt
anyway.

A phase that fails outright **stops the ones after it** — a phase hands its
tree to the next one, and a broken tree turns one failure into three. A phase
whose *gate* went red is not a failure: it ran, its edits were undone, and the
run continues.

## The staging contract

This is the part to understand before reading a diff this skill produced.

Preflight runs `git add -A` **before the first phase**. From then on:

| | holds |
|---|---|
| `git diff --cached` | your work, exactly as it was when you invoked the skill |
| `git diff` | everything the three phases changed |

So reviewing the skill's output is `git diff`, and throwing it away is
`git checkout -- :/`. No stash, no snapshot file, nothing to leak if the run
dies halfway.

Preflight prints `index=<sha>` first, before it stages anything. That sha is a
real tree object, and it is there for one case: you had a *deliberate* partial
stage, and `git add -A` flattened it. `git read-tree <sha>` puts it back. After
the run nothing else can tell "was staged" from "just got staged".

The skill's own output is never staged. That is the point.

## The phase gate

`gate` runs `iso_config_get test.command` — the shell command that proves this
repository still works. Set it in `docs/iso/config.json`:

```json
{ "test": { "command": "npm test" } }
```

A phase whose edits turn that command red is **undone**: the working tree goes
back to how that phase found it, and the files it created are removed.

Undone means *that phase*, not the run — which is why every phase takes its own
`snapshot` first. The index cannot serve as the undo point: it is the pre-*run*
snapshot, so reverting to it would throw away every phase that already passed.
(`snapshot` needs `git restore --worktree`, so git 2.23 or newer.)

`gate` exits 0 on both outcomes. Read the `phase=` line, not the status.

With `test.command` unset there is no gate. Phases still run, nothing checks
them, and each phase's line reads `result=unchecked` rather than claiming a
pass it did not earn. That is a real mode, not a broken one.

## Scope

The scope is **the staged diff against the base** — every file this branch
changed, listed by `review.sh scope <base>`. Every phase covers all of it.

The list is fixed for the whole run, and the staging contract is what fixes it:
preflight is the last thing that ever stages, so the phases churn the worktree
while `git diff --cached <base>` goes on answering with the branch's own work.

Pass the base. Without it, `scope` re-runs preflight — and preflight's
`git add -A` would swallow the earlier phases' output into the index, staging
exactly what this skill promises to leave unstaged for you.

Two things the list does not cover, both by construction:

- A phase sees the **worktree** as the phase before it left it. The scope names
  the same files throughout, but their contents move, so simplify reads the
  architecture phase's fresh output as if it were hand-written code.
- A file a phase **creates** is not in the list, because the list is the staged
  diff and nothing new is ever staged. Later phases still see it on disk; it
  just is not named.

`files=N` on a phase line counts the files that phase **changed** — measured
against that phase's own `snapshot`, so it is the phase's footprint and not the
run's. (Called without a snapshot, `gate` has nothing to measure from and falls
back to the whole run.) Anything a concurrent session writes to this checkout
during the phase lands in the count too; there is no way to tell the two apart
from inside the phase.

It is not a coverage number. A small `files=` against a large scope means the
phase sampled rather than covered, and that is the failure this section exists
to prevent.

## Staleness

If the branch is behind the development branch, the base every phase measures
against is wrong, so preflight deals with it first:

| branch | what happens |
|---|---|
| local (no upstream) | rebased automatically, then the run continues |
| published (has an upstream) | **refused** — rebase it yourself and re-run |

A rebase conflict exits **2** and leaves the rebase in progress, so
`git rebase --continue` or `--abort` are both still available.

The rebase itself is delegated, today to `iso-push`. When `iso-rebase` exists <!-- skill-refs-ok: names a skill that does not exist yet, on purpose -->
this points at it and nothing else here changes. Two known weaknesses live at
that seam and are documented in the script: a branch pushed without `-u` reads
as local, and `iso-push` rebases onto `origin/<base>` while the staleness check
measures against the local one.

## Reading the result

One heading per phase, in the run's order, and under it one dot per change worth
naming. The `phase=` lines go at the bottom, where they belong: they are the
record that the run happened, not the report of what it did.

The two sha lines do **not** go in it. `preflight` already printed them to the
terminal, and `index=` is a recovery aid with a short shelf life — it exists so
you can `git read-tree` a partial stage within minutes of the run. On a ticket
a month later it is an unresolvable hex string whose tree object may be gone.

```
## architecture — verified, 3 files

- folded the two config readers into `iso_config_get`, so a caller no longer
  has to know which file holds which key

## simplify — reverted

- the gate went red and the edits were undone; nothing from this phase survives

## review — unchecked, 1 file

- `push.sh:412` reads `$?` after a pipeline, so it tests grep's status and
  never the command's

phase=architecture result=verified files=3 (ran; the test command was still green after it)
phase=simplify result=reverted files=0 (the test command went red; this phase edits were undone)
phase=review result=unchecked files=1 (ran; no test.command set, so nothing verified it)
```

Three result words, and they are not interchangeable:

| `result=` | what happened |
|---|---|
| `verified` | the phase ran and `test.command` was green afterwards |
| `unchecked` | the phase ran and **nothing checked it** — no `test.command` is set |
| `reverted` | `test.command` went red, so this phase's edits were undone |

`unchecked` is the one to read carefully. It is not a pass; it means the phase's
output has had no verification of any kind, and the only thing standing behind
it is the agent that wrote it.

Every dot names something concrete that exists in the diff: a file, a function,
a flag, a behaviour. A dot that cannot name one is padding and gets deleted
rather than reworded — that is the rule `/iso-commit` uses on a commit body, and
it catches the same slop here. A phase that changed nothing says so in one dot,
which is a finding too.

In the terminal, `preflight` opens with the two shas and a `note=` line for
each. They exist because those shas are the only output a reader cannot decode,
and they are separate lines rather than a suffix because the sha lines are
parsed by machine, anchored to end-of-line.

The same summary is posted as one comment on this branch's ticket, when there
is one, capped at `ISO_REVIEW_REPORT_CAP` characters (4000 by default, matching
the tracker's own limit). No ticket means the terminal is the whole report.

## Never commits

Like the rest of the chain. The run ends with a working tree for you to read.
`/iso-commit` is the only thing that commits, and only when you ask it to.

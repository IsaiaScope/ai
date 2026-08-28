# Refine phases run in the calling session, not as headless subprocesses

> **Renamed.** The skill discussed here now ships as `iso-review`
> (`/iso-review`); it was `iso-refine` when this was written.

`iso-refine` no longer shells out. Its architecture and simplify phases run in
the session that invoked the skill; review runs as a subagent. `refine.sh` lost
`cmd_run`, and `lib/phase.sh` — the headless invocation, the wall clock, the
process-group kill — is deleted. This supersedes ADR 0005.

ADR 0005 chose `claude -p` per phase for three per-process properties: a revert
boundary, a diff scope, and a timeout. Only the first turned out to be
load-bearing, and it was never actually a process property — it is a tree
object — the `snapshot` verb — which works identically whoever is doing the
editing. The diff scope was documented as a non-feature at the time, on the
grounds that every phase sees the whole working tree because a phase's edits are
unstaged and nothing excludes them. And the timeout only guards a run nobody is
watching.

Three things pushed it over. A headless phase starts cold, so a three-phase run
reads the same tree three times and pays for it three times, against a
subscription window shared with the interactive session that is waiting on it.
`SessionStart` hooks fire for `claude -p`, so every phase inherited this user's
instruction sets — including one whose standing order is to delete rather than
add, directly opposed to the architecture phase's purpose. `--bare` would strip
the hooks but also the skills, and two of the three phases *are* slash commands.
And ADR 0005's own consequence — that non-interactivity rested on prompt text
with nobody to answer a question — stops being a risk when there is a person
in the loop by construction.

## Considered Options

- **Phases in the calling session, review in a subagent** (chosen) — deletes
  the subprocess layer, the timeout and its perl fallback, and the stub seam
  that existed only to test orchestration. The two phases that benefit from the
  branch's context get it for free. Review, which benefits from *not* having
  it, is the one that stays isolated. Cost: no `--no-*` flag parsing in the
  script, so the phase list is prose rather than a `case`.
- **All three in-session** (rejected) — one less moving part, and wrong on the
  phase that matters most. A reviewer that just wrote the code will rationalise
  its own choices; that is the entire reason a review phase exists.
- **Keep headless, disable the inherited hooks** (rejected) —
  `CAVEMAN_DEFAULT_MODE=off PONYTAIL_DEFAULT_MODE=off` is a real fix for the
  contradiction, but it treats one symptom of cold starts and leaves the
  triple-read, the invisible progress and the wall clock untouched.

## Consequences

Progress is visible again, which ADR 0005 listed as its main cost. The phases
edit in the open, and the gate line lands after each one rather than all three
at the end.

The orchestration moved from `refine.sh` into `SKILL.md`, so it is prose and
cannot be unit-tested. `refine.test.sh` lost its phase-ordering and `--no-*`
assertions and gained assertions on the three primitives instead; the run order
is now guarded by review, not by a test.

`gate` had to become order-independent. Under the loop, "untracked means
created by this phase" held because every phase passed through one function
whose `add -N` made the previous phase's files tracked. As a verb a human can
call in any order, that invariant would have been a standing obligation on the
prose — so `gate` now asks the snapshot (`git cat-file -e "$snap:$f"`) instead
of trusting the caller.

`ISO_REFINE_TIMEOUT` and `ISO_REFINE_PHASE_CAP` are gone.
`ISO_REVIEW_REPORT_CAP` (`ISO_REFINE_REPORT_CAP` as first written) replaces the latter, applied once to the whole summary.

## Amended after the first real run

Two things this record got wrong, both found by running it rather than reading
it.

**The diff scope is not a non-feature.** The paragraph above inherits ADR 0005's
claim that nothing can exclude a phase's own edits. `scope <base>` does exactly
that: it reads `git diff --cached <base>`, and since preflight is the last thing
in a run that ever stages, the index still answers with the branch's own work no
matter how much the phases have churned the working tree. What the phases share
is the *working tree*, not the scope. Passing the base is therefore mandatory —
omitting it re-runs preflight, whose `git add -A` folds the earlier phases'
output into the index and destroys the property.

**In-session phases depend on their skills being model-invocable.** A phase *is*
its skill, and a skill carrying `disable-model-invocation: true` in its
frontmatter refuses a model caller outright — only a human typing `/name` can
start it. `improve-codebase-architecture` shipped with that flag set. Nothing
failed loudly: the phase reported a result having invoked nothing, because the
`phase=` line is written by the gate and looks identical either way. Headless
`claude -p` never had this problem, because a slash command reaches a subprocess
as a *user* prompt, so ADR 0005's design was immune to a constraint this one is
exposed to. The mitigation is the `skill-check` verb, run before the first phase
and failing the run rather than warning about it.

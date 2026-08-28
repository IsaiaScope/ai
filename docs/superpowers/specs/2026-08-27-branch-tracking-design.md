# Branch tracking across iso-* skills — design

**Date:** 2026-08-27
**Status:** brainstormed

## Goal

A ticket's `Branch` property must name the branch the work is **implemented** on, not the branch its plan happened to be written on. Today it names the latter, because it is written once at `open`/`replan` time — usually while standing on `dev` — and nothing ever rewrites it.

The visible symptom is a stale field on the board. The real damage is one level down: the local ledger row carries the same branch string, that string is the **lookup key** `ticket_for_branch` resolves by, and a stale key makes the ticket unfindable from the branch the work actually lives on. That is the `iso-push: no ticket for this branch -- the PR stays unlinked` line.

### Three symptoms, one cause

The stale branch surfaces in three places, all downstream of the same ledger field:

1. **Board.** The ticket's `Branch` property names the plan-time branch.
2. **Ticket lookup.** `ticket_for_branch` misses, so `/iso-push` prints `no ticket for this branch -- the PR stays unlinked` and `body_with_ticket` (`push.sh:456-461`) appends nothing, so the tracker's PR auto-link never fires.
3. **PR property.** `reconcile` matches pull requests with `select(.headRefName==$b)` where `$b` is the ledger's branch (`tracking.sh:525, 534-541`). No PR has `headRefName: dev`, so `pr_url` stays empty and the click-through `PR` property is never written.

Symptoms 2 and 3 are already-implemented features that have simply never been reachable. Correcting the ledger restores both with no new code.

Alongside the fix, this design consolidates three divergent answers to "am I standing on a branch I should be working on?" into one shared gate that every `iso-*` skill calls.

## Problem, precisely

`Branch` is written in exactly one place — `do_bind` (`skills/iso-issue-tracking/scripts/tracking.sh:249-251`):

```bash
br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
…
ensure_property Branch text && tk_issue_property "$key" Branch "$br"
```

`do_bind` has three callers, all at plan time: `open` (line 491), `replan` (line 422), `bind` (line 337). `/iso-write` calls only `track <state> <plan>` (`write.sh:108-116`), which moves status and touches no property. `/iso-push` writes a `PR` property (`tracking.sh:539`) and never `Branch`. So the value is fixed at the moment the ticket is opened and is never revisited.

The same `do_bind` call writes the ledger row (`tracking.sh:244`):

```bash
ledger_put "$key" "$(jq -nc … '{repo:$r,branch:$b,project:$p,opened_by:$o,plan:$pl}')"
```

`ticket_for_branch` (line 301-309) resolves via `ticket_for_plan "$br"`, whose jq matches either the plan basename or `.value.branch` exactly (line 108-114). Once `/iso-write` cuts `feat/<slug>`, neither arm matches the current branch, and the lookup misses.

### Current branch logic, per skill

| skill | where | behaviour |
|---|---|---|
| `iso-write` | `write.sh:33-40`, `88-99` | `is_base_branch` over `branches.protected`. On base or detached: derive `<type>/<slug>` from the plan filename, cut it, **`die` if it already exists**. On a feature branch: stay (`mode=current-branch`). |
| `iso-commit` | `commit.sh:15-33` | No branch policy. Checks repo, rejects detached HEAD, checks there is something to commit. Commits onto `dev` without comment. |
| `iso-push` | `push.sh:34-38`, `161-180` | `is_protected` over the same key. Refuses `test`/`prod` outright. For a protected branch carrying commits, `rescue_to_branch` names a branch from the last commit subject, `git branch`, `git reset --hard origin/<base>`, checkout — unasked, refusing only a dirty tree. |

`is_base_branch` and `is_protected` are the same loop over `branches.protected`, differing only in name and write's extra `[ -z "$1" ] && return 0` (detached counts as base).

## Decisions (locked in brainstorming)

| Question | Decision |
|---|---|
| Gate posture | **Config-driven, not conversational.** The gate decides from `branches.protected` plus git state, and prompts only in the one case config cannot answer. `/iso-write` stays as silent as it is today. |
| Rebind scope | **Unconditional and shared.** Every skill that lands on a branch reports it to tracking, whether or not the gate did anything. |
| `rescue_to_branch` | **Kept.** It exists for work that arrives without ceremony — a plain `git commit`, another agent, a merge — and `/iso-commit` gating does not stop those. Stranded commits on `dev` are invisible to the cascade, a worse failure than a rare `reset --hard`. |
| Standing on a base branch, ticket names a feature branch | **Ticket wins** — offer to check it out. Standing on `dev` means no branch opinion has been formed yet, so resuming is the likely intent. |
| Standing on a feature branch, ticket names a different one | **Working tree wins** — stay. The rebind follows only when the caller holds a plan path, which identifies the ticket independently of the branch. `/iso-commit` on an unrelated feature branch resolves no ticket and correctly does nothing: a hotfix branch is not the plan's branch. |
| Branch-move history | **None on the ticket.** The property is overwritten; nothing is posted as a comment. A branch move is bookkeeping, and a comment per move buries the retro. The tracker's `log` file keeps the trail. |
| Detached HEAD | **Counts as a base branch**, matching `is_base_branch` today. A detached HEAD is exactly a place work should not live. |

## Component 1 — the shared gate

New file `skills/iso-config/scripts/lib/branch.sh`, sourced through `iso_sibling` exactly as `config.sh` is. It becomes the **only** reader of `branches.protected`; the two local copies in `write.sh` and `push.sh` are deleted.

It exports the membership test, two naming helpers, and the gate.

**The gate is pure.** It never calls the tracker. `iso-issue-tracking` sources
`iso-config` (`tracking.sh:11-13`), so a call back the other way would be a
dependency cycle. The caller resolves the ticket with whatever identifier it
already holds and passes the answer in:

```
iso_is_protected        <branch>                 # empty (detached) counts as protected
iso_branch_from_plan    <plan-path>              # YYYY-MM-DD-<type>-<slug>.md -> <type>/<slug>
iso_branch_from_subject <commit-subject>         # "feat(scope): msg"          -> feat/scope-msg
iso_branch_gate         <current> <ticket-branch> <proposed>
```

`iso_branch_from_plan` is `write.sh`'s `cmd_branch_for` moved verbatim.
`iso_branch_from_subject` is the pure half of `push.sh`'s `branch_name_from`
(lines 119-140); push keeps the git-log read that feeds it, since reading
`origin/<base>..HEAD` is push-specific.

The gate decides nothing interactively — a script cannot ask a question — so it
prints a verdict and the calling `SKILL.md` renders any prompt:

```
action=stay|create|checkout|ask
branch=<name>      # target for create/checkout; the current branch for stay; empty for ask
```

Its whole logic:

```bash
iso_branch_gate() {
  local cur="$1" tb="${2:-}" proposed="${3:-}" candidate=""
  iso_is_protected "$cur" || { printf 'action=stay\nbranch=%s\n' "$cur"; return 0; }
  # The ticket's own branch beats a freshly derived name: resuming beats cutting
  # a near-duplicate. A ticket still naming a protected branch is the staleness
  # this design fixes -- never follow it back onto dev.
  if [ -n "$tb" ] && [ "$tb" != "$cur" ] && ! iso_is_protected "$tb"; then
    candidate="$tb"
  else
    candidate="$proposed"
  fi
  [ -n "$candidate" ] || { printf 'action=ask\nbranch=\n'; return 0; }
  if git rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null 2>&1
  then printf 'action=checkout\nbranch=%s\n' "$candidate"
  else printf 'action=create\nbranch=%s\n'   "$candidate"
  fi
}
```

Candidate-exists-means-checkout is what removes `write.sh`'s
`die "branch $branch already exists"` (line 93): re-running `/iso-write` on the
same plan now resumes its branch instead of refusing.

### The seven cases

Worked with ticket `FIRE-20`, plan `docs/superpowers/plans/2026-08-27-feat-wiki-ingest.md`, `branches.protected = "dev test prod"`.

| # | on | ticket `Branch` | proposed | verdict | why |
|---|---|---|---|---|---|
| 1 | `feat/wiki-ingest` | `feat/wiki-ingest` | — | `stay` | already right |
| 2 | `feat/hotfix-typo` | `feat/wiki-ingest` | — | `stay` | tree wins; caller rebinds only if it holds a plan path |
| 3 | `dev` | `feat/wiki-ingest` *(exists)* | `feat/other` | `checkout feat/wiki-ingest` | resume the ticket's branch |
| 3b | `dev` | `feat/wiki-ingest` *(absent)* | `feat/other` | `create feat/wiki-ingest` | ticket names it; this clone lacks it |
| 4 | `dev` | `dev` or empty | `feat/wiki-ingest` *(absent)* | `create feat/wiki-ingest` | name from the hint |
| 4b | `dev` | `dev` or empty | `feat/wiki-ingest` *(exists)* | `checkout feat/wiki-ingest` | replaces write.sh's `die` |
| 5 | `dev` | `dev` or empty | *(empty)* | `ask` | nothing to derive a name from |

Rows 4 and 5 differ only in whether a proposed name was supplied. `/iso-write` always has a plan filename, so it never reaches row 5. `/iso-commit` has the subject it is about to write, so it reaches row 5 only when that subject yields no usable slug.

`ask` is the sole prompt in the design. Everywhere else the config already holds the answer.

### Why row 3 exists

```
  session ends after /iso-write; you return the next day on dev, with staged work
                 |
                 v
        /iso-commit  ->  gate: on dev (protected), FIRE-20 says feat/wiki-ingest
                     ->  action=checkout, branch=feat/wiki-ingest
```

Without row 3 the gate would cut `feat/wiki-ingest-2` and split one ticket across two branches.

## Component 2 — the rebind verb

`ticket_for_plan` (`tracking.sh:104-118`) already resolves **either** a plan basename **or** an exact branch name; the branch arm exists because `/iso-push` holds a branch and never a plan path. The new verb therefore needs no new resolver and no second index:

```bash
tracking.sh rebranch <identifier> <new-branch>
#   identifier: a plan path (iso-write holds one) or the OLD branch name (commit, push)
```

It makes the same two writes `do_bind` makes, without the session file and without the status promotion:

```bash
key=$(ticket_for_plan "$1") || { logf "rebranch: no ticket for $1"; exit 0; }
ledger_put "$key" "<row with .branch replaced by $2>"
ensure_property Branch text && tk_issue_property "$key" Branch "$2"
```

Three required properties:

1. **Resolve before writing.** After the ledger write the old identifier matches nothing, so the lookup must happen first. Callers that check out before rebinding pass the old branch name explicitly, which leaves checkout order free.
2. **Idempotent, and silent on a miss.** The same identifier twice is a no-op. No live ticket exits 0 with a log line, matching `move_plan_ticket` (line 125-135). Tracking must never fail a run — `write.sh:107` and `push.sh:438` both depend on that.
3. **No ticket comment.** The property is overwritten in place.

### The read half

`/iso-commit` needs the ticket's branch to reach row 3, and holds no plan path.
One more verb, the read counterpart of `rebranch`:

```bash
tracking.sh branch-of <identifier>    # prints the ledger row's branch, or nothing
```

`/iso-write` needs no such call: its proposed name comes from the plan filename,
so when the ticket's branch already exists it is the same string, and row 4b
reaches the same checkout with an empty `<ticket-branch>`.

### Callers

| skill | when | call |
|---|---|---|
| `iso-write` | after `cmd_resolve`, in every mode | `rebranch <plan> <branch>` |
| `iso-commit` | after the gate creates or checks out | `rebranch <old-branch> <new>` |
| `iso-push` | inside `rescue_to_branch`, after the checkout | `rebranch <prot> <new>` |

`iso-write` calls it even for `mode=current-branch` and `--no-branch`. That costs one ledger read, and it is precisely case 2 above — the case where the ticket is most likely already wrong because the user moved themselves.

## Component 3 — per-skill wiring

### iso-write

`cmd_resolve`'s default arm (`write.sh:88-99`) currently derives the branch name and dies if it already exists. It becomes a `branch_gate "$plan"` call. Row 4 reproduces today's behaviour. Row 3 replaces the `die` with a checkout, so resuming a ticket's own branch stops being an error. `--no-branch`, `--branch=`, and `--worktree` continue to bypass the gate — they are explicit instructions. Every arm ends with `rebranch`.

### iso-commit

The gate needs the commit subject as its hint, and the subject is drafted after reading the diff, so the gate cannot live in `preflight`. `SKILL.md`'s step order becomes:

```
1  preflight        (repo, detached, something to commit)   unchanged
2  draft message                                            unchanged
3  branch_gate "<subject>"                                  NEW
4  git commit
5  rebranch                                                 NEW
```

This is the only skill whose documented flow changes shape.

### iso-push

One `rebranch` line inside `rescue_to_branch`, after the checkout (`push.sh:178`). `ticket_key` (line 441-451) needs no change; it starts hitting because the ledger is finally correct.

## Component 4 — the shared guideline

`skills/iso-config/SKILL.md` gains a **Branch policy** section carrying the five-row table, `branch_gate`'s output contract, and the rule that no skill reads `branches.protected` directly any more. `iso-config` is already the shared-vocabulary skill every `iso-*` sources, so it is the one place all four can point at.

`AGENTS.md`'s architecture tree gains `branch.sh` under `skills/iso-config/`.

## Testing

| file | must prove |
|---|---|
| `skills/iso-config/scripts/lib/branch.test.sh` *(new)* | each of the five rows, in a throwaway git repo |
| `skills/iso-issue-tracking/scripts/tracking.test.sh` | `rebranch` resolves by plan path and by old branch; writes both ledger and property; no-ops on a miss; is idempotent |
| `skills/iso-write/scripts/write.test.sh` | row 3 checks out instead of dying |
| `skills/iso-push/scripts/push.test.sh` | `rescue_to_branch` rebinds |
| `skills/iso-commit/scripts/commit.test.sh` | the gate fires on a protected branch |
| `scripts/dispatch-integrity.test.sh` | passes with the new `rebranch` arm — existing guard, no edit needed |

## Files touched

Two new: `skills/iso-config/scripts/lib/branch.sh`, `skills/iso-config/scripts/lib/branch.test.sh`.

Twelve edited:

| file | why |
|---|---|
| `iso-issue-tracking/scripts/tracking.sh` | the `rebranch` arm and function |
| `iso-issue-tracking/scripts/tracking.test.sh` | `rebranch` cases |
| `iso-issue-tracking/SKILL.md` | document the `rebranch` verb |
| `iso-write/scripts/write.sh` | `branch_gate` replaces `is_base_branch`; `rebranch` call |
| `iso-write/scripts/write.test.sh` | row 3 checkout |
| `iso-write/SKILL.md` | row 3 is no longer an error |
| `iso-push/scripts/push.sh` | `branch_gate` replaces `is_protected`; `rebranch` in `rescue_to_branch` |
| `iso-push/scripts/push.test.sh` | rescue rebinds |
| `iso-commit/scripts/commit.sh` | the gate |
| `iso-commit/scripts/commit.test.sh` | gate fires on a protected branch |
| `iso-commit/SKILL.md` | the new step order |
| `iso-config/SKILL.md` | the Branch policy section |

Plus `AGENTS.md`'s architecture tree, for `branch.sh`.

No new dependency. `branch.sh` sources `config.sh` the way every other lib does.

## Out of scope

- Promoting any of this to the VPS or to other repos' trackers.
- Backfilling `Branch` on tickets already opened. Existing rows correct themselves the next time a skill lands on a branch.
- Any change to `reconcile`, which reads `.branch` from the ledger and simply becomes correct once the ledger is.

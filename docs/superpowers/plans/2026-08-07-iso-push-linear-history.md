# iso-push refactor — linear history, force only where unavoidable

Target: `~/.claude/skills/iso-push/{SKILL.md,scripts/push.sh,scripts/push.test.sh}`
Skill is global and stack-agnostic. Nothing repo-specific belongs in it.

## Problem, as measured

`gh pr merge --rebase` rewrites commits at merge time:

```
dabc1ee  tree=2356699…  2026-08-06 17:47  feat: let an agent hear voice notes…   branch
1a4e345  tree=2356699…  2026-08-07 09:57  feat: let an agent hear voice notes…   dev
same tree, same patch-id 616488e32226, different SHA, committer date = merge click
git rev-list --left-right --count HEAD...origin/dev  →  3  3
```

Consequences:

1. Every merged branch is left diverged from `dev` with zero content difference.
   The next push is non-fast-forward, so the skill reaches for `--force`.
2. `SKILL.md` step 4's "establish which side the base is built on" analysis exists
   only to survive that manufactured divergence.
3. The SHA that lands on `dev` was never tested — CI ran on the pre-rebase head.

`gh pr merge --merge` on cascade hops gives `test`/`prod` a commit `dev` will never
have, so they can never fast-forward again and each promotion adds a rung:

```
git diff --stat origin/test origin/dev   → empty      trees identical
git diff --stat origin/prod origin/dev   → empty
commits test has that dev lacks:  5   all "Merge pull request #N", empty diffs
commits prod has that dev lacks: 10   all "Merge pull request #N", empty diffs
git merge-base --is-ancestor origin/test origin/dev → 1   (NOT ancestor)
```

## Target flow

```
 feat/x · fix/x · refactor/x        preflight refuses dev/test/prod, detached HEAD
        │
        ▼  status: behind · remote · dirty
 behind > 0 → git rebase origin/dev          AUTO, no prompt
              conflict → stop, report, wait for a decision
        │
        ▼  push branch:refs/heads/branch
              remote absent          → plain push
              rebased AND published  → --force-with-lease   ASK, every time
        │
        ▼  gh pr create --base dev ; gh pr checks --watch
        │
        ▼  merge-base --is-ancestor origin/dev HEAD
           git push origin branch:refs/heads/dev     plain push, no force
        │
 dev  ●──●──●──●──●  linear, your SHAs, PR flips to Merged
        │
        ▼  cascade: compute bump from origin/test..origin/dev
           commit chore(release): 0.4.0 ON dev, push dev, tag v0.4.0
 dev  ●──●──●──●──◆
        │
        ▼  PR dev→test ; CI ; push origin <sha>:refs/heads/test
 test ─────────────◆
        │
        ▼  PR test→prod ; gate workflow ; push origin <sha>:refs/heads/prod
 prod ─────────────◆   same SHA, same version, no second bump
```

One lane. `dev`/`test`/`prod` are three refs at different positions on it.

## Decisions

| # | decision |
|---|---|
| 1 | Promotion is a plain push of the source SHA onto the target ref. Not a merge commit, not a rebase-merge. |
| 2 | Feature integration is the same primitive: `git push origin <branch>:refs/heads/dev`. `gh pr merge` is deleted from the skill entirely, both call sites. |
| 3 | `DIVERGED` handling shrinks to: detect, print `theirs:`, stop, ask. The patch-id / which-side-is-the-base analysis is deleted — it was scaffolding for the merge-rewrite bug. |
| 4 | A `test` that is not a descendant of `dev` is an environment defect. `preflight --cascade` refuses with a diagnosis and points at `/iso-init-repo`. The skill never force-pushes an integration branch and owns no `straighten` subcommand. |
| 5 | A branch with `git rev-list --count origin/dev..HEAD` = 0 is already integrated. Report and **exit 0** — that is success, not failure. Do not auto-checkout `dev`; report `you are still on <branch>, dev is at <sha>`. |
| 6 | Rebase runs automatically. Conflicts stop the run and produce a report with a proposed resolution per hunk; the rebase is **left in progress**, not aborted. |
| 7 | Force-push keeps its gate, asked every time. It is the only act in the flow that changes published history. |

| 8 | **Versioning happens only in the cascade, never in the feature flow.** Feature branches never touch the version file. Two concurrent feature PRs would otherwise both compute the same next version and conflict on a file neither author edited — every time, structurally. |
| 9 | The release commit lands **on `dev`** and is pushed directly, without a PR. It cannot live on `test`: a commit `test` holds that `dev` lacks is the braid, and `test` could never fast-forward again. This is a deliberate narrowing of decision 2, written into `SKILL.md` verbatim: *the only commit iso-push may create is a version bump; the only files it may write are the version file and its test; the only branch it may push a self-made commit to is `dev`, during a cascade.* The gate workflow runs on it during the `dev→test` PR, so it is tested before reaching anything deployed. |
| 10 | One annotated tag per release: `v<version>` on the release commit. No `deploy/<env>/<date>` scheme — merged cascade PRs already timestamp each promotion, and encoding a date in a tag name duplicates the annotation's own date. |
| 11 | `iso-init-repo` owns the version file and the test asserting it. `iso-push` reads a known path, bumps, and refuses with `run /iso-init-repo` when absent. Same seam as decision 4: environment shape is not this skill's business. |
| 12 | Bump is computed from `origin/test..origin/dev` — the exact range `cmd_promote` already lists in the cascade PR body. `test→prod` never bumps; it promotes the same number, so "test is on 0.4.0" and "prod is on 0.4.0" name the same commit. |

### Bump rules

Applied to `origin/test..origin/dev`, reusing the existing highest-type-wins logic:

| range contains | bump |
|---|---|
| any `!` or `BREAKING CHANGE:` | major — except below `1.0.0`, where it is minor per SemVer's `0.x` clause. Crossing to `1.0.0` is a manual decision. |
| else any `feat` | minor |
| else any `fix` or `perf` | patch |
| else only `chore`/`docs`/`refactor`/`test`/`ci`/`style` | no bump, no release commit — the artifact did not change |

Bump must be idempotent: `cmd_pr` is find-or-create, so a re-run after a red build
must not stack a second release commit. Guard on `dev`'s tip already being a
release commit for the computed version.

Decision 6 overrides `SKILL.md`'s current "one rule that overrides everything" and
the standing memory `never-rewrite-git-history-unasked`. That memory needs
amending to: force-push needs a go-ahead; a clean rebase onto the base does not.

## Why a plain push is the whole safety model

`git push origin <branch>:refs/heads/dev` is a compare-and-swap. Git moves a ref
only forward along its own history, so the push succeeds **only** if `dev` is an
ancestor of the branch. If `dev` moved while CI ran, the push is rejected and
nothing is touched — no lease, no lock, no retry loop. Rebase and re-run.

Same property guards every cascade hop.

## push.sh changes

| function | change |
|---|---|
| `cmd_base` | unchanged |
| `cmd_preflight` | with `--cascade`, additionally assert `git merge-base --is-ancestor origin/test origin/dev` and `origin/prod origin/test`. Failure → diagnosis + `run /iso-init-repo`. |
| `cmd_status` | unchanged, except `DIVERGED` output trimmed per decision 3. Add `integrated:` line when `origin/<base>..HEAD` is 0. |
| `cmd_rebase` | on conflict, exit non-zero **and leave the rebase in progress**. Emit `git diff --name-only --diff-filter=U`. Never `--abort` on the skill's behalf. |
| `cmd_push` | force decided by `origin/<branch>` presence, not by "did we rebase". Remote absent → plain push even after a rebase. |
| `cmd_pr` | unchanged (find-or-create) |
| `cmd_checks` | unchanged |
| `cmd_merge` | **delete** |
| `cmd_integrate <src> <dst>` | **new**: fetch dst, assert `merge-base --is-ancestor origin/<dst> <src>`, `git push origin <src>:refs/heads/<dst>`, refetch, echo landed SHA |
| `cmd_promote <from> <to>` | keeps exit 3 on level. No tagging — that moves to `cmd_release`. |
| `cmd_bump <from> <to>` | **new**: read version file, classify `origin/<to>..origin/<from>` per the rule table, echo `current next kind` or `none`. Pure computation, writes nothing. |
| `cmd_release <version>` | **new**: write version file + its test, commit `chore(release): <version>`, `git tag -a v<version> -m …`, push `dev` and the tag. Idempotent — no-op if `dev`'s tip is already that release commit. The only place in the skill that creates a commit. |

## SKILL.md changes

- Rewrite "The one rule that overrides everything" around **consent on conflict
  and consent on force-push**, not consent on rebase.
- Step 3: rebase is automatic. Add the conflict report format.
- Step 4: delete the patch-id / which-side-is-the-base section. Keep the
  fully-qualified `<branch>:refs/heads/<branch>` warning — the `push.default=upstream`
  trap is real and unrelated.
- Step 6: replace "merge the feature PR" with "integrate": checks → `integrate`.
- Step 7: cascade becomes `bump` → `release` (dev only, once) → per hop
  `promote` → PR → checks → `integrate`. No `merge <n> merge`.
- New section: the version-bump rules table and the narrow write permission from
  decision 9, stated as a rule the skill may not exceed.
- Reference **the gate workflow `iso-init-repo` installs**, never its filename —
  it has already been renamed once mid-design (`ci-prod-gate` → branch-gate).
- Constraints: drop "never merge a red build" phrasing tied to `gh pr merge`;
  the gate is now "never integrate a red build".

### Conflict report format

```
iso-push: rebase onto origin/dev stopped at commit 2/3

  applying   feat: own the runtime user, and warn on a duplicated login
  conflict   build_agent/floor.py:41
             scripts/agent-login.sh:12

  build_agent/floor.py:41
    ours   (origin/dev)   USER = "hermes"
    theirs (your commit)  USER = os.environ["AGENT_USER"]
    proposed: take theirs. Your commit introduces AGENT_USER; dev's literal
    predates it and has no other reader (1 grep hit, same line).

  repo is mid-rebase. say the word and I resolve as proposed, or:
    git rebase --continue     after you fix it
    git rebase --abort        to back out entirely
```

`push.sh` supplies the conflicted paths only. Reading hunks and proposing a
resolution is judgement — it lives in `SKILL.md`.

### Environment-defect report

```
iso-push: 'test' is not a descendant of 'dev' — cascade cannot fast-forward.

  5 commits on test that dev lacks, all empty merge commits:
    42766ea Merge pull request #17 from IsaiaScope/dev
    …
  git diff --stat origin/test origin/dev → no differences (trees identical)

  This repo was set up before linear promotion. Run /iso-init-repo to straighten
  the environment branches, then re-run /iso-push --cascade.
```

## push.test.sh additions

- integrate accepted when base is an ancestor
- integrate rejected when base moved — asserts nothing was written
- push chooses plain (not force) when `origin/<branch>` is absent after a rebase
- push chooses force when `origin/<branch>` exists and a rebase ran
- promote exits 3 when level
- bump: `feat!` below 1.0.0 → minor, not major
- bump: docs-only range → `none`, no release commit created
- bump: highest type wins across a mixed range
- release is idempotent — second call on the same version is a no-op
- release refuses when the version file is absent, naming `/iso-init-repo`
- preflight --cascade refuses a non-descendant `test`
- status reports `integrated` and exits 0 when `origin/dev..HEAD` is 0

## Open, unverified

GitHub flipping a PR to **Merged** on a direct fast-forward push is asserted, not
measured in this repo. The commits and the PR record survive either way; worst
case the badge reads Closed. First real run settles it. If it lands as Closed,
add a `gh pr comment` with the landed SHA — cosmetic.

## Out of scope

Cutting the existing braid on this repo's `test`/`prod` is a one-time migration,
and per decision 4 it belongs to `/iso-init-repo`, not here. Deploy-webhook
behaviour is a property of the repo, not of the skill.

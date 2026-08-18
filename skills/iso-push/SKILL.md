---
name: iso-push
description: Push committed work, open a PR against dev, and land it with a merge commit so no commit is ever rewritten or duplicated. Use when invoked as /iso-push [--pr] [--cascade test|prod] [--no-merge] [--stay], or when asked to push a branch, open a PR against dev, or promote dev to test or prod. Requires a dev or develop branch on origin. Rebases the branch onto its base automatically; returns to dev after a landing unless --stay; never force-pushes without explicit approval.
---

# iso-push

Push what is committed, open a PR a person can read, and promote it through the
environment branches — leaving a single linear history and rewriting nothing
that has been published without asking first.

Invocation: `/iso-push [--pr] [--cascade test|prod] [--no-merge] [--stay]`.

| flag | effect |
|---|---|
| *(none)* | push the current branch, nothing else |
| `--pr` | push, then open a PR against `dev` and integrate it once CI is green |
| `--cascade test` | release, then promote `dev` → `test` |
| `--cascade prod` | release, then promote `dev` → `test` → `prod` |
| `--no-merge` | open the PRs and stop; integrate nothing |
| `--stay` | stay on the feature branch after a landing instead of returning to the base |

`--cascade` works with or without `--pr`. Without it, `dev` is promoted exactly
as it currently stands.

**After anything lands, you end up on the base.** A merged feature branch is a
dead lane — GitHub will never move it again, so a commit made there starts a
second head and `git pull` fetches a ref frozen at the merge. `--stay` keeps you
on it, for the case where the branch is a base for follow-up work you are about
to push again.

Mechanics live in `skills/iso-push/scripts/push.sh`. Run it by absolute path.

## Why every landing is `gh pr merge --merge`

> Summarised here; the full argument — rebase, squash and merge drawn out as
> trees across two feature branches and three rungs, plus the public/private and
> free/paid matrix that forces it — is in [docs/why-merge.md](docs/why-merge.md).

**GitHub is the only writer to `dev`, `test` and `prod`.** No clone ever pushes
to them. That is the whole design.

It follows from where branch protection is *unavailable*: a private repo on
GitHub Free returns 403 from the protection API, so nothing server-side refuses
a direct push, and the pre-push guard `iso-init-repo` installs is the only
substitute. A skill that landed work by pushing to `dev` would be blocked by
that guard — correctly. Rather than drill an escape hatch through the one
control the repo has, this skill stops pushing to protected branches at all.

```bash
gh pr merge <n> --merge
```

**One method, every landing, feature and promotion alike.** The reason is a
single property: `--merge` is the only method GitHub offers that does not
*rewrite* commits.

`--rebase` and `--squash` both rebuild the source's commits, producing a target
that **contains** the work without **descending** from it. Two things break, and
both are permanent:

- The source branch is left pointing at commits the target will never hold.
  Nothing here is ever deleted, so that is a stale parallel lane per branch —
  and for `dev`/`test`/`prod`, one more lane at every rung. Three rungs once left
  **four copies of every commit** in this repo.
- `origin/<dst>..origin/<src>` keeps listing commits that already landed, so
  every later promotion re-proposes them and re-raises their conflicts.

A fast-forward would avoid both — and **GitHub has no fast-forward merge
method**. Bitbucket and GitLab do; GitHub offers only merge commit, squash and
rebase, and "Rebase and merge" rewrites SHAs even when the branch is already on
top of the base. FF is reachable only by `git push`, which is exactly what the
no-direct-push rule forbids. On GitHub the two are mutually exclusive.

**What `--merge` costs, stated plainly:** one merge commit per landing. It
carries no content, and the count grows with the number of *landings*, not the
number of *commits* — unlike a rebase, where a 40-commit promotion duplicates 40
commits. Read a promoted branch with `git log --first-parent` and it is one line
per landing.

What it buys is that **ancestry stays true**. `origin/<src>` really is an
ancestor of `origin/<dst>` afterwards, which is what makes "what is left to
promote" and "did this land" answerable at all — offline, with no tree hashing
and no `gh pr list`. `integrate` asserts that ancestry after every merge rather
than assuming it: if someone flips the repo's merge method, the next promotion
fails loudly instead of quietly duplicating history.

If the base moved such that the merge cannot apply, GitHub refuses it and
nothing is written. Rebase and re-run.

## The rules that override everything

**Never force-push without asking first.** Not when the user said "push
everything", not when the rebase obviously requires it. Report the facts, stop,
wait for a yes. Force-push is the one act in this flow that changes history
other people already have.

**Never resolve a rebase conflict without asking first.** Report where the
conflict is and how you would resolve it, then wait.

A clean rebase onto the base needs no approval — it is local, recoverable via
`--abort`, and the pre-rebase tip stays in reflog. Consent attaches to
*publishing* a rewrite, not to producing one.

**The only commit this skill may create is a version bump.** The only files it
may write are `VERSION` and the test asserting it. The only branch it may push a
self-made commit to is the base, during a cascade. Everything else it pushes is
a branch tip that a PR and CI have already passed.

## Flow

1. **Preflight** — `push.sh preflight [--cascade]`. Non-zero: print its message
   and stop. Checks the repo, refuses a detached HEAD, refuses to run from
   `dev`/`develop`/`test`/`prod`, checks `gh` auth, resolves the base branch,
   and with `--cascade` additionally verifies `test` and `prod` carry no work of
   their own. Echoes `<branch> <base>`.

   Merge nodes left by past promotions are expected and allowed. What is refused
   is a **non-merge** commit on `test` or `prod` that its upstream lacks — a
   hotfix applied straight downstream, which the promotion PR does not show and
   which widens at every rung. That is an **environment defect**, not a push
   problem: get the commit onto `dev` first. This skill never force-pushes an
   integration branch to fix it.

2. **Status** — `push.sh status <base>`. Four independent things, any one of
   which can sink the push:

   - `behind: N` — commits on the base you don't have, plus the replay list.
   - `integrated:` — nothing left to carry. The branch is already in the base.
   - `remote: level | DIVERGED | absent` — the branch against **its own**
     remote, `origin/<branch>`. Divergence also prints `theirs:`.
   - `uncommitted:` — dirty paths. Exit 3.

   They are separate axes: a branch can sit level with the base and still be
   diverged from its own remote, because `origin/<branch>` is invisible from the
   base. An amend after a push is the usual cause.

   **`integrated:` → stop, exit 0.** Detected by `ahead == 0`, offline. Because
   `--merge` rewrites nothing, a landed branch is a genuine ancestor of its base
   and has nothing left to carry — ancestry answers the question directly. (Under
   a rebase merge it could not: the base would hold only rebuilt copies, `ahead`
   would never reach 0, and `behind` would count the base's copies of this
   branch's own work.)

   Report `integrated: …` and stop. This is success, not failure — do not open a
   PR with no content in it, and do not check the user out onto `dev`. Say where
   they are and let them move.

   That is not in tension with step 8: the return happens because **this run**
   landed something. Here the branch was already in the base before the run
   started, so there is nothing to report and no reason to move anyone.

   **Dirty tree → ask.** List the paths and confirm before going further. A push
   ships commits, not files, so uncommitted work silently stays out of the PR.
   Do not offer to commit it — that is `/iso-commit`'s job.

   **DIVERGED → stop and ask.** Show `theirs:` and let the user decide. A real
   divergence means someone rewrote the branch — an amend or a rebase after a
   push. Landing never causes one, because nothing this skill does rewrites a
   commit.

3. **Rebase** — if `behind` is greater than 0, run `push.sh rebase <base>`
   without asking. Clean: continue.

   **Conflict: it exits non-zero and leaves the rebase in progress.** Aborting
   would discard the commits that already applied cleanly. Read the conflicted
   hunks and report, one block per file:

   ```
   iso-push: rebase onto origin/dev stopped at commit 2/3

     applying   feat: own the runtime user, and warn on a duplicated login
     conflict   build_agent/floor.py:41
                scripts/agent-login.sh:12

     build_agent/floor.py:41
       ours   (origin/dev)   USER = "hermes"
       theirs (your commit)  USER = os.environ["AGENT_USER"]
       proposed: take theirs. Your commit introduces AGENT_USER; dev's
       literal predates it and has no other reader (1 grep hit, same line).

     repo is mid-rebase. say the word and I resolve as proposed, or:
       git rebase --continue     after you fix it
       git rebase --abort        to back out entirely
   ```

   Every `proposed:` names why one side wins — what introduced it, what still
   reads it. A proposal that cannot say that is a guess and must be marked one.
   Then stop and wait.

4. **Push** — `push.sh push`, or `push.sh push --force` when step 3 rebased a
   branch that is already published.

   `--force` needs its own approval, every time. `push.sh` decides whether it is
   *needed* — if `origin/<branch>` does not exist there is nothing published to
   rewrite, so it downgrades to a plain push and says so rather than spending
   your approval.

   Both forms name the destination in full — `<branch>:refs/heads/<branch>`.
   Never hand-roll a `git push` here. A feature branch can carry an upstream of
   `origin/dev`, and under `push.default=upstream` an unqualified push resolves
   against it and lands the branch **on dev**, skipping the PR and CI entirely:

   ```
   $ git push -u origin feat/up          # upstream = origin/dev
   ca797c6..741e406  feat/up -> dev
   ```

   Stop here unless `--pr` or `--cascade` was passed.

5. **Feature PR** — write the message to a temp file (format below), then
   `push.sh pr <branch> <base> <msgfile>`. Reuses an open PR for the same
   head/base instead of opening a second one, so a re-run after a red build is
   safe. Echoes the PR number.

6. **Integrate the feature PR** — skip when `--no-merge`. Run
   `push.sh checks <n>`. Green or no CI configured → `push.sh integrate <branch> <base>`.
   Red → report the failing job, print `gh run view --log-failed`, and stop the
   whole run.

   `integrate` refuses if the base moved while CI ran. That is not an error to
   work around: go back to step 3, rebase, and re-run. The branch is never
   deleted.

7. **Cascade** — only with `--cascade`.

   First, **release** — once, on the base, before any hop:

   - `push.sh bump <base> test` — echoes `<current> <next> <kind>`, or `none`.
   - `none` → the branches are level, there is nothing to promote. Report it and
     stop; do not cut a version for zero commits. This is the only `none`.
   - Otherwise write **two** files and pass both:
     - `<msgfile>` — the cascade PR message, subject included.
     - `<annotfile>` — the same body, but with the cascade subject replaced by a
       one-line **release title** (format below).

     Then `push.sh release <next> <msgfile> <annotfile>`. It builds
     `chore(release): <next>` in a
     detached worktree, pushes it to `release/v<next>`, opens a PR against the
     base and lands it like everything else — the release commit is not exempt
     from the rule that GitHub is the only writer to a protected branch. It then
     tags that same commit, and asserts it is reachable from the base before
     doing so. Your working tree is never touched and a dirty tree cannot block
     it.

   Then each hop in turn (`dev`→`test`, and for `prod` also `test`→`prod`):

   - `push.sh promote <from> <to>` — exit 3 means the branches are level, so
     report "nothing to promote" and stop cleanly. Otherwise it prints a count
     and the commit subjects being carried.
   - Write the cascade message, then `push.sh pr <from> <to> <msgfile>`.
   - `push.sh checks <n>`, then `push.sh integrate <from> <to>`.

   `test→prod` never bumps. It promotes the same commit — nothing is rebuilt at
   a rung — so "test is on 0.4.0" and "prod is on 0.4.0" name **the same SHA**,
   which is the point. Verify a promotion with
   `git merge-base --is-ancestor origin/test origin/prod`.

   A hop that fails CI stops the cascade. Later hops do not run.

8. **Home** — once, after the last successful landing of the run, unless
   `--stay`. Run `push.sh home <base>`: it checks out the base and
   fast-forwards it to `origin/<base>`.

   **Only when something actually landed.** Not after `--no-merge`, not after
   the `integrated:` exit in step 2, not after a red build or a stopped
   cascade — moving the user off a branch whose work is still in flight loses
   them the thing they were looking at.

   `<base>` is always the base from step 1, `dev`, including after a cascade to
   `prod`. `test` and `prod` are places work is promoted **to**, never worked
   **on**; checking someone out onto one invites the straight-to-prod commit the
   preflight gate exists to refuse.

   Two refusals, both reported and neither fatal to what already landed:

   - **Dirty tree** — exit 3. Says which paths and leaves you where you are.
     Uncommitted work is not something a flag about your final branch may move.
   - **Local base holds commits `origin/<base>` lacks** — exit 1. That branch is
     not a copy of the remote one, and `refs/heads/dev` shadows `origin/dev` in
     every later `rev-parse`. Report it; do not straighten it here.

9. **Report** — every PR URL created or merged, the version released and its
   tag, where the run left you, and what was skipped.

## Versioning

Versioning happens **only in the cascade**, never in the feature flow. Two
feature PRs open at once would both compute the same next version and then
conflict on `VERSION` — a file neither author touched — every single time.
Promotion is serial by construction, so the collision cannot occur there.

The bump is computed from `origin/test..origin/dev`, the same range the cascade
PR body lists. Highest wins, exactly like the PR subject rule:

| range contains | bump |
|---|---|
| any `!` after the type, or `BREAKING CHANGE:` in a body | major |
| else any `feat` | minor |
| else any `fix` or `perf` | patch |
| else **anything at all** — `chore`, `docs`, `refactor`, `test`, `ci`, `style`, `build`, `revert` | patch |
| an **empty** range — nothing to promote | none — no release commit |

**Every promotion cuts a version.** `none` means exactly one thing: there is
nothing to promote. It is never a judgement about what the commits were.

An earlier rule skipped the release when the range held no `feat`/`fix`/`perf`.
It read well and was wrong in two ways:

- `git describe origin/prod` named a release the branch had already moved past.
  `prod` reported `v0.1.0` while carrying commits no tag covered — so "which
  version is prod running" had a true-sounding answer that was not the truth.
- The fall-through swallowed `revert:` and `build:` along with the docs. A
  revert undoes behaviour users can observe; a `build:` can move an engine floor
  or a dependency pin. Both shipped with no version recording them.

The precedence table above is now the *only* thing keeping a feature from
shipping as a patch, so highest-type-wins matters more than it did, not less.

Below `1.0.0` a breaking change bumps **minor**, per SemVer's `0.x` clause.
Crossing to `1.0.0` is a decision, not an inference — ask.

`VERSION` is a single semver line at the repo root. **Absent → it is seeded at
`0.1.0`**, not refused: `bump` echoes `(absent) 0.1.0 initial` and the release
proceeds. The seed ignores the commit kinds in the range — with no existing
number there is nothing to increment, so they have no bearing on the result. A
repo needs a floor before anything can be counted up from it. Every bump after
the first follows the table above.

> The test asserting `VERSION` should **derive** its expectation — comparing the
> file against the latest `v*` tag — rather than pinning a literal that has to be
> rewritten on every release. `iso-init-repo`'s call, but a pinned literal is a
> second place for the number to be wrong.

### Where the number lives

`VERSION` is **canonical**: read with `git show origin/dev:VERSION`, so it needs
no toolchain, no JSON parser and no checkout, and it works in a repo with no
manifest at all. The git tag is a *projection* of it — `v` + the contents,
written by the same command — not a second source of truth.

**`package.json` is different, and `release` syncs it in the release commit
itself.** Unlike the tag, npm and CI *consume* it, so a release that bumps
`VERSION` and leaves the manifest stale ships the stale one, silently. Two
hand-maintained copies with no reconciliation is the one thing every versioning
guide names as the anti-pattern, so both move together, in one commit, with no
window where they disagree:

```bash
npm --prefix <worktree> version <v> --no-git-tag-version --allow-same-version
```

`npm version` rather than a `jq` edit, because it also updates
`package-lock.json` — a lockfile left behind turns one drift into two. Both are
staged. A repo carrying a `package.json` with no `npm` on PATH **refuses the
release** rather than shipping a manifest it could not update.

## Tags

One annotated tag per release.

| | |
|---|---|
| name | `v` + the `VERSION` contents, e.g. `v0.4.0` |
| kind | **annotated, never lightweight.** A lightweight tag is a bare pointer — no tagger, no date, no message. It can say *which commit*, never *what shipped*. |
| points at | the `chore(release): <version>` commit on the base |
| when | once, before the first hop. `test→prod` tags nothing. |
| first line | a **release title** — see below. Never the cascade PR's subject. |
| body | the cascade PR body — `### 📦 Summary`, `### 📝 Commits`, then one `🔗` line per work PR, appended by `push.sh release` |

### The release title

`git tag -n1` prints **only the first line**, and that listing is the release
index — the view anyone reaches for first. Seeding the tag from the cascade PR
put the PR's subject there, so the index read as a list of hops:

```
v0.2.0          chore(cascade): dev → test
v0.1.0          chore(cascade): dev → test
```

Every release, the same line, naming nothing. So the tag gets its own first line:

```
v0.3.0          Move the fleet roster into the encrypted vault
v0.2.0          Add cursor pagination and retire the offset path
v0.1.0          Encrypt hetzner credentials and gate promotions
```

Rules for it:

- **One line, ≤72 chars, imperative, capitalised, no trailing period.**
- **No `type(scope):` prefix.** A tag is not a commit — commitlint never sees it
  and the version bump never reads it, so the grammar buys nothing and spends
  the characters that matter most in a listing.
- **Say what the release delivers, not which branches moved.** If the line would
  work as the subject of any other release, it is wrong.
- Emoji stay out of it, same as a commit subject. The `###` headings below carry
  the two the body is allowed.

It is the `### 📦 Summary` compressed to one line — write that first, then
distil. Do not reuse a commit subject verbatim: a release carrying two features
would silently advertise one and hide the other.

The annotation is a git object replicated to every clone, so the summary travels
with the code. That is what makes the body worth writing: `git show v0.4.0`
answers *what shipped* on a machine with no network and no GitHub account, long
after the PR page has scrolled out of reach.

What the tag makes answerable, all offline:

| question | command |
|---|---|
| what shipped in 0.4.0 | `git show v0.4.0` |
| which release is `prod` on | `git describe --tags origin/prod` |
| did 0.4.0 reach `prod` | `git merge-base --is-ancestor v0.4.0 origin/prod` |
| what has landed since | `git log --oneline v0.4.0..origin/dev` |

`git describe` works only because nothing is rebuilt at a rung: the tagged commit
is *literally* the one `prod` contains. Under a rebase merge each rung held its
own copy, the tag matched none of them, and every question above needed a tree
comparison instead.

**The tag's count reads one lower than the cascade PR's. That is correct, not a
bug.** The tag is written before `chore(release):` itself has been promoted, so
the release commit is absent from its own annotation — it is bookkeeping, a
number recording the other commits, not shipped work.

No `deploy/<env>/<date>` scheme: the merged cascade PRs already timestamp each
promotion, and a date in a tag *name* duplicates the annotation's own date.

## Feature PR message

```
type(scope): message

### 📦 Summary

Two or three lines of plain language: what this delivers and who it
affects. Cut the section if it cannot say that.

### 📝 Changes

- what changed
- what changed, because reason
```

Same two headings as the cascade body, so a reader learns one shape. `Changes`
rather than `Commits`: these dots describe the diff, not a commit list.

The subject follows `iso-commit` exactly — `type(scope): message`, imperative,
≤50 chars preferred and 72 hard, no trailing period, no emoji — the subject is
machine-read by commitlint and by the bump, and an emoji there breaks
both. Emoji live in the body's two headings and nowhere else. **Highest type
across the branch's commits wins**: a branch holding a feature and a fix is
`feat:`.

The lede is at most 3 lines and answers *should I care*. The dots answer *what
changed*, one per change, `-` never `*`, wrapped at 72.

**Shape rule.** Every dot — and the lede — names something concrete in the
diff: a file, function, endpoint, flag, behavior, error. Anything that cannot
name one is padding and gets deleted, not reworded.

## Cascade PR message

Its **body** is reused as the `v<version>` tag annotation; its **subject** is not
— the tag gets a release title instead (see [The release title](#the-release-title)).
Write both files, pass both to `push.sh release`.

```
chore(cascade): dev → test

### 📦 Summary

Encrypts the hetzner credentials into the repo and puts a branch gate
around promotion, so a rebuilt machine reaches a working state from
`chezmoi init --apply` instead of hand-copied files.

### 📝 Commits (3)

- feat(hetzner): add create, delete and ssh skills
- feat(iso-plan): gate the grill step on the domain docs
- chore(iso-commit): track the skill in the repo
```

Two headings, one emoji each, and the count in the `Commits` heading rather than
a sentence of its own. `###` renders as a heading on the PR page and still reads
as a plain label in `git show v0.1.0` — the same text has to work in both.

`push.sh release` appends a `🔗` line per PR that carried work into the release:

```
🔗 https://github.com/owner/repo/pull/5 — feat: add age-encrypted vault for hetzner credentials
```

You do not write those lines — none of the numbers exist when the message file
is written. They are derived: every landing is a `--merge`, so each leaves a
merge commit naming its PR, and the release's range yields them.

**Never the release's own PR.** That one changes a single line of `VERSION` and
answers nothing about what shipped, which is the only question a tag gets opened
for. It is excluded structurally rather than by filtering: the range ends at the
release *commit*, and the release PR's merge node is a descendant of it.

**The summary, at most 5 lines under `### 📦 Summary`.** It says what the release *delivers* — the
thing a reader wants before deciding whether to read the list. Write it at the
release's level, not the commit's: three commits that together move credentials
into an encrypted vault are *one* sentence about credentials, not three
sentences about files.

This is the part that survives into the tag annotation and gets read years
later, with no PR page and no context. It has to stand alone. Same shape rule as
everywhere else — every line names something concrete (a path, a command, a
behavior); a line that cannot is padding and gets deleted.

Do not summarize a docs-only or chore-only promotion into significance it does
not have. `chore: bump three dependencies` is the honest summary, and one line
is a complete summary.

**The dots stay verbatim.** The subjects were already curated by `iso-commit`,
so **list them, do not rewrite them** — re-describing a subject in its own dot is
the redundancy the shape rule bans. The summary is not a re-description: it
answers a question the list cannot, which is why it earns its lines. No SHAs;
the PR page links every commit. Above ~10 commits, group the dots under
`feat` / `fix` / `chore` headings with counts.

## Never write

**Attribution.** No `Co-Authored-By:`, no `Generated with Claude Code`, no `🤖`,
no mention of Claude, AI, or an agent anywhere in a PR title, body, commit, or
tag annotation.

**Meta-narration** — `This PR…`, `This change…`, `I've…`, `We've…`,
`Successfully…`.

**LLM register** — `comprehensive`, `robust`, `seamless(ly)`, `leverage`,
`delve`, `streamline`, `enhance`, `facilitate`, `utilize`,
`significantly improves`, `best practices`.

**Padding** — `various improvements`, `misc updates`, `several changes`,
`and more`.

**Empty ceremony** — no `## Testing`, no `## Checklist`, no `## Screenshots`
with nothing under it. `### 📦 Summary` and `### 📝 Commits`/`Changes` are the
only two headings, and each must have real content under it: a heading is a
label for something, not a placeholder for something you did not write. A PR
with nothing to summarize gets no Summary section, not an empty one.

**More emoji.** Two, one per heading, plus the `🔗` on the tag's PR link. Not in
the subject, not on the dots, not sprinkled through the prose.

## Constraints

- Force-push is gated on explicit approval, every time. A clean rebase is not.
- Conflict resolution is gated on explicit approval, every time.
- Never `--delete-branch`. Removing a branch is the user's call.
- Never `--no-verify`, never `push --force` without `--with-lease`.
- Never `git push --force` to `dev`, `test`, or `prod`. Straightening an
  environment branch belongs to `/iso-init-repo`.
- Never integrate a red build. No CI configured is a pass; a failing check is not.
- Never `home` past uncommitted work, and never onto a `test` or `prod` checkout.
  The return moves the working copy and nothing else — no commit, no push, no
  branch deleted.
- `prod` is only ever fed from `test`; the gate workflow `iso-init-repo` installs
  enforces it server-side. Reference it by role, not by filename — it has been
  renamed once already.

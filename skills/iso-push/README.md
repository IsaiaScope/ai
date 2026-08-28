# iso-push

Push, PR, promote. One linear history, readable PRs, and it never rewrites
anything published without asking.

```
/iso-push
```

## What it does

Pushes the current branch. With `--pr`, rebases onto `dev` if you are behind,
opens a PR, waits for CI, and lands it with a merge commit. With `--cascade`, cuts
a version and carries `dev` through `test` and `prod`.

```
feat(api): add cursor pagination to /events

Large event lists were unusable past a few thousand rows. Callers keep
their existing query params; only the response gains a cursor.

- added `cursor` and `limit` query params, defaulting to 50
- switched the list query to keyset ordering on (created_at, id)
- dropped the offset path, it drifted when rows were inserted mid-scan
```

## Flags

| flag | effect |
|---|---|
| *(none)* | push the current branch, nothing else |
| `--pr` | push, open a PR against `dev`, integrate it when CI is green |
| `--cascade test` | release, then promote `dev` → `test` |
| `--cascade prod` | release, then promote `dev` → `test` → `prod` |
| `--no-merge` | open the PRs and stop |

`--cascade` works without `--pr`, promoting `dev` as it currently stands.

## Rules it follows

**GitHub is the only writer to `dev`, `test` and `prod`.** Everything lands as
`gh pr merge --merge`; no clone ever pushes to a protected branch. That keeps
the pre-push guard `iso-init-repo` installs correct with no escape hatch — which
matters most on a private repo on GitHub Free, where branch protection returns
403 and that guard is the only stand-in for it.

**Nothing is ever rewritten.** `--merge` is the only method GitHub offers that
keeps the source's commits intact. `--rebase` and `--squash` both rebuild them,
producing a target that *contains* the work without *descending* from it — which
breaks two things permanently:

- every surviving branch is left pointing at commits the target will never hold.
  Nothing here is deleted, so that is a stale parallel lane per branch, and one
  more lane per rung. Three rungs once left four copies of every commit.
- `origin/<dst>..origin/<src>` keeps listing commits that already landed, so
  each later promotion re-proposes them and re-raises their conflicts.

**A fast-forward would avoid both, and GitHub does not offer one.** Bitbucket and
GitLab have `--ff-only` as a merge strategy; GitHub has merge commit, squash and
rebase, and its "Rebase and merge" rewrites SHAs even when the branch already
sits on top of the base. FF is reachable only by `git push` — exactly what the
no-direct-push rule forbids. On GitHub the two are mutually exclusive.

The full argument, with the trees drawn out for rebase, squash and merge across
two feature branches and three rungs, lives in
[docs/why-merge.md](docs/why-merge.md).

**The cost is one merge commit per landing.** It carries no content, and the
count grows with *landings*, not *commits* — a 40-commit promotion adds one node,
where a rebase would have duplicated 40. `git log --first-parent prod` reads as
one line per promotion.

**Provenance is by SHA again.** `test` and `prod` holding "the same release" means
the same commit id, not merely the same content. `integrate` asserts
`git merge-base --is-ancestor origin/<src> origin/<dst>` after every merge, so if
someone flips the repo's merge method the next promotion fails loudly instead of
quietly duplicating history.

**Integration is detected by ancestry**, offline. A landed branch is a real
ancestor of its base, so `ahead == 0` answers it — no tree hashing, no `gh pr
list`.

**You are the gate on publishing, not on producing.** A clean rebase onto the
base runs on its own: it is local, `--abort` undoes it, and the old tip stays in
reflog. Force-push always asks, every time, because it is the one act that
changes history other people already have. `push.sh` also decides whether a
force is *needed* — nothing published means nothing to rewrite, so it downgrades
to a plain push rather than spending your approval.

**Conflicts stop and explain.** A conflicting rebase is left in progress, not
aborted, so the commits that already applied cleanly are not thrown away. You
get the file, the two sides, and a proposed resolution with a reason — then it
waits for you.

**One commit, one file, one branch.** The only commit this skill creates is a
version bump; the only files it writes are `VERSION` and its test; the only
branch it pushes a self-made commit to is `dev`, during a cascade. Everything
else it pushes is a branch tip a PR and CI already passed.

**`VERSION` is canonical; `package.json` is synced, not maintained.** `VERSION`
needs no toolchain to read and works in a repo with no manifest at all. The tag
is a projection of it. `package.json` is the copy npm and CI actually consume, so
`release` runs `npm version` in the same commit — lockfile included, since a
stale lockfile turns one drift into two. A `package.json` with no `npm` on PATH
refuses the release rather than shipping a manifest it could not update.

**Versions move in the cascade, never in the feature flow.** Two feature PRs
open at once would both compute the same next version and then conflict on
`VERSION` — a file neither author touched — every time. Promotion is serial, so
the collision cannot happen there. `feat` → minor, `fix`/`perf` → patch, `!` or
`BREAKING CHANGE` → major (minor below `1.0.0`, per SemVer's `0.x` clause),
**anything else → patch**.

**Every promotion cuts a version.** The only range that releases nothing is an
empty one. Skipping the release for a chore-only promotion — the earlier rule —
left `git describe origin/prod` naming a release the branch had already moved
past, and silently swallowed `revert:` and `build:` along with the docs.

**Never integrates a red build.** Branch protection is unavailable on private
repos on the free plan, so this skill is the only thing standing between a
failing build and `prod`. Every landing waits on `gh pr checks --watch` first. No
CI configured passes; a failing one stops the entire cascade.

**PRs get written, not dumped.** A title following `iso-commit`'s subject rules,
then two sections and no others:

```
### 📦 Summary      what this delivers — 3 lines on a feature, 5 on a release
### 📝 Changes      dots naming what changed   (Commits (N) on a cascade)
```

Each must carry real content; a heading with nothing under it is the `## Testing`
boilerplate this replaces, wearing a nicer hat. Two emoji total, none in the
subject — commitlint and the version bump read that line. No commit-log dump, no
`Co-Authored-By`, no *comprehensive robust seamless*.

**Cascade summaries are pitched at the release, not the commit.** Three commits
that together move credentials into a vault are one sentence about credentials.
The dots under them stay verbatim: `iso-commit` already wrote those subjects, and
re-describing one in its own dot says nothing twice.

That body becomes the `v<version>` tag annotation, with the release PR's URL
appended as a `🔗` line. So `git show v0.4.0` returns the summary *and* a way
back to the review, years later, on a machine with no network.

**Branches are never deleted**, and `dev`/`test`/`prod` are never force-pushed.
Straightening an environment branch belongs to `/iso-init-repo`.

**Requires `dev` or `develop`.** `dev` wins if both exist. Neither means the repo
was never set up — preflight refuses and points at `/iso-init-repo` rather than
guessing a base branch. `--cascade` also needs `test` and `prod`, and needs them
free of work of their own: the merge nodes a promotion leaves behind are normal
and expected, but a **non-merge** commit on `test` or `prod` that `dev` lacks is
a hotfix applied straight downstream — invisible to the promotion PR, and wider
at every rung.

## Tags

One annotated tag per release, `v0.4.0`, on the `chore(release):` commit.
Annotated, never lightweight: a lightweight tag is a bare pointer with no tagger,
date or message — it can say *which commit*, never *what shipped*.

**Its first line is a release title, not the cascade PR's subject.** `git tag -n1`
prints only that line, and that listing is the release index — seeded from the PR
it read `v0.1.0  chore(cascade): dev → test`, the same words every release,
naming nothing. A title makes the index a changelog:

```
v0.2.0   Add cursor pagination and retire the offset path
v0.1.0   Encrypt hetzner credentials and gate promotions
```

One line, ≤72, imperative, no `type(scope):` prefix — a tag is not a commit, so
the grammar buys nothing and spends the characters that matter most in a listing.

Below it sits the cascade PR body — summary, commit list, then one `🔗` line per
PR that carried work into the release, appended by `push.sh release` and titled,
so the line reads as *what it was* rather than a bare number. Never the release's
own PR: that one changes a single line of `VERSION` and answers nothing about
what shipped.

A tag annotation is a git object replicated to every clone, so `git show v0.4.0`
returns all of it on a machine with no network and no GitHub account, long after
the PR page has scrolled away.

Nothing is rebuilt at a rung, so the tag names a SHA every branch genuinely
contains:

| question | command |
|---|---|
| which release is `prod` on | `git describe --tags origin/prod` |
| did 0.4.0 reach `prod` | `git merge-base --is-ancestor v0.4.0 origin/prod` |
| what has landed since | `git log --oneline v0.4.0..origin/dev` |

Under a rebase merge none of these worked: each rung held its own copy, the tag
matched none of them, and every question needed a tree comparison.

No `deploy/<env>/<date>` scheme — the merged cascade PRs already timestamp each
promotion, and a date in a tag *name* duplicates the annotation's own.

## Layout

```
skills/iso-push/
├── SKILL.md              the workflow and the message rules
├── README.md             this file
├── docs/
│   └── why-merge.md      why every landing is --merge, with the trees drawn
└── scripts/
    ├── push.sh           preflight, base, status, rebase, push, pr, checks,
    │                     integrate, promote, bump, release
    └── push.test.sh      self-check — bash push.test.sh
```

`push.sh` holds no prose. It reports facts and performs git and `gh` calls; every
message is authored in `SKILL.md`.

## Related

| skill | role |
|---|---|
| `iso-commit` | writes the commits this pushes |
| `iso-init-repo` | creates `dev`/`test`/`prod`, the branch gate, and the pre-push guard |
| `iso-review` | improves and reviews the diff before any of it leaves your machine |

#!/usr/bin/env bash
# Self-check push.sh. Run: bash push.test.sh
# ponytail: asserts only the logic that silently does harm — base resolution
# order, the refusals, the fast-forward guarantees, and the bump arithmetic. The
# gh-backed verbs (pr/checks) need a live GitHub and are not covered here.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/push.sh"

# Hermetic: the suite must not read whatever this machine happens to have in
# ~/.config/iso/iso.json. Cases that want a scope set it themselves.
export ISO_GLOBAL_CONFIG=/nonexistent

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }

# A bare origin plus a clone, so ls-remote and fetch work with no network.
# -b main is pinned on purpose: init.defaultBranch is a global setting, and
# without this the fixtures inherit whatever the host happens to use.
newrepo() {
  local d origin clone
  d=$(mktemp -d); origin="$d/origin.git"; clone="$d/clone"
  git init -q -b main --bare "$origin"
  git init -q -b main "$clone"
  git -C "$clone" config user.email t@t.t
  git -C "$clone" config user.name t
  git -C "$clone" commit -q --allow-empty -m init
  git -C "$clone" remote add origin "$origin"
  git -C "$clone" push -q origin HEAD:refs/heads/main
  printf '%s' "$clone"
}
mkbranch() { git -C "$1" push -q origin "HEAD:refs/heads/$2"; }
# Commit onto a remote branch without disturbing the clone's checkout.
onbranch() {
  local d="$1" b="$2" msg="$3" wt
  wt="$(mktemp -d)/wt"
  git -C "$d" fetch -q origin "$b"
  git -C "$d" worktree add -q --detach "$wt" "origin/$b"
  git -C "$wt" commit -q --allow-empty -m "$msg"
  git -C "$wt" push -q origin "HEAD:refs/heads/$b"
  git -C "$d" worktree remove --force "$wt"
  git -C "$d" fetch -q origin "$b"
}
# Like onbranch but with real content, so patch-id comparisons mean something —
# an empty commit has no patch and `git cherry` cannot classify it. Echoes the sha.
onbranchfile() {
  local d="$1" b="$2" msg="$3" file="$4" wt sha
  wt="$(mktemp -d)/wt"
  git -C "$d" fetch -q origin "$b"
  git -C "$d" worktree add -q --detach "$wt" "origin/$b"
  printf '%s\n' "$msg" > "$wt/$file"
  git -C "$wt" add "$file"
  git -C "$wt" commit -q -m "$msg"
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push -q origin "HEAD:refs/heads/$b"
  git -C "$d" worktree remove --force "$wt"
  git -C "$d" fetch -q origin "$b"
  printf '%s' "$sha"
}
# Put a patch-identical copy of <sha> on remote branch <b>: a different commit id
# carrying the same change, which is exactly what a rebase merge leaves behind.
copyonto() {
  local d="$1" b="$2" sha="$3" wt
  wt="$(mktemp -d)/wt"
  git -C "$d" fetch -q origin "$b"
  git -C "$d" worktree add -q --detach "$wt" "origin/$b"
  git -C "$wt" cherry-pick "$sha" >/dev/null
  git -C "$wt" push -q origin "HEAD:refs/heads/$b"
  git -C "$d" worktree remove --force "$wt"
  git -C "$d" fetch -q origin "$b"
}
# Merge <src> into remote branch <b> with a real merge commit, the way
# `gh pr merge --merge` does. The node it leaves on <b> is the promotion residue
# every later cascade has to tolerate.
mergeonto() {
  local d="$1" b="$2" src="$3" msg="$4" wt
  wt="$(mktemp -d)/wt"
  git -C "$d" fetch -q origin "$b" "$src"
  git -C "$d" worktree add -q --detach "$wt" "origin/$b"
  git -C "$wt" merge -q --no-ff -m "$msg" "origin/$src"
  git -C "$wt" push -q origin "HEAD:refs/heads/$b"
  git -C "$d" worktree remove --force "$wt"
  git -C "$d" fetch -q origin "$b"
}
setversion() {
  local d="$1" b="$2" v="$3" wt
  wt="$(mktemp -d)/wt"
  git -C "$d" fetch -q origin "$b"
  git -C "$d" worktree add -q --detach "$wt" "origin/$b"
  printf '%s\n' "$v" > "$wt/VERSION"
  git -C "$wt" add VERSION
  # Pinned dates: two branches seeded with the same version from the same base
  # must produce the SAME commit, so "level branches" is level by construction.
  # Left to the clock, the pair collides only when both land inside one second —
  # the assertion below was riding a hash collision it never asked for.
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
    git -C "$wt" commit -q -m "chore: seed version"
  git -C "$wt" push -q origin "HEAD:refs/heads/$b"
  git -C "$d" worktree remove --force "$wt"
  git -C "$d" fetch -q origin "$b"
}

echo "base resolution:"
d=$(newrepo)
(cd "$d" && bash "$SH" base >/dev/null 2>&1); check "no dev or develop refuses" "$?" 1

d=$(newrepo); mkbranch "$d" dev
check "dev resolves" "$(cd "$d" && bash "$SH" base 2>/dev/null)" "dev"

d=$(newrepo); mkbranch "$d" develop
check "develop resolves" "$(cd "$d" && bash "$SH" base 2>/dev/null)" "develop"

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" develop
check "dev wins over develop" "$(cd "$d" && bash "$SH" base 2>/dev/null)" "dev"

echo "preflight refusals:"
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b dev
(cd "$d" && bash "$SH" preflight >/dev/null 2>&1); check "refuses on dev" "$?" 1

d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b prod
(cd "$d" && bash "$SH" preflight >/dev/null 2>&1); check "refuses on prod" "$?" 1

d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q --detach
(cd "$d" && bash "$SH" preflight >/dev/null 2>&1); check "refuses detached HEAD" "$?" 1

d=$(mktemp -d)
(cd "$d" && bash "$SH" preflight >/dev/null 2>&1); check "refuses outside a repo" "$?" 1

d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q dev
(cd "$d" && bash "$SH" preflight --cascade >/dev/null 2>&1)
check "cascade without test/prod refuses" "$?" 1

echo "cascade branch rule:"
# --pr is what decides, not the branch alone. A pure cascade reads only origin/*
# refs and promotes the base as it stands, so the base is the ONE right place to
# run it from — and it is where `home` leaves you. These assert on the message
# rather than the exit code: preflight ends at `gh auth status`, so a genuinely
# clean run's exit code depends on whether this machine has a gh session.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test; mkbranch "$d" prod
git -C "$d" checkout -q dev
check "pure cascade from the base clears the branch check" \
  "$(cd "$d" && bash "$SH" preflight --cascade 2>&1 >/dev/null | grep -c 'on protected branch')" "0"

# --pr means a feature branch is being landed, and dev cannot PR into itself.
(cd "$d" && bash "$SH" preflight --cascade --pr >/dev/null 2>&1)
check "cascade --pr from the base refuses" "$?" 1
check "refusal names the pure-cascade exception" \
  "$(cd "$d" && bash "$SH" preflight --cascade --pr 2>&1 >/dev/null | grep -c 'pure cascade')" "1"

# Bare preflight from the base still refuses — the relaxation is cascade-only.
(cd "$d" && bash "$SH" preflight >/dev/null 2>&1)
check "bare preflight from the base still refuses" "$?" 1

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test; mkbranch "$d" prod
git -C "$d" checkout -q -b feat/cascade
(cd "$d" && bash "$SH" preflight --cascade >/dev/null 2>&1)
check "pure cascade from a feature branch refuses" "$?" 1
# The fix has to be in the message: --pr is the flag that makes this branch legal.
check "refusal names --pr as the fix" \
  "$(cd "$d" && bash "$SH" preflight --cascade 2>&1 >/dev/null | grep -c '\-\-pr')" "1"
check "cascade --pr from a feature branch clears the branch check" \
  "$(cd "$d" && bash "$SH" preflight --cascade --pr 2>&1 >/dev/null | grep -c 'pure cascade')" "0"

# Flags are parsed, not positional: an unknown one is a typo, not a no-op.
(cd "$d" && bash "$SH" preflight --casacde >/dev/null 2>&1)
check "unknown preflight flag refuses" "$?" 1
check "flag order does not matter" \
  "$(cd "$d" && bash "$SH" preflight --pr --cascade 2>&1 >/dev/null | grep -c 'pure cascade')" "0"

echo "downstream integrity gate:"
# A hotfix committed straight onto test: real content living only downstream.
# The promotion PR shows only dev's side, so nobody reviewing it sees this.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test; mkbranch "$d" prod
git -C "$d" checkout -q dev
onbranch "$d" test "fix: hotfix straight onto test"
(cd "$d" && bash "$SH" preflight --cascade >/dev/null 2>&1)
check "own work on test refuses" "$?" 1
check "refusal reports the offending commit" \
  "$(cd "$d" && bash "$SH" preflight --cascade 2>&1 >/dev/null | grep -c 'hotfix straight onto test')" "1"

# The merge nodes a promotion leaves behind are commits test holds and dev does
# not — that is the NORMAL resting state under `--merge`, and the gate must not
# read it as drift. An earlier fast-forward-shaped gate failed exactly here, on
# the second cascade, and could never recover.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test; mkbranch "$d" prod
git -C "$d" checkout -q dev
onbranch "$d" dev "feat: work that landed on dev"
mergeonto "$d" test dev "Merge pull request #1 from x/dev"
(cd "$d" && bash "$SH" preflight --cascade >/dev/null 2>&1)
check "promotion merge nodes are allowed" "$?" 0
# And the node really is there — otherwise the check above passes vacuously.
check "test holds a merge dev lacks" \
  "$(git -C "$d" rev-list --merges --count origin/dev..origin/test)" "1"

# Rebase-merge residue: patch-identical copies of dev's own commits. Refused
# like real downstream work, but the FIX IS OPPOSITE — carrying these up would
# replay dev onto itself — so the message must not confuse the two.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test; mkbranch "$d" prod
git -C "$d" checkout -q dev
# TWO commits on dev, and only the second is copied. The first exists solely to
# move dev's tip, so the copy lands on a DIFFERENT PARENT and therefore gets a
# different sha. Copy the only commit instead and git rebuilds a byte-identical
# object — same parent, tree, author and date — so there is no duplicate to
# detect and this whole block passes while testing nothing.
onbranchfile "$d" dev "feat: first" a.txt >/dev/null
sha=$(onbranchfile "$d" dev "feat: second" b.txt)
copyonto "$d" test "$sha"
(cd "$d" && bash "$SH" preflight --cascade >/dev/null 2>&1)
check "duplicate copies refuse" "$?" 1
out=$(cd "$d" && bash "$SH" preflight --cascade 2>&1 >/dev/null)
check "duplicates are named as duplicates" "$(printf '%s' "$out" | grep -c 'duplicate commit')" "1"
check "duplicates are not called own work"  "$(printf '%s' "$out" | grep -c "carries")" "0"
check "duplicates are not sent up to dev"   "$(printf '%s' "$out" | grep -c 'Get it onto')" "0"

echo "status:"
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/x
(cd "$d" && bash "$SH" status dev >/dev/null 2>&1); check "clean + level exits 0" "$?" 0
check "reports behind 0" "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep '^behind:')" "behind: 0"
# A branch level with the base carries nothing — the post-integrate resting
# state, where every other signal reads green.
check "reports integrated when nothing to carry" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep -c '^integrated:')" "1"

git -C "$d" commit -q --allow-empty -m "work"
check "no integrated line when ahead" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep -c '^integrated:')" "0"

touch "$d/scratch.txt"
(cd "$d" && bash "$SH" status dev >/dev/null 2>&1); check "dirty tree exits 3" "$?" 3
check "dirty tree lists the path" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep -c 'scratch.txt')" "1"

d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/y
onbranch "$d" dev "upstream work"
check "counts commits behind" "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep '^behind:')" "behind: 1"

echo "promote:"
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
(cd "$d" && bash "$SH" promote dev test >/dev/null 2>&1); check "level branches exit 3" "$?" 3
check "level branches say nothing to promote" \
  "$(cd "$d" && bash "$SH" promote dev test 2>/dev/null | grep -c 'nothing to promote')" "1"

echo "release repair path:"
# When VERSION already matches, release must still be able to tag — a tag push
# fails on its own, and returning early made that unrepairable.
check "does not return before tagging" \
  "$(grep -cF 'release: %s already on %s' "$SH")" "1"
# The lookup must exclude merges. GitHub copies the PR title into the merge
# commit's BODY, so a bare --grep finds the merge node first and tags that
# instead of the release commit.
check "release lookup excludes merges" \
  "$(grep -cF "format='%H' --no-merges" "$SH")" "1"
check "release lookup asserts the exact subject" \
  "$(grep -cF '= "chore(release): $version" ]' "$SH")" "1"

echo "tag annotation:"
# The tag is seeded from annotfile, NOT msgfile. `git tag -n1` prints only the
# first line, so seeding from the cascade PR body made the release index read
# "v0.1.0  chore(cascade): dev -> test" — the hop, not the release.
check "the annotation is seeded from annotfile" \
  "$(grep -cF 'annot=$(mktemp); cat "$annotfile" > "$annot"' "$SH")" "1"
check "annotfile defaults to msgfile when omitted" \
  "$(grep -cF 'local annotfile="${3:-$msgfile}"' "$SH")" "1"
check "an empty annotation file is refused" \
  "$(grep -cF 'tag annotation file is empty' "$SH")" "1"
# The PR link is appended by release, never by the caller — the number does not
# exist when the message file is written. Asserting the source because the live
# path needs GitHub; what must not drift is WHO writes the line.
# The link must point at the PRs that carried the WORK. The release's own PR
# changes one line of VERSION and answers nothing about what shipped.
check "annotation links the work PRs" \
  "$(grep -cF "sed -n 's/^Merge pull request #" "$SH")" "1"
check "the release's own PR is excluded" \
  "$(grep -cF 'grep -vx "$pr"' "$SH")" "1"
check "each link carries the PR title" \
  "$(grep -cF -- "--json url,title -q '.url + \" — \" + .title'" "$SH")" "1"

# Manifest sync, in the release commit itself.
check "package.json is versioned in the same commit" \
  "$(grep -cF 'npm --prefix "$wt" version "$version" --no-git-tag-version' "$SH")" "1"
check "the lockfile is staged too" \
  "$(grep -cF 'git -C "$wt" add package-lock.json' "$SH")" "1"
check "a missing npm refuses rather than shipping a stale manifest" \
  "$(grep -cF 'package.json is present but npm is not installed' "$SH")" "1"
# `-F` defaults to --cleanup=strip, which deletes lines starting with `#` — and
# the body's headings are `### Summary` / `### Commits`. `whitespace` fixes that
# but still eats the trailing blank line, so only `verbatim` satisfies both.
check "the tag is built from the appended file, not the caller's" \
  "$(grep -cF 'git tag -a "v$version" "$sha" --cleanup=verbatim -F "$annot"' "$SH")" "1"
# Proven against real git, not just asserted in the source. Three modes, and
# only one preserves BOTH the heading and the trailing blank line.
d=$(newrepo)
printf '### Head\n\nbody\n\n' > "$d/m.txt"
git -C "$d" tag -a striptag HEAD -F "$d/m.txt"
git -C "$d" tag -a wstag    HEAD --cleanup=whitespace -F "$d/m.txt"
git -C "$d" tag -a verbtag  HEAD --cleanup=verbatim   -F "$d/m.txt"
heading() { git -C "$d" tag -l --format='%(contents)' "$1" | grep -c '^### Head$'; }
# Count lines in the RAW tag object, not in %(contents): for-each-ref appends a
# newline of its own, so a `tail -1` probe reads empty for every mode and
# "verbatim kept the blank line" passes vacuously.
msglines() { git -C "$d" cat-file tag "$1" | sed '1,/^$/d' | wc -l | tr -d ' '; }
check "default -F strips # headings"            "$(heading striptag)"  "0"
check "whitespace keeps the heading"            "$(heading wstag)"     "1"
check "whitespace eats the trailing blank line" "$(msglines wstag)"    "3"
check "verbatim keeps the heading"              "$(heading verbtag)"   "1"
check "verbatim keeps the trailing blank line"  "$(msglines verbtag)"  "4"
# ...and verbatim is still not enough on GitHub, which trims ASCII whitespace off
# both ends before rendering. The terminator has to be a character that survives
# that trim, so it is U+00A0, not a newline.
check "the annotation is terminated with a non-breaking space" \
  "$(grep -cF '302\240' "$SH")" "1"
printf 'subject\n\nbody\n\302\240\n' > "$d/nb.txt"
git -C "$d" tag -a nbtag HEAD --cleanup=verbatim -F "$d/nb.txt"
# strip only ASCII whitespace, exactly what a server-side render does before
# emitting HTML. A bare trailing newline vanishes here; the NBSP does not.
trimmed() { git -C "$d" cat-file tag "$1" | sed '1,/^$/d' \
            | python3 -c 'import sys;sys.stdout.write(sys.stdin.read().strip(" \t\r\n")[-1:])' | od -An -tx1 | tr -d ' '; }
check "verbatim's trailing newline does NOT survive the trim" "$(trimmed verbtag)" "79"
check "the non-breaking space does survive the trim"          "$(trimmed nbtag)"   "c2a0"
check "a failed gh pr view degrades to the bare number, never fails the release" \
  "$(grep -cF 'line="#$n"' "$SH")" "1"

echo "merge method:"
# One method, everywhere. --rebase and --squash both rebuild commits, which
# leaves every surviving branch pointing at work the target will never hold.
check "only --merge is ever passed to gh" \
  "$(grep -c 'gh pr merge .* --\(rebase\|squash\)' "$SH")" "0"
check "integrate merges with --merge" \
  "$(grep -c 'gh pr merge "\$pr" --merge' "$SH")" "2"

echo "integrate:"
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/i
git -C "$d" commit -q --allow-empty -m "feat: work"
# Pushed, because the real flow pushes at step 4 and integrates at step 6. An
# unpushed branch has no origin/ ref and is refused earlier, for a reason that
# has nothing to do with the PR this block is about.
git -C "$d" push -q origin feat/i
# Landing goes through `gh pr merge --rebase`, so integrate REQUIRES an open PR
# and can no longer write to the base itself. A local fixture has no GitHub, so
# what is asserted here is the refusal — the merge path needs a live repo and is
# covered by the end-to-end run, not by this suite.
(cd "$d" && bash "$SH" integrate feat/i dev >/dev/null 2>&1)
check "integrate without an open PR refuses" "$?" 1
# Two distinct refusals, both correct and both write nothing: "cannot list PRs"
# (GitHub unreachable — what a file-path fixture remote produces) and "no open
# PR" (reachable, none found). Assert the refusal, not which one.
check "refusal is about the PR" \
  "$(cd "$d" && bash "$SH" integrate feat/i dev 2>&1 | grep -ci 'PR')" "1"
check "integrate wrote nothing to the base" \
  "$(git -C "$d" rev-parse origin/dev)" "$(git -C "$d" rev-parse origin/dev@{0})"

# The race: base moves while CI runs. The plain push must be refused and NOTHING
# written — this rejection is the whole concurrency story.
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/race
git -C "$d" commit -q --allow-empty -m "feat: mine"
onbranch "$d" dev "someone else landed first"
devwas=$(git -C "$d" rev-parse origin/dev)
(cd "$d" && bash "$SH" integrate feat/race dev >/dev/null 2>&1)
check "refuses when base moved" "$?" 1
git -C "$d" fetch -q origin dev
check "refused integrate wrote nothing" "$(git -C "$d" rev-parse origin/dev)" "$devwas"

d=$(newrepo); mkbranch "$d" dev
(cd "$d" && bash "$SH" integrate nope/nothing dev >/dev/null 2>&1); check "unknown ref refuses" "$?" 1

# The source is resolved as origin/$src, never the bare name. GitHub merges what
# is ON ORIGIN, so a local branch of the same name is not what lands — and for
# `dev` the two routinely disagree, because the cascade promotes dev without
# ever checking it out, leaving refs/heads/dev stale enough to shadow
# refs/remotes/origin/dev in rev-parse and make the tree report read false.
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/local-only
git -C "$d" commit -q --allow-empty -m "feat: never pushed"
(cd "$d" && bash "$SH" integrate feat/local-only dev >/dev/null 2>&1)
check "source absent from origin refuses" "$?" 1
check "refusal names the origin ref" \
  "$(cd "$d" && bash "$SH" integrate feat/local-only dev 2>&1 \
     | grep -c 'origin/feat/local-only')" "1"

echo "home:"
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/landed
onbranch "$d" dev "fix: landed while you were on the feature branch"
check "returns to the base" \
  "$(cd "$d" && bash "$SH" home dev >/dev/null 2>&1; git -C "$d" symbolic-ref --short HEAD)" \
  "dev"
# The fast-forward is the point: a base left at its stale local tip is a branch
# that only looks like origin/dev, which is what cmd_integrate refuses to trust.
check "base is fast-forwarded to origin" \
  "$(git -C "$d" rev-parse HEAD)" "$(git -C "$d" rev-parse origin/dev)"

d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/dirty
printf 'wip\n' > "$d/scratch.txt"
(cd "$d" && bash "$SH" home dev >/dev/null 2>&1); check "dirty tree exits 3" "$?" 3
check "dirty tree stays on the feature branch" \
  "$(git -C "$d" symbolic-ref --short HEAD)" "feat/dirty"

# A local dev that has drifted is the trap, not an inconvenience: every later
# rev-parse in a cascade would read it instead of origin/dev.
d=$(newrepo); mkbranch "$d" dev
git -C "$d" fetch -q origin dev
git -C "$d" checkout -q -b dev origin/dev
git -C "$d" commit -q --allow-empty -m "chore: committed straight onto local dev"
git -C "$d" checkout -q -b feat/other
(cd "$d" && bash "$SH" home dev >/dev/null 2>&1); check "drifted local base refuses" "$?" 1

echo "bump:"
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 0.3.2
setversion "$d" test 0.3.2
onbranch "$d" dev "fix: a thing"
check "fix bumps patch" "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.3.3 patch"

onbranch "$d" dev "feat: a bigger thing"
check "feat outranks fix" "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.4.0 minor"

# SemVer 0.x: breaking changes bump minor. Crossing to 1.0.0 is a decision.
onbranch "$d" dev "refactor!: drop the old surface"
check "breaking below 1.0.0 bumps minor" \
  "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.4.0 minor"

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 1.4.0; setversion "$d" test 1.4.0
onbranch "$d" dev "refactor!: drop the old surface"
check "breaking at or above 1.0.0 bumps major" \
  "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "1.4.0 2.0.0 major"

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 0.3.2; setversion "$d" test 0.3.2
onbranch "$d" dev "docs: explain the thing"
onbranch "$d" dev "chore: tidy up"
# Every promotion cuts a version. Leaving a chore-only range untagged made
# `git describe` name a release the branch had already moved past.
check "docs and chore only still bumps patch" \
  "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.3.3 patch"

# The types that fell through to `none` and shipped invisibly. revert: undoes
# behaviour users can observe; build: can move an engine floor or a pin.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 0.3.2; setversion "$d" test 0.3.2
onbranch "$d" dev "revert: back out the pagination change"
check "revert bumps patch" "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.3.3 patch"

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 0.3.2; setversion "$d" test 0.3.2
onbranch "$d" dev "build: raise the node engine floor to 22"
check "build bumps patch" "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.3.3 patch"

# feat still outranks a chore sharing the range — highest type wins, and now
# that everything bumps, the precedence is the ONLY thing keeping a feature
# from shipping as a patch.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 0.3.2; setversion "$d" test 0.3.2
onbranch "$d" dev "chore: tidy up"
onbranch "$d" dev "feat: add the thing"
check "feat still outranks chore" "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "0.3.2 0.4.0 minor"

# `none` now means exactly one thing: nothing to promote. This is the only
# surviving path to it, so it is the only thing standing between an empty
# cascade and a version cut for no commits at all.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
check "an empty range is the ONLY none" "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "none"

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
setversion "$d" dev 0.3.2; setversion "$d" test 0.3.2
check "level branches with a VERSION are still none" \
  "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "none"

d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
onbranch "$d" dev "feat: work with no VERSION file"
# An absent VERSION seeds rather than refusing — a repo needs a floor before
# anything can be incremented from it.
(cd "$d" && bash "$SH" bump dev test >/dev/null 2>&1); check "missing VERSION exits 0" "$?" 0
check "missing VERSION seeds 0.1.0" \
  "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "(absent) 0.1.0 initial"

# The seed ignores the commit kinds in the range: with no existing number there
# is nothing to increment, so they cannot influence the result. It reports
# `initial`, not a computed kind — the one bump that is not arithmetic.
d=$(newrepo); mkbranch "$d" dev; mkbranch "$d" test
onbranch "$d" dev "docs: readme only, still no VERSION file"
check "docs-only also seeds 0.1.0" \
  "$(cd "$d" && bash "$SH" bump dev test 2>/dev/null)" "(absent) 0.1.0 initial"

echo "release:"
d=$(newrepo); mkbranch "$d" dev
setversion "$d" dev 0.3.2
git -C "$d" checkout -q -b feat/r
msg=$(mktemp); printf 'chore(cascade): dev → test\n\nPromotes 1 commit.\n' > "$msg"
branchwas=$(git -C "$d" rev-parse HEAD)
# The release commit now lands via branch -> PR -> rebase merge, so release
# cannot complete without GitHub. A fixture remote is a file path, so what is
# asserted here is everything up to the PR — and, most importantly, that a
# failure at the PR step leaves the protected branch untouched.
devwas=$(git -C "$d" rev-parse origin/dev)
(cd "$d" && bash "$SH" release 0.4.0 "$msg" >/dev/null 2>&1)
check "release without GitHub refuses" "$?" 1
check "release branch was pushed" \
  "$(git -C "$d" log -1 --format='%s' origin/release/v0.4.0 2>/dev/null)" "chore(release): 0.4.0"
check "release branch carries the new VERSION" \
  "$(git -C "$d" show origin/release/v0.4.0:VERSION 2>/dev/null | tr -d '[:space:]')" "0.4.0"

# The rule the whole design rests on: no clone writes to a protected branch.
git -C "$d" fetch -q origin dev
check "dev was NOT written to" "$(git -C "$d" rev-parse origin/dev)" "$devwas"
check "no tag created before the merge landed" "$(git -C "$d" tag -l v0.4.0)" ""

# Decision 5, mechanised: the user must end where they started.
check "working tree untouched — still on feat/r" \
  "$(git -C "$d" symbolic-ref --short HEAD)" "feat/r"
check "feat/r did not move" "$(git -C "$d" rev-parse HEAD)" "$branchwas"
check "no worktree left behind even on the failure path" \
  "$(git -C "$d" worktree list | wc -l | tr -d ' ')" "1"

d=$(newrepo); mkbranch "$d" dev
(cd "$d" && bash "$SH" release 0.4 "$msg" >/dev/null 2>&1); check "rejects non-semver version" "$?" 1
empty=$(mktemp)
(cd "$d" && bash "$SH" release 0.4.0 "$empty" >/dev/null 2>&1); check "rejects empty tag message" "$?" 1

echo "remote divergence:"
# Level with the base, clean tree, and a rejected push. Amend AFTER pushing, so
# origin/<branch> holds a commit HEAD does not — base-relative numbers read green.
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/z
git -C "$d" commit -q --allow-empty -m "work"
git -C "$d" push -q origin feat/z
git -C "$d" commit -q --amend --allow-empty -m "work, amended"
check "diverged branch still reports behind 0" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep '^behind:')" "behind: 0"
check "diverged branch is reported" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep -c '^remote: DIVERGED')" "1"
check "plain push refuses a diverged remote" \
  "$(cd "$d" && bash "$SH" push >/dev/null 2>&1; echo $?)" "1"
(cd "$d" && bash "$SH" push --force >/dev/null 2>&1); check "--force lands it" "$?" 0
check "remote level after force" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep -c '^remote: level')" "1"

d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/new
check "unpushed branch reports absent" \
  "$(cd "$d" && bash "$SH" status dev 2>/dev/null | grep -c '^remote: absent')" "1"

# Force is decided by what is PUBLISHED, not by whether a rebase ran. Nothing
# published means nothing to rewrite, and the user's approval must not be spent.
git -C "$d" commit -q --allow-empty -m "first work"
check "--force on an unpublished branch downgrades" \
  "$(cd "$d" && bash "$SH" push --force 2>/dev/null | grep -c 'force not needed')" "1"
check "downgraded push still landed the branch" \
  "$(git -C "$d" rev-parse feat/new)" "$(git -C "$d" rev-parse origin/feat/new 2>/dev/null)"

# A wrong upstream is what made a bare `git push` a gamble: push.default decides
# where it lands, and it is not always <branch>.
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/up
git -C "$d" branch -q --set-upstream-to=origin/dev feat/up
# Pinned, not inherited: under push.default=upstream a bare `git push` sends
# HEAD to DEV. The host's own setting decides whether that happens, so the
# fixture names the dangerous one rather than testing whatever is installed.
git -C "$d" config push.default upstream
devwas=$(git -C "$d" rev-parse origin/dev)
git -C "$d" commit -q --allow-empty -m "feature work"
(cd "$d" && bash "$SH" push >/dev/null 2>&1); check "push with upstream=dev exits 0" "$?" 0
check "push wrote origin/feat/up" \
  "$(git -C "$d" rev-parse feat/up)" "$(git -C "$d" rev-parse origin/feat/up 2>/dev/null)"
check "push did NOT write dev" "$(git -C "$d" rev-parse origin/dev)" "$devwas"
check "push repaired the upstream" \
  "$(git -C "$d" config --get branch.feat/up.merge)" "refs/heads/feat/up"

d=$(newrepo)
(cd "$d" && bash "$SH" push --wat >/dev/null 2>&1); check "rejects unknown push flag" "$?" 1

# `push` is reachable without preflight — a retry, a caller that skips a step.
# The refusal has to live at the write, not only in the check that precedes it.
# main and master are in the list because the guard reads branches.protected now.
# A literal `dev|develop|test|prod` here waved them through, so a repo whose base
# is `main` could be pushed to directly by a `push` that skipped preflight.
for b in dev develop test prod main master; do
  d=$(newrepo); mkbranch "$d" dev
  git -C "$d" checkout -q -B "$b"
  git -C "$d" commit -q --allow-empty -m "work on a protected branch"
  was=$(git -C "$d" rev-parse origin/dev)
  (cd "$d" && bash "$SH" push >/dev/null 2>&1); check "push refuses from $b" "$?" 1
  check "push from $b left dev untouched" "$(git -C "$d" rev-parse origin/dev)" "$was"
done

# --force-with-lease is only a guarantee if the expected value is FRESH. With a
# stale origin/<b> the bare form compares the tracking ref to itself, agrees,
# and overwrites a commit that was never fetched. Fixture: someone else pushes
# to the feature branch while this clone's tracking ref stays behind.
d=$(newrepo); mkbranch "$d" dev
git -C "$d" checkout -q -b feat/lease
git -C "$d" commit -q --allow-empty -m "mine"
git -C "$d" push -q origin HEAD:refs/heads/feat/lease
# A SEPARATE CLONE, not a worktree. A worktree shares this repo's refs, so its
# push would update our own origin/feat/lease — that is "I pushed", not "someone
# else did", and the lease would rightly permit it.
other="$(mktemp -d)/other"
git clone -q "$(git -C "$d" remote get-url origin)" "$other"
git -C "$other" config user.email o@o.o; git -C "$other" config user.name o
git -C "$other" checkout -q -B feat/lease origin/feat/lease
git -C "$other" commit -q --allow-empty -m "theirs — pushed from elsewhere"
git -C "$other" push -q origin feat/lease:refs/heads/feat/lease
theirs=$(git -C "$other" rev-parse HEAD)
# This clone has NOT fetched, so origin/feat/lease still points at "mine".
git -C "$d" commit -q --allow-empty -m "amended work"
(cd "$d" && bash "$SH" push --force >/dev/null 2>&1)
check "stale lease refuses the force-push" "$?" 1
# Ask the OTHER clone what survived — this one still cannot see their object.
git -C "$other" fetch -q origin
check "their commit still on origin" \
  "$(git -C "$other" rev-parse origin/feat/lease)" "$theirs"

echo "rebase:"
# Conflicts must LEAVE THE REBASE IN PROGRESS — aborting would discard the
# commits that already applied cleanly.
d=$(newrepo); mkbranch "$d" dev
printf 'one\n' > "$d/f.txt"; git -C "$d" add f.txt
git -C "$d" commit -q -m "seed"; git -C "$d" push -q origin HEAD:refs/heads/dev
git -C "$d" fetch -q origin dev
git -C "$d" checkout -q -b feat/conflict
printf 'mine\n' > "$d/f.txt"; git -C "$d" commit -q -am "feat: mine"
wt="$(mktemp -d)/wt"
git -C "$d" worktree add -q --detach "$wt" origin/dev
printf 'theirs\n' > "$wt/f.txt"
git -C "$wt" commit -q -am "feat: theirs"
git -C "$wt" push -q origin HEAD:refs/heads/dev
git -C "$d" worktree remove --force "$wt"
git -C "$d" fetch -q origin dev
(cd "$d" && bash "$SH" rebase dev >/dev/null 2>&1); check "conflicting rebase exits non-zero" "$?" 1
rebasing=no
if [ -d "$d/.git/rebase-merge" ] || [ -d "$d/.git/rebase-apply" ]; then rebasing=yes; fi
check "rebase left in progress" "$rebasing" "yes"
check "conflicted file is named" \
  "$(cd "$d" && bash "$SH" rebase dev 2>&1 >/dev/null | grep -c 'f.txt')" "1"
git -C "$d" rebase --abort 2>/dev/null

echo "usage:"
d=$(newrepo)
(cd "$d" && bash "$SH" >/dev/null 2>&1); check "no subcommand refuses" "$?" 1
(cd "$d" && bash "$SH" merge 1 rebase >/dev/null 2>&1); check "merge is gone" "$?" 1

echo "branch vocabulary from config"
cfgrepo=$(mktemp -d); mkdir -p "$cfgrepo/docs/iso"
( cd "$cfgrepo" && git init -q -b main . )
printf '%s\n' '{"branches":{"development":"trunk"}}' > "$cfgrepo/docs/iso/config.json"
out=$( cd "$cfgrepo" && ISO_GLOBAL_CONFIG=/nonexistent bash "$SH" development-branch )
check "overlay renames development" "$out" "trunk"

out=$( cd "$cfgrepo" && rm -f docs/iso/config.json && ISO_GLOBAL_CONFIG=/nonexistent bash "$SH" development-branch )
check "default when no overlay" "$out" "dev"

# ------------------------------------------------------------------ ticket
# The tracker links a PR to its ticket by finding the identifier in the title.
# `pr` is find-or-create, so this decision is re-taken on every re-run: what
# must hold is that a second run never prepends a second copy, and that a title
# naming some OTHER ticket still gets its own.
. "$SH" >/dev/null 2>&1 || true
set +e   # push.sh runs under `set -e`; sourcing it must not abort the suite

echo "the body is left alone"
# The body carried `Closes <key>` until the title took the job over. Asserted as
# an absence because a helper that quietly comes back is invisible otherwise:
# a second link to the same ticket, and one that would also flip merge-to-Done
# back on without anyone choosing it.
type body_with_ticket >/dev/null 2>&1 \
  && bad "body_with_ticket is back — the body must carry no ticket line" \
  || ok "nothing writes a ticket line into the body"
# Anchored at `^[^#]*` so the match must begin before any comment marker on the
# line: the comments in push.sh explain the close intent at length and would
# otherwise fail their own assertion.
grep -qE "^[^#]*(printf|--body)[^#]*Closes" "$SH" \
  && bad "push.sh emits a close intent again" \
  || ok "no close intent is emitted"

echo "ticket in the title"
check "no ticket, title untouched" "$(title_with_ticket 'feat: a thing' '')" "feat: a thing"
check "a ticket is prefixed" \
  "$(title_with_ticket 'feat: a thing' 'FIRE-9')" "FIRE-9 feat: a thing"
check "a title already naming it is left alone" \
  "$(title_with_ticket 'FIRE-9 feat: a thing' 'FIRE-9')" "FIRE-9 feat: a thing"
# Anywhere in the title links, so anywhere satisfies the check - prefixing a
# second copy would be noise, not a fix.
check "the key mid-title also counts" \
  "$(title_with_ticket 'revert FIRE-9 changes' 'FIRE-9')" "revert FIRE-9 changes"
check "another ticket in the title is not this link" \
  "$(title_with_ticket 'supersedes FIRE-3' 'FIRE-9')" "FIRE-9 supersedes FIRE-3"

# The cascade gate: a hop's head is development or test, and those carry no
# ticket. cmd_pr skips the lookup entirely for them.
iso_is_protected dev && ok "development is protected, so a cascade hop skips it" \
  || bad "development not protected: cascade hops would resolve a ticket"


echo "rescue rebinds the ticket"
export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)
r=$(newrepo)
git -C "$r" checkout -q -b dev
git -C "$r" push -q origin dev
git -C "$r" commit -q --allow-empty -m "feat(auth): add token refresh"

# Record what rescue asks the tracker to do, without a real tracker.
BINR=$(mktemp -d)
cat > "$BINR/tracking.sh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$TRACK_CALLS"
STUB
chmod +x "$BINR/tracking.sh"
# Outside the repo: a file inside it is a dirty tree, which rescue refuses.
export TRACK_CALLS="$BINR/calls"; : > "$TRACK_CALLS"

new=$( cd "$r" && ISO_TRACKING_SH="$BINR/tracking.sh" bash "$SH" rescue dev )
check "named from the commit subject" "$new" "feat/auth-add-token-refresh"
check "landed on it" "$(git -C "$r" branch --show-current)" "feat/auth-add-token-refresh"
check "dev reset back to origin" \
  "$(git -C "$r" rev-parse dev)" "$(git -C "$r" rev-parse origin/dev)"
grep -q 'rebranch dev feat/auth-add-token-refresh' "$TRACK_CALLS" \
  && ok "ticket rebound off dev" || bad "rescue did not rebind the ticket"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

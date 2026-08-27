#!/usr/bin/env bash
# iso-push mechanics: preflight, base resolution, rebase, push, PR, CI, integrate,
# version bump, release. Message authoring lives in SKILL.md — this script never
# writes prose.
#
# One idea holds the whole design together: a NON-FORCE push is a compare-and-swap.
# Git moves a ref only forward along its own history, so `push <sha>:refs/heads/dev`
# succeeds only when dev is an ancestor of that sha, and is rejected otherwise
# without writing anything. Every "is it safe to merge" question is answered
# atomically by the remote instead of by this script guessing beforehand.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/track.sh)"

die() { printf 'iso-push: %s\n' "$1" >&2; exit 1; }

# Branch vocabulary. Read once — every lookup is a jq pass, and this file runs
# dozens of them per invocation otherwise.
DEVELOPMENT=$(iso_config_get branches.development)
TEST_BRANCH=$(iso_config_get branches.test)
PRODUCTION=$(iso_config_get branches.production)
PR_BASE=$(iso_config_get branches.pr_base)

cmd_development_branch() { printf '%s\n' "$DEVELOPMENT"; }

# Membership against branches.protected now lives in iso-config's branch.sh as
# iso_is_protected — iso-write carried a second copy of the same loop, under a
# different name. push.sh's own gates stay role-specific (production refuses,
# development has a cascade exemption); this is the plain "may I work here?".

# --------------------------------------------------------------------- base
# The integration branch a feature PR targets. dev wins when both exist.
# Hard requirement: no dev/develop means this repo has no governance layout.
cmd_base() {
  local b
  for b in "$DEVELOPMENT" develop; do
    if git ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1; then
      printf '%s\n' "$b"; return 0
    fi
  done
  die "no dev or develop branch on origin — run /iso-init-repo first"
}

# ------------------------------------------------------- downstream integrity
# A promotion MERGES <from> into <to>, so <to> is expected to hold commits <from>
# lacks — one merge node per past promotion. Those carry no content, and
# asserting their absence (as an earlier fast-forward-shaped gate did) would fail
# on the second cascade and never recover.
#
# What must never appear is a NON-MERGE commit on <to> that <from> does not have:
# a hotfix committed straight onto test or prod. That is real content living only
# downstream. The promotion PR shows only <from>'s side, so nobody reviewing it
# sees the divergence, and it widens at every rung.
#
# This is an ENVIRONMENT defect, not a push problem, so the remedy is the skill
# that owns environment shape.
assert_no_own_work() {
  local to="$1" from="$2" own dupes
  own=$(git rev-list --no-merges --count "origin/$from..origin/$to")
  [ "$own" -eq 0 ] && return 0

  # Two very different problems look identical to `rev-list`. `git cherry` tells
  # them apart: it marks a commit `-` when the upstream already holds a
  # patch-equivalent one. All `-` means these are not downstream work at all,
  # they are rebuilt copies left behind by a rebase or squash merge — and the
  # fixes are opposite. Real work must be carried UP to <from>; duplicates must
  # be DISCARDED. Telling someone to merge duplicates into dev would replay
  # dev's own commits back onto it.
  dupes=$(git cherry "origin/$from" "origin/$to" | grep -c '^-' || true)
  {
    if [ "$dupes" -eq "$own" ]; then
      printf "iso-push: '%s' holds %s duplicate commit(s) of work already on '%s'.\n\n" \
        "$to" "$own" "$from"
      git --no-pager log --no-merges --format='    %h %s' "origin/$from..origin/$to"
      printf '\n  Every one is patch-identical to a commit %s already has. These are\n' "$from"
      printf '  rebuilt copies left by a rebase or squash merge, not new work —\n'
      printf '  do NOT carry them up, that would replay %s onto itself.\n' "$from"
      printf '  Promotions merge now, so this cannot recur, but the existing copies\n'
      printf '  must be discarded first: straighten the branches with /iso-init-repo.\n'
    else
      printf "iso-push: '%s' carries %s commit(s) of its own that '%s' lacks.\n\n" \
        "$to" "$own" "$from"
      git --no-pager log --no-merges --format='    %h %s' "origin/$from..origin/$to"
      printf '\n  Promotion only ever moves work downstream. A commit made directly on\n'
      printf '  %s is invisible to the promotion PR and drifts further at every rung.\n' "$to"
      printf '  Get it onto %s first, then re-run /iso-push --cascade.\n' "$from"
    fi
  } >&2
  exit 1
}

# ---------------------------------------------------------------- preflight
# Repo? On a branch? Not on a protected one? gh usable? Cascade branches present
# AND still linear? Echoes "<branch> <base>".

# Derive <type>/<slug> from the work that has to move off a protected branch.
#
# Named from the OLDEST commit above the base, not the newest: it is the one
# that started the branch, and a branch named after the last thing you happened
# to commit reads wrong the moment there are two.
#
# Same shape iso-write derives from a plan filename, for the same reason — a
# name you did not choose is a name you do not argue with, and every branch in
# the repo then sorts by type.
branch_name_from() {   # <base> -> <type>/<slug>
  local subject
  subject=$(git log --format=%s --no-merges "origin/$1..HEAD" 2>/dev/null | tail -1)
  [ -n "$subject" ] || return 1
  iso_branch_from_subject "$subject"
}

# Move commits off a protected branch onto a feature branch named after them.
#
# iso-push cannot push dev, test or prod — GitHub is their only writer — so a
# commit made while standing on one is stranded: not pushable from where it is,
# and invisible to a cascade, which promotes origin/* and never sees it. The
# refusal that used to happen here was correct and useless, because the only
# way forward was a `git reset --hard` typed by hand, which is exactly the
# operation nobody should be improvising at the end of a working session.
#
# ORDER IS THE SAFETY. The branch is created first, so every commit is
# reachable from a second ref before the reset moves anything. A reset that
# fails, or a terminal that dies between the two, leaves the work on the new
# branch either way.
#
# Refuses a dirty tree outright. --hard discards uncommitted changes and this
# function runs without being asked, so the one state where it could destroy
# something it cannot recreate is the one state it will not run in.
rescue_to_branch() {   # <protected-branch> -> echoes the new branch name
  local prot="$1" new

  [ -z "$(git status --porcelain)" ] \
    || die "'$prot' carries commits that have to move to a feature branch, but the working tree is dirty.
       Moving them resets '$prot' to origin/$prot, which would discard those changes.
       Commit or stash them, then run again."

  new=$(branch_name_from "$prot") \
    || die "cannot name a branch: no non-merge commit above origin/$prot"

  ! git rev-parse --verify --quiet "$new" >/dev/null \
    || die "would move the work to '$new', but that branch already exists.
       Check it out and merge, or rename it, then run again."

  git branch "$new"                      # reachable from two refs before anything moves
  git reset --hard "origin/$prot" >&2
  git checkout "$new" >&2
  # The ledger still names the protected branch here, which is exactly the
  # identifier that resolves the ticket.
  # Point the ticket at the branch the work was just moved to.
  iso_track rebranch "$prot" "$new" >/dev/null 2>&1
  printf '%s\n' "$new"
}

# Seam for the self-check: rescue_to_branch runs inside larger flows and a test
# needs a way in.
cmd_rescue() { rescue_to_branch "$@"; }

cmd_preflight() {
  local want_cascade= want_pr=
  while [ $# -gt 0 ]; do
    case "$1" in
      --cascade) want_cascade=1 ;;
      --pr)      want_pr=1 ;;
      *) die "preflight: unknown flag '$1'" ;;
    esac
    shift
  done

  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) \
    || die "detached HEAD — check out a branch before pushing"

  # test and prod are promoted INTO. Nothing is ever worked on there and no run
  # is ever driven from there, so they are refused unconditionally.
  #
  # dev is not the same case. A PURE cascade — --cascade with no --pr — promotes
  # dev exactly as it stands: it reads only origin/* refs, writes nothing to the
  # working tree, and has no feature branch in play at all. It is also precisely
  # where `home` leaves you at the end of the previous run. Refusing dev for it
  # made a documented invocation unreachable from the only branch you could be
  # standing on.
  #
  # So the rule splits on --pr, not on the branch alone: --pr means a feature
  # branch is being landed and dev is wrong; no --pr means dev is the only right
  # place. `set -e` is why these are `if` blocks and not `&&` chains inside the
  # case — an arm ending in a false test would exit the script.
  # A protected branch carrying its own commits is now RESCUED rather than
  # refused: rescue_to_branch names a branch after the work and moves it there.
  # See that function for why, and for the two states it still refuses in.
  #
  # `local` is deliberately not used for `branch` below — it is reassigned to
  # whatever we were moved onto, and everything after this point (cmd_base, the
  # echo at the end, and every caller reading that echo) has to see the new one.
  case "$branch" in
    "$TEST_BRANCH"|"$PRODUCTION")
      # No cascade exemption here, unlike dev. A cascade promotes INTO test and
      # prod, so standing on one is never the right place to drive a run from —
      # and a commit made there is the environment defect the later check
      # refuses anyway. Moving it to a feature branch is the documented remedy
      # for that defect, so doing it here just means it happens before the
      # refusal instead of after.
      if [ -n "$(git log --format=%H "origin/$branch..HEAD" 2>/dev/null)" ]; then
        branch=$(rescue_to_branch "$branch")
      else
        die "on protected branch '$branch' — iso-push runs from a feature branch"
      fi ;;
    "$DEVELOPMENT"|develop)
      if [ -z "$want_cascade" ] || [ -n "$want_pr" ]; then
        # Commits sitting here are stranded: unpushable from dev, and invisible
        # to a cascade, which reads origin/* only. Move them. With none, the
        # branch is a faithful copy of the remote and the invocation is simply
        # wrong — say so, as before.
        if [ -n "$(git log --format=%H "origin/$branch..HEAD" 2>/dev/null)" ]; then
          branch=$(rescue_to_branch "$branch")
        else
          die "on protected branch '$branch' — iso-push runs from a feature branch, except for a pure cascade (--cascade with no --pr), which promotes '$branch' as it stands"
        fi
      fi ;;
    *)
      if [ -n "$want_cascade" ] && [ -z "$want_pr" ]; then
        die "a pure cascade promotes the base as it stands and runs from it, not from '$branch' — add --pr to land this branch first, or check out the base"
      fi ;;
  esac

  local base; base=$(cmd_base)

  # Repo-shape checks run BEFORE the network auth probe: they are cheaper, more
  # specific, and failing on the most precise problem first reads better. It
  # also keeps them testable without a live gh session.
  if [ -n "$want_cascade" ]; then
    local b
    for b in test prod; do
      git ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1 \
        || die "--cascade needs a '$b' branch on origin — run /iso-init-repo first"
    done
    git fetch --quiet origin "$base" test prod
    assert_no_own_work test "$base"
    assert_no_own_work prod test
  fi

  gh auth status >/dev/null 2>&1 || die "gh not authenticated — run: gh auth login"

  printf '%s %s\n' "$branch" "$base"
}

# ------------------------------------------------------------------- status
# Four questions, because a push can fail on any of them: is the tree clean, are
# we behind the base, has the branch's own remote moved out from under us, and
# is there anything left to integrate at all.
#
# origin/<branch> is INVISIBLE from the base. It can hold a commit the base never
# took — an amend made after a push is the usual cause — and every base-relative
# number stays green right up to the moment the push is rejected non-fast-forward.
#
# Reports only; every line is a gate the skill clears with the user.
# Exit 3 = dirty tree, so the caller can branch without parsing.
cmd_status() {
  local base="${1:?usage: push.sh status <base>}" branch dirty behind ahead
  branch=$(git symbolic-ref --short HEAD)
  git fetch --quiet origin "$base"
  # A branch with no remote yet is a first push, not an error.
  git fetch --quiet origin "$branch" 2>/dev/null || true

  dirty=$(git status --porcelain)

  behind=$(git rev-list --count "HEAD..origin/$base")
  ahead=$(git rev-list --count "origin/$base..HEAD")

  printf 'behind: %s\n' "$behind"
  # `replay` lists YOUR commits, which a rebase would replay onto the new base —
  # so it needs ahead > 0, not just behind > 0. An integrated branch is behind by
  # its own merge commit while having nothing of its own left, and printing a
  # bare `replay:` header over an empty list reads like the list failed.
  if [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
    printf 'replay:\n'
    git --no-pager log --format='  %s' "origin/$base..HEAD"
  fi

  # ANCESTRY ANSWERS THIS, offline, because nothing is ever rewritten. `--merge`
  # keeps the branch's own commits — so once it lands, the branch is a genuine
  # ancestor of the base and has nothing left to carry.
  #
  # Under `--rebase` this line would be wrong forever: the base would hold only
  # rebuilt copies, `ahead` would never reach 0, and `behind` would count the
  # base's copies of this branch's own work. That is what forced an earlier
  # version to ask GitHub which PR had merged and then compare tree hashes.
  #
  # Without this the skill walks into `gh pr create` with nothing to open a PR
  # about. Being fully integrated is success, so it is a report, not an error.
  if [ "$ahead" -eq 0 ]; then
    printf 'integrated: nothing to carry, %s is at %s\n' "$base" \
      "$(git rev-parse --short "origin/$base")"
  fi

  if git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    local counts ours theirs
    counts=$(git rev-list --left-right --count "HEAD...origin/$branch")
    ours=${counts%%[[:space:]]*}; theirs=${counts##*[[:space:]]}
    if [ "$theirs" -eq 0 ]; then
      printf 'remote: level (ahead %s)\n' "$ours"
    else
      printf 'remote: DIVERGED (ours %s, theirs %s)\n' "$ours" "$theirs"
      printf 'theirs:\n'
      git --no-pager log --format='  %h %s' "HEAD..origin/$branch"
    fi
  else
    printf 'remote: absent (first push)\n'
  fi

  if [ -n "$dirty" ]; then
    printf 'uncommitted:\n%s\n' "$(printf '%s' "$dirty" | sed 's/^/  /')"
    return 3
  fi
  return 0
}

# ------------------------------------------------------------------- rebase
# Runs unattended. A rebase is recoverable by construction: clean gives linear
# history, conflict stops with everything reachable via --abort, and the
# pre-rebase tip stays in reflog either way. The irreversible step is never the
# rebase — it is the push that PUBLISHES its result, and that keeps its gate.
#
# On conflict this LEAVES THE REBASE IN PROGRESS and exits non-zero. Aborting
# would discard the commits that already applied cleanly and force both
# resolution paths to start over.
cmd_rebase() {
  local base="${1:?usage: push.sh rebase <base>}"
  if git rebase "origin/$base"; then
    # Report the BASE BY NAME and the NEW HEAD. `log -1 --format=... "$base"`
    # read both fields off the base commit, so it printed the base's subject
    # where the branch name belongs and the base's sha as "head now" — which
    # reads exactly like the rebase threw the replayed commits away.
    printf 'rebased onto origin/%s, head now %s\n' \
      "$base" "$(git rev-parse --short HEAD)"
    return 0
  fi
  {
    printf 'conflict: rebase onto origin/%s stopped, rebase LEFT IN PROGRESS\n' "$base"
    printf 'applying: %s\n' "$(git log -1 --format='%s' REBASE_HEAD 2>/dev/null || echo unknown)"
    printf 'files:\n'
    git diff --name-only --diff-filter=U | sed 's/^/  /'
  } >&2
  return 1
}

# --------------------------------------------------------------------- push
# FULLY QUALIFIED destination, always: `<branch>:refs/heads/<branch>`.
#
# Naming the source alone is not enough, and this is the sharp edge. A feature
# branch can carry an upstream of origin/DEV — `git checkout -b` sets it that
# way and nothing complains — and under push.default=upstream git then resolves
# an unqualified `git push origin <branch>` against that upstream:
#
#     $ git push -u origin feat/up          # upstream = origin/dev
#     ca797c6..741e406  feat/up -> dev      # onto DEV. measured, not theorised.
#
# The feature branch lands directly on the integration branch, skipping the PR,
# the CI gate and the review. `<branch>:refs/heads/<branch>` names the
# destination outright, so push.default has nothing left to decide. `-u` then
# repairs the bad upstream on the way past.
#
# --force REWRITES PUBLISHED HISTORY and is gated by the skill, every time. But
# whether it is NEEDED is decided here, by whether anything is published at all:
# rewriting a branch no one has ever seen needs no force and must not spend the
# user's approval on one.
cmd_push() {
  local force="${1:-}" branch
  branch=$(git symbolic-ref --short HEAD)

  # Repeated from cmd_preflight on purpose. `push` is its own subcommand and can
  # be reached without preflight ever running — a retry after a failed step, a
  # caller that improvises the order. Preflight is where this is EXPLAINED; here
  # it is the last thing standing between a wrong branch and a direct push to an
  # integration branch, so it is checked again at the point of the write.
  case "$branch" in
    dev|develop|test|prod)
      die "refusing to push protected branch '$branch' — landings go through gh pr merge";;
  esac

  if [ "$force" = "--force" ] && ! git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    printf 'push: origin/%s absent — plain push, force not needed\n' "$branch"
    force=""
  fi
  case "$force" in
    "")      git push -u origin "$branch:refs/heads/$branch" ;;
    --force)
      # NEVER fetch this branch before the lease. It reads as prudence and is
      # the exact opposite.
      #
      # --force-with-lease=<branch> expects the remote to still match the local
      # remote-tracking ref. That ref is a record of what this clone last SAW.
      # Someone else pushes, you have not fetched, the two disagree, the push is
      # rejected — the guarantee holding.
      #
      # Fetch first and you overwrite that record with their commit, the lease
      # then agrees with itself, and the force-push destroys work the flag exists
      # to protect. Measured: push.test.sh fails on exactly this if a fetch is
      # added here.
      git push --force-with-lease="$branch" -u origin "$branch:refs/heads/$branch" ;;
    *) die "push takes --force or nothing (got '$force')" ;;
  esac
}

# ------------------------------------------------------------------- ticket
# The tracker links a PR to its ticket by finding the identifier in the branch
# name, the title or the body. Branch names come from the plan filename and the
# title is what commitlint reads, so the body is the only place left.
#
# This must resolve BEFORE `integrate`: the retro that closes a ticket also
# drops its ledger row, and there is nothing left to look up afterwards.
#
# Silent when iso-issue-tracking is not installed — a repo with no tracker has no
# ticket to miss. One line on stderr when tracking answers but this branch has
# no row, because an unlinked PR otherwise looks exactly like a ticketless one.
ticket_key() {
  local key
  # No tracker installed is not a missing ticket, so it warns about nothing.
  [ -n "$(iso_track_path)" ] || return 0
  key=$(iso_track ticket-for-branch 2>/dev/null | cut -f1)
  [ -n "$key" ] || {
    printf 'iso-push: no ticket for this branch -- the PR stays unlinked\n' >&2
    return 0
  }
  printf '%s\n' "$key"
}

# The pure half, and the only half that can be quietly wrong: which key, or
# none. An empty key, or a body already naming it, comes back byte-identical so
# the caller can compare instead of deciding again — `pr` reuses an open PR, so
# this runs on every re-run.
body_with_ticket() {
  local body="$1" key="$2"
  [ -n "$key" ] || { printf '%s' "$body"; return 0; }
  case "$body" in *"$key"*) printf '%s' "$body"; return 0 ;; esac
  printf '%s\n\nTicket: %s' "$body" "$key"
}

# ----------------------------------------------------------------------- pr
# Find-or-create. Reuse matters: a re-run after a red build must not open a
# second PR for the same branch. Echoes the PR number.
cmd_pr() {
  local head="${1:?usage: push.sh pr <head> <base> <msgfile>}"
  local base="${2:?usage: push.sh pr <head> <base> <msgfile>}"
  local msgfile="${3:?usage: push.sh pr <head> <base> <msgfile>}"
  [ -s "$msgfile" ] || die "message file is empty: $msgfile"

  # Feature PRs only. A cascade hop's head is development or test, which carry
  # no ticket of their own, and the tickets they ship were closed at their own
  # merges — linking here would hang one ticket off two PRs.
  local key=""
  iso_is_protected "$head" || key=$(ticket_key)

  local n
  n=$(gh pr list --head "$head" --base "$base" --state open --json number --jq '.[0].number // empty')
  if [ -n "$n" ]; then
    # The body is written once, at create. A ticket bound after that — or this
    # very feature landing mid-flight — would never reach it. Append, never
    # rewrite: the rest of that body is someone's prose.
    if [ -n "$key" ]; then
      local cur new
      cur=$(gh pr view "$n" --json body --jq '.body // ""') || cur=""
      new=$(body_with_ticket "$cur" "$key")
      [ "$new" = "$cur" ] || gh pr edit "$n" --body "$new" >/dev/null
    fi
    printf '%s\n' "$n"; return 0
  fi

  local title body
  title=$(head -1 "$msgfile")
  body=$(tail -n +2 "$msgfile" | sed '1{/^$/d;}')
  gh pr create --base "$base" --head "$head" --title "$title" \
    --body "$(body_with_ticket "$body" "$key")" >/dev/null
  gh pr list --head "$head" --base "$base" --state open --json number --jq '.[0].number'
}

# ------------------------------------------------------------------- checks
# Gate an integrate on CI. Branch protection is unavailable on private repos on
# the free plan, so this is the only thing standing between a failing build and
# prod.
#
# "No checks" is AMBIGUOUS and that ambiguity is the dangerous part: it means
# either a repo with no CI, or a PR whose checks GitHub has not registered YET.
# Taking the second for the first passes a build nobody ran. `pr` and `checks`
# run back-to-back, so the window is hit routinely rather than rarely — it was
# hit on the first cascade this ran, on a PR whose gate then passed a second
# later.
#
# So re-ask before believing it. A repo genuinely without CI pays the full wait
# once per landing; that is the right side to be wrong on.
CHECKS_TRIES=5
CHECKS_SLEEP=4
cmd_checks() {
  local n="${1:?usage: push.sh checks <pr>}" out rc i waited=0
  for i in $(seq 1 "$CHECKS_TRIES"); do
    rc=0
    out=$(gh pr checks "$n" --watch 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && { printf 'checks: green\n'; return 0; }
    # Anything other than "no checks" is a real verdict — report it now.
    printf '%s' "$out" | grep -qi 'no checks' || break
    [ "$i" -eq "$CHECKS_TRIES" ] && {
      printf 'checks: none configured (none appeared in %ss)\n' "$waited"; return 0; }
    sleep "$CHECKS_SLEEP"
    waited=$((waited + CHECKS_SLEEP))
  done
  printf '%s\n' "$out" >&2
  printf 'checks: FAILED\n' >&2
  return 1
}

# ---------------------------------------------------------------- integrate
# Every landing is `gh pr merge`. No clone ever pushes to dev/test/prod, so the
# pre-push guard `iso-init-repo` installs stays a blanket refusal with no
# exception to argue about — which matters most on a private repo on GitHub
# Free, where branch protection returns 403 and that guard is all there is.
#
# ALWAYS --merge. Nothing in this flow is ever rewritten.
#
# --rebase and --squash both REBUILD the source's commits, producing a target
# that CONTAINS the work without DESCENDING from it. Two things break, and both
# are permanent:
#
#   1. The source branch is left pointing at commits the target will never hold.
#      Since no branch is ever deleted here, that is an orphan lane per branch,
#      forever — and for dev/test/prod, one more lane at every rung. Three rungs
#      once left four copies of every commit in this repo.
#   2. `origin/<dst>..origin/<src>` keeps listing commits that already landed,
#      so every later promotion re-proposes them and re-raises their conflicts.
#
# --merge rewrites nothing. The source's commits ARE the target's commits, the
# branch pointer becomes a label inside the target's history rather than a lane
# beside it, and ancestry stays true — which is what makes "what is left to
# promote" answerable at all. The cost is one merge commit per landing: a node
# that carries no content, and grows with the number of LANDINGS rather than
# with the number of commits.
#
# The ancestry is asserted after the merge, not assumed.
cmd_integrate() {
  local src="${1:?usage: push.sh integrate <src> <dst>}"
  local dst="${2:?usage: push.sh integrate <src> <dst>}"
  local pr dst_before

  # origin/, not the bare name: what lands is what is ON ORIGIN, and rev-parse
  # prefers refs/heads over refs/remotes. `dev` is the trap — the cascade
  # promotes it without ever checking it out, so a stale refs/heads/dev shadows
  # origin/dev. Fetch is best-effort; the rev-parse is the assertion, guarded
  # because set -e would turn "not on origin" into git's raw 128.
  git fetch --quiet origin "$src" "$dst" 2>/dev/null || true
  git rev-parse --verify --quiet "origin/$src^{commit}" >/dev/null \
    || die "unknown ref: origin/$src — push it before integrating"
  dst_before=$(git rev-parse "origin/$dst")

  # Resolve by head AND base — `gh pr merge <branch>` is ambiguous once a branch
  # has more than one open PR, which `dev` always does mid-cascade.
  pr=$(gh pr list --head "$src" --base "$dst" --state open --json number \
       -q '.[0].number') || die "cannot list PRs for $src -> $dst"
  [ -n "$pr" ] || die "no open PR for $src -> $dst — run 'push.sh pr' first"

  gh pr merge "$pr" --merge \
    || die "GitHub refused the merge of PR #$pr ($src -> $dst) — if the error names the
merge method, enable 'Allow merge commits' in the repo's settings; this skill
uses no other method. Otherwise resolve on GitHub, then re-run"

  git fetch --quiet origin "$dst"
  [ "$(git rev-parse "origin/$dst")" != "$dst_before" ] \
    || die "PR #$pr reported merged but '$dst' did not move — inspect before promoting"

  # The invariant the whole model rests on. If this fails the merge was NOT a
  # merge commit — someone changed the repo's default method, and every later
  # promotion would start re-proposing work that already landed.
  git merge-base --is-ancestor "origin/$src" "origin/$dst" \
    || die "'$src' is not an ancestor of '$dst' after PR #$pr — the merge rewrote
history. Check the repo's merge-method settings before promoting"

  printf 'integrated: %s -> %s at %s (%s is now an ancestor of %s)\n' \
    "$src" "$dst" "$(git rev-parse --short "origin/$dst")" "$src" "$dst"
}

# --------------------------------------------------------------------- home
# Put the working copy back on the base once something has landed.
#
# The flow used to end on a feature branch GitHub had already merged. Nothing
# will ever move that branch again, so the next commit made there starts a second
# head on a dead lane, and `git pull` fetches a ref frozen at the merge. Landing
# is the moment the feature branch stops being the place to work.
#
# A local `dev` carrying commits origin/dev lacks is the exact trap cmd_integrate
# documents at :358 — refs/heads/dev shadows origin/dev in every later rev-parse,
# so a cascade would read a branch that only LOOKS like the base.
#
# `--ff-only` alone does NOT catch that, and the comment here claimed it did.
# When the local branch is AHEAD, origin/<base> is already an ancestor, so the
# merge reports "already up to date" and exits 0 — the one shape most worth
# refusing is the one it waves through. Only the diverged case fails. So the
# ancestry is asserted outright, and --ff-only is kept for what it is good at:
# advancing a base that is merely behind, without inventing a merge node.
#
# Exit 3 = dirty tree, the same code cmd_status uses for it. A checkout would
# carry the changes onto the base or abort halfway, and neither is what a flag
# about where you end up should do to uncommitted work.
cmd_home() {
  local base="${1:?usage: push.sh home <base>}" branch dirty own
  branch=$(git symbolic-ref --short HEAD)
  dirty=$(git status --porcelain)

  if [ -n "$dirty" ]; then
    printf 'home: staying on %s, working tree is dirty\n%s\n' \
      "$branch" "$(printf '%s' "$dirty" | sed 's/^/  /')"
    return 3
  fi

  git fetch --quiet origin "$base"
  # No local branch is fine: checkout creates one tracking origin/<base>.
  [ "$branch" = "$base" ] || git checkout --quiet "$base" \
    || die "cannot check out $base from $branch"

  own=$(git rev-list --count "origin/$base..HEAD")
  [ "$own" -eq 0 ] || die "local '$base' holds $own commit(s) origin/$base does not — it
is not a copy of the remote branch, and every later rev-parse would read it
instead. Inspect it before working from it; straightening an integration branch
belongs to /iso-init-repo, not here"

  git merge --quiet --ff-only "origin/$base" \
    || die "cannot fast-forward '$base' to origin/$base"

  printf 'home: %s at %s (was %s)\n' \
    "$base" "$(git rev-parse --short HEAD)" "$branch"
}

# ------------------------------------------------------------------ promote
# Commit subjects the promotion would carry, for the cascade PR body and the
# release tag annotation. SHAs are omitted on purpose — the PR page links every
# commit and nobody reads a hash.
# Exit 3 = branches already level, nothing to promote.
cmd_promote() {
  local from="${1:?usage: push.sh promote <from> <to>}"
  local to="${2:?usage: push.sh promote <from> <to>}"
  git fetch --quiet origin "$from" "$to"
  local n work
  # "Is there anything to promote" is asked of the FULL range — a range holding
  # only merge nodes is still a real difference between the branches.
  n=$(git rev-list --count "origin/$to..origin/$from")
  [ "$n" -eq 0 ] && { printf 'nothing to promote: %s is level with %s\n' "$to" "$from"; return 3; }

  # What gets LISTED excludes merges. Every landing leaves one, and
  # "Merge pull request #5 from IsaiaScope/feat/x" describes no change — it would
  # be noise in the PR body and permanent noise in the tag annotation, which is
  # read years later with no PR page to explain it.
  work=$(git rev-list --no-merges --count "origin/$to..origin/$from")
  printf 'count: %s\n' "$work"
  git --no-pager log --no-merges --format='%s' "origin/$to..origin/$from"
}

# --------------------------------------------------------------------- bump
# Pure computation, writes nothing. Echoes "<current> <next> <kind>", or "none".
#
# Versioning lives in the CASCADE, never in the feature flow. Two feature PRs
# open at once would both compute the same next version and then conflict on the
# version file — a file neither author touched — every single time. Promoting is
# serial by construction, so the collision cannot occur there.
#
# The range is origin/<to>..origin/<from>: exactly what cmd_promote already
# lists in the PR body.
cmd_bump() {
  local from="${1:?usage: push.sh bump <from> <to>}"
  local to="${2:?usage: push.sh bump <from> <to>}"
  local cur
  git fetch --quiet origin "$from" "$to"

  # "Nothing to promote" is answered BEFORE a VERSION file is demanded. bump
  # runs ahead of promote in the cascade, so a level pair would otherwise be
  # sent to /iso-init-repo to set up a file it has no use for yet.
  # DEFAULT patch, not none: every promotion cuts a version. A chore-only range
  # still changes what prod holds, and leaving it untagged made `git describe`
  # report a release the branch had already moved past — prod read v0.1.0 while
  # carrying commits no tag covered. It also silently swallowed `revert:` and
  # `build:`, both of which change the artifact.
  #
  # `none` now means exactly one thing: the range is empty (handled below).
  local range="origin/$to..origin/$from" subjects bodies kind=patch
  subjects=$(git log --format='%s' "$range")
  bodies=$(git log --format='%b' "$range")
  [ -z "$subjects" ] && { printf 'none\n'; return 0; }

  # Read VERSION from origin/<from>, NOT the working tree. The release commit is
  # built on origin/<from>, so that is the number being incremented — a stale
  # VERSION on the user's feature branch must not decide the next release.
  cur=$(git show "origin/$from:VERSION" 2>/dev/null | tr -d '[:space:]') || cur=""

  # ABSENT VERSION SEEDS AT 0.1.0 — it does not refuse.
  #
  # Seeded, not computed: with no existing number there is nothing to increment,
  # so the commit kinds in the range have no bearing on the result. A first
  # release is a real event and the repo needs a floor to count up from.
  # `(absent)` fills the <current> field so the three-field contract holds.
  if [ -z "$cur" ]; then
    printf '(absent) 0.1.0 initial\n'
    return 0
  fi

  printf '%s' "$cur" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "VERSION on origin/$from is not semver: '$cur'"

  # Subjects decide feat/fix; only BREAKING CHANGE is read from bodies. Scanning
  # bodies for ^feat would let a commit that merely QUOTES a subject bump minor.
  if printf '%s' "$subjects" | grep -qE '^[a-z]+(\([^)]*\))?!:' \
    || printf '%s' "$bodies" | grep -q 'BREAKING CHANGE'; then
    kind="major"
  elif printf '%s' "$subjects" | grep -qE '^feat(\([^)]*\))?:'; then
    kind="minor"
  elif printf '%s' "$subjects" | grep -qE '^(fix|perf)(\([^)]*\))?:'; then
    kind="patch"
  fi

  local M m p; IFS=. read -r M m p <<<"$cur"
  # SemVer's 0.x clause: below 1.0.0 anything may break, so a breaking change
  # bumps minor. Crossing to 1.0.0 is a decision, not an inference.
  [ "$kind" = major ] && [ "$M" -eq 0 ] && kind=minor
  case "$kind" in
    major) M=$((M+1)); m=0; p=0 ;;
    minor) m=$((m+1)); p=0 ;;
    patch) p=$((p+1)) ;;
  esac
  printf '%s %s.%s.%s %s\n' "$cur" "$M" "$m" "$p" "$kind"
}

# ------------------------------------------------------------------ release
# The ONLY place this skill creates a commit, and the only branch it may push a
# self-made commit to is the base. That narrowness is the point — everything
# else it pushes is a branch tip a PR and CI already passed.
#
# The release commit CANNOT be created on test: it must be on the base so both
# promotions carry it, and so "test is on 0.4.0" and "prod is on 0.4.0" describe
# the same work rather than two numbers that happen to match.
#
# A detached worktree, not `checkout dev`: the user stays on their branch with
# their tree untouched, and a dirty tree cannot block a release.
cmd_release() {
  local version="${1:?usage: push.sh release <version> <msgfile> [annotfile]}"
  local msgfile="${2:?usage: push.sh release <version> <msgfile> [annotfile]}"
  # The tag annotation is a SEPARATE file when one is given, because the two
  # documents want different first lines. `msgfile` opens with the cascade PR's
  # subject — `chore(cascade): dev -> test` — which is right for a PR (commitlint
  # reads it, it names the hop) and useless on a tag: `git tag -n1` prints only
  # that line, so the release index reads as a list of hops instead of a list of
  # releases. `annotfile` opens with a one-line release title instead.
  local annotfile="${3:-$msgfile}"
  [ -s "$msgfile" ] || die "tag message file is empty: $msgfile"
  [ -s "$annotfile" ] || die "tag annotation file is empty: $annotfile"
  printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "version is not semver: '$version'"

  local base; base=$(cmd_base)
  git fetch --quiet origin "$base"

  # Idempotent: cmd_pr is find-or-create, so a re-run after a red build must not
  # stack a second release commit.
  #
  # Read VERSION, not the base's top commit subject — after the merge that top
  # commit is the merge node, not `chore(release): <v>`, so a subject check would
  # miss and cut the same release twice.
  local sha pr rb="release/v$version"
  if [ "$(git show "origin/$base:VERSION" 2>/dev/null | tr -d '[:space:]')" = "$version" ]; then
    # The commit landed on an earlier run. Do NOT return here: tagging is a
    # separate push that fails on its own (network, auth, an interrupted run),
    # and returning would make that unrepairable — every re-run would report
    # success while the tag stayed missing. Find the commit and fall through.
    printf 'release: %s already on %s\n' "$version" "$base"
    # --no-merges, and then an exact SUBJECT check. `--grep` matches anywhere in
    # the message, and GitHub puts the PR title in the merge commit's body — so
    # a bare grep finds the merge node first and the tag lands on it instead of
    # on the release commit.
    sha=$(git log -1 --format='%H' --no-merges \
          --grep="^chore(release): $version\$" "origin/$base")
    [ -n "$sha" ] && [ "$(git log -1 --format='%s' "$sha")" = "chore(release): $version" ] \
      || die "VERSION on $base reads $version but no 'chore(release): $version' commit is on it"
    pr=$(gh pr list --head "$rb" --base "$base" --state merged --json number \
         -q '.[0].number' 2>/dev/null || true)
  else
    local wt; wt="$(mktemp -d)/wt"
    git worktree add -q --detach "$wt" "origin/$base"
    printf '%s\n' "$version" > "$wt/VERSION"
    git -C "$wt" add VERSION

    # Manifests move in the SAME commit. VERSION is canonical because it needs
    # no toolchain to read, but package.json is the copy npm and CI actually
    # consume — so a release that updates one and not the other ships the stale
    # one. Two hand-maintained copies with no reconciliation is the single thing
    # every versioning guide names as the anti-pattern.
    #
    # `npm version`, not a jq edit: it updates package-lock.json too, and a
    # lockfile left behind turns one drift into two.
    if [ -f "$wt/package.json" ]; then
      command -v npm >/dev/null \
        || die "package.json is present but npm is not installed — cannot keep the manifest in step"
      npm --prefix "$wt" version "$version" --no-git-tag-version --allow-same-version >/dev/null \
        || die "npm could not set version $version in package.json"
      git -C "$wt" add package.json
      [ -f "$wt/package-lock.json" ] && git -C "$wt" add package-lock.json
    fi

    git -C "$wt" commit -q -m "chore(release): $version"
    sha=$(git -C "$wt" rev-parse HEAD)

    # The release commit lands like every other commit: branch -> PR -> merge. It
    # may NOT be pushed straight to $base — the pre-push guard refuses that, and
    # allowing one exception is how "GitHub is the only writer" stops being true.
    git push origin "$sha:refs/heads/$rb" \
      || die "could not push $rb — if it exists from a failed run, delete it and re-run"
    git worktree remove --force "$wt"

    pr=$(gh pr list --head "$rb" --base "$base" --state open --json number -q '.[0].number')
    [ -n "$pr" ] || pr=$(gh pr create --head "$rb" --base "$base" \
          --title "chore(release): $version" --body-file "$msgfile" \
          | grep -oE '[0-9]+$') \
      || die "could not open the release PR for $rb -> $base"
    gh pr merge "$pr" --merge \
      || die "release PR #$pr refused — resolve on GitHub, then re-run"
    git fetch --quiet origin "$base"
  fi

  # $sha itself is tagged, and that is only safe because --merge rewrote
  # nothing: the commit built in the worktree is the commit now reachable from
  # $base. Under --rebase it would not be, and the tag would dangle off content
  # held by no branch — present in this clone, absent from every other.
  git merge-base --is-ancestor "$sha" "origin/$base" \
    || die "the release commit is not on $base — not tagging"

  if git rev-parse --verify --quiet "refs/tags/v$version" >/dev/null; then
    printf 'release: tag v%s already exists, not moved\n' "$version"
  else
    # Link the PRs that carried the WORK — never this release's own PR, which
    # changes one line of VERSION and answers nothing about what shipped, the
    # single question a tag gets read for.
    #
    # They are derivable: every landing is a --merge, so each leaves a merge
    # commit whose subject names its PR. The range this release covers is the
    # one the cascade is about to promote.
    #
    # Appended HERE, not written by the caller: none of these numbers are known
    # when the message file is written. Best-effort throughout — a release must
    # not fail because `gh` did.
    local annot prnums="" relrange="" prevtag
    annot=$(mktemp); cat "$annotfile" > "$annot"

    # Bound at $sha, not at origin/$base. The release commit's own merge node is
    # a DESCENDANT of $sha, so this range excludes the release PR structurally
    # rather than by filtering — and it stays correct if the tag is repaired
    # later, after the cascade has already moved $base on.
    prevtag=$(git describe --tags --abbrev=0 "$sha^" 2>/dev/null || true)
    if [ -n "$prevtag" ]; then
      relrange="$prevtag..$sha"
    elif git rev-parse --verify --quiet origin/test >/dev/null 2>&1; then
      relrange="origin/test..$sha"
    fi
    if [ -n "$relrange" ]; then
      prnums=$(git log --merges --format='%s' "$relrange" \
               | sed -n 's/^Merge pull request #\([0-9][0-9]*\) .*/\1/p' || true)
      # Belt and braces: the range already excludes it, but this states the
      # intent outright so a later change to the endpoint cannot reintroduce it.
      [ -n "$pr" ] && prnums=$(printf '%s\n' "$prnums" | grep -vx "$pr" || true)
    fi
    if [ -n "$prnums" ]; then
      printf '\n' >> "$annot"
      local n line
      for n in $prnums; do
        line=$(gh pr view "$n" --json url,title -q '.url + " — " + .title' 2>/dev/null) \
          || line="#$n"
        printf '🔗 %s\n' "$line" >> "$annot"
      done
    fi
    # U+00A0, not a newline. GitHub strips ASCII whitespace off both ends of a
    # tag message before rendering it, so a trailing blank line reaches the
    # object (verifiably: the tail is `0a 0a`) and still never reaches the page —
    # the 🔗 line ends up flush against the zip/tar.gz footer. A non-breaking
    # space is not ASCII whitespace, so the trim leaves it, and it renders as the
    # blank line it looks like. `git show` is unaffected either way.
    printf '\302\240\n' >> "$annot"

    # --cleanup=verbatim, NOT the default. Two things depend on it:
    #   · `-F` defaults to `strip`, which deletes every line beginning with `#`
    #     as a comment — and the headings are `### 📦 Summary` / `### 📝 Commits`.
    #     The tag would silently lose both while the PR sharing this same file
    #     kept them, because `gh` does no such stripping.
    #   · `whitespace` would fix that but still eat the trailing blank line
    #     above, which is what keeps `git show v<n>` from running the annotation
    #     straight into the commit that follows it.
    git tag -a "v$version" "$sha" --cleanup=verbatim -F "$annot"
    rm -f "$annot"
    git push origin "v$version"
  fi
  printf 'released: %s at %s on %s (via PR #%s)\n' \
    "$version" "$(git rev-parse --short "$sha")" "$base" "${pr:-?}"
}

# Sourced by the self-check to exercise the pure helpers in isolation. Without
# this the dispatch below runs and `die` kills the sourcing shell.
(return 0 2>/dev/null) && return 0

case "${1:-}" in
  preflight) shift; cmd_preflight "$@" ;;
  rescue)    shift; cmd_rescue "$@" ;;
  base)      shift; cmd_base "$@" ;;
  development-branch) shift; cmd_development_branch "$@" ;;
  status)    shift; cmd_status "$@" ;;
  rebase)    shift; cmd_rebase "$@" ;;
  push)      shift; cmd_push "$@" ;;
  pr)        shift; cmd_pr "$@" ;;
  checks)    shift; cmd_checks "$@" ;;
  integrate) shift; cmd_integrate "$@" ;;
  home)      shift; cmd_home "$@" ;;
  promote)   shift; cmd_promote "$@" ;;
  bump)      shift; cmd_bump "$@" ;;
  release)   shift; cmd_release "$@" ;;
  *) die "usage: push.sh {preflight|base|development-branch|status|rebase|push|pr|checks|integrate|home|promote|bump|release|rescue} [args]" ;;
esac

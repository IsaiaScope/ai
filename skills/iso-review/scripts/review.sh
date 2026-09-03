#!/usr/bin/env bash
# iso-review mechanics: the git-side primitives the skill's three phases sit on.
# Preflight stages, snapshot records an undo point, gate checks and reverts one
# phase, report publishes. The phases themselves run in the calling session, so
# nothing here ever invokes an agent — see docs/adr/0006.
set -euo pipefail

die() { printf 'iso-review: %s\n' "$1" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/track.sh)"

# The integration branch, and the ref to measure against. WHICH names to try is
# iso-config's fact (iso_integration_candidates); resolving them is the caller's,
# and this caller wants a ref that merge-base can actually read — a fresh clone
# or a worktree has origin/dev and no local dev, and a bare name dies there.
# Prints "<name> <ref>".
iso_review_integration() {
  local b r
  for b in $(iso_integration_candidates); do
    for r in "$b" "origin/$b"; do
      git rev-parse --verify --quiet "$r" >/dev/null 2>&1 \
        && { printf '%s %s\n' "$b" "$r"; return 0; }
    done
  done
  return 1
}

# ------------------------------------------------------------------ rebase
# The rebase seam. Today it is iso-push's, which already runs unattended and
# leaves a conflict in progress rather than aborting; when iso-rebase exists,
# this points at it and nothing else here changes.
#
# MISMATCH, known: push.sh rebases onto `origin/<base>` while the staleness
# check below measures against the LOCAL base. They agree whenever the local
# base is fetched, and disagree loudly rather than silently when it is not —
# the rebase either no-ops or fails on a missing ref. Reconciling the two is
# iso-rebase's job, because iso-push has its own reasons for wanting the remote.
iso_review_rebase() {
  local base="$1" sh
  sh="${ISO_REVIEW_REBASE:-$(iso_sibling iso-push scripts/push.sh 2>/dev/null)}" || true
  [ -x "$sh" ] || die "no rebase available — install iso-push or set ISO_REVIEW_REBASE"
  case "$sh" in *push.sh) "$sh" rebase "$base" ;; *) "$sh" "$base" ;; esac
}

# Rewriting history is safe only while nobody else has the commits.
#
# KNOWN WEAKNESS, deliberate: `git push origin <branch>` without -u writes no
# upstream, so a genuinely published branch reads as local here and would be
# rewritten. `git ls-remote --exit-code origin <branch>` is the correct test.
# Deferred to iso-rebase, which will own this decision for every iso-* skill.
branch_is_local() {
  ! git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1
}

# --------------------------------------------------------------- preflight
# The index becomes the "before" snapshot for the whole run, so everything the
# phases write shows up as `git diff` and nothing else does.
#
# The write-tree comes FIRST and is printed, because `git add -A` overwrites a
# deliberate partial stage and nothing afterwards can tell "was staged" from
# "just got staged". The tree object survives in .git/objects either way, but
# only the sha makes it findable without `git fsck`. Recovery is
# `git read-tree <sha>`.
cmd_preflight() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
  local index ib ibref behind
  index=$(git write-tree) || die "could not snapshot the index"
  # Printed BEFORE the staging it protects against, and before every refusal
  # below. Emitting it at the end would mean the one path that destroys a
  # partial stage — a die between here and there — is the one path that never
  # tells you how to get it back.
  printf 'index=%s\n' "$index"
  git add -A
  read -r ib ibref < <(iso_review_integration) \
    || die "no integration branch: tried $(iso_integration_candidates | tr '\n' ' ')"
  REVIEW_BASE=$(git merge-base "$ibref" HEAD 2>/dev/null) \
    || die "no merge-base with $ib — is this branch related to it?"
  # Behind means the base is stale, and every phase after this would measure
  # its diff against the wrong thing. Checked BEFORE the empty-diff refusal:
  # after a rebase the base moves, and a branch can look empty against the old
  # base and not against the new one.
  behind=$(git rev-list --count "HEAD..$ibref")
  if [ "$behind" -gt 0 ]; then
    if branch_is_local; then
      iso_review_rebase "$ib" || exit 2
      REVIEW_BASE=$(git merge-base "$ibref" HEAD)
    else
      die "branch is $behind behind $ib and is published — rebase it yourself, then re-run"
    fi
  fi
  # An empty diff is not a failure to report on, it is nothing to run three
  # agents against. Measured from the base, not from the index: after `add -A`
  # the tree is clean by construction, so a dirty-tree check would always pass.
  if git diff --cached --quiet "$REVIEW_BASE"; then
    die "nothing on this branch to refine (base $ib)"
  fi
  printf 'base=%s\n' "$REVIEW_BASE"
  # The sha lines stay bare: they are parsed with `sed -n 's/^index=//p'` and
  # matched anchored to end-of-line, so the prose goes on its own lines.
  printf 'note=index= is your staged work from before this run. Undo the staging with: git read-tree %s\n' "$index"
  printf 'note=base= is the commit every phase measures its diff against (merge-base with %s)\n' "$ib"
}

# ----------------------------------------------------------------- scope
# The files a run acts on: the staged diff against the base. Every phase gets
# this list, all of it, and it does not move for the whole run — preflight is
# the last thing that stages, so the index stays pinned to the branch's own
# work while the phases churn the worktree around it.
#
# With <base>, lists and nothing else. That form is the one a running phase
# calls: without it this re-runs preflight, whose `git add -A` would swallow
# the previous phases' output into the index and destroy the very separation
# the caller is about to read.
#
# The listing is repo-relative, which `git diff --name-only` already is by
# default from any directory — the flag to never add here is `--relative`. A
# phase resolving a cwd-relative path against the repo root silently reads the
# wrong file, which is how the revert path lost data once already.
cmd_scope() {
  local base="${1:-}"
  if [ -n "$base" ]; then
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
      || die "not a commit: $base"
    REVIEW_BASE="$base"
    printf 'base=%s\n' "$REVIEW_BASE"
  else
    # Called directly, not through `$(...)` or a temp file: preflight ASSIGNS
    # REVIEW_BASE, and a command substitution would set it in a subshell that
    # then exits. It already prints both `index=` and `base=`, so forwarding
    # them by hand was plumbing to recover output that was never lost — and its
    # `|| rm -f` cleanup could not run anyway, since every failure inside
    # preflight is an `exit`, which no `||` branch survives.
    #
    # The `index=` line matters here above all: this is the branch whose
    # `git add -A` flattens a hand-staged index, so it is the one that must say
    # how to get it back.
    cmd_preflight
  fi
  git diff --cached --name-only "$REVIEW_BASE"
}

# ---------------------------------------------------------- skill-check
# skill-check <name>... -> one "skill=<n> state=<s>" line each; exit 1 if any
# is blocked.
#
# A phase IS its skill. `disable-model-invocation: true` makes that skill
# refuse a model caller, and the refusal is easy to route around by "following"
# the skill from memory instead — which produces a phase that reports a result
# without having run the thing it names. That happened, on this skill, and the
# gate exists so it cannot happen quietly again.
#
# Reports rather than repairs. Flipping the flag edits a file outside the
# repository, and that is a decision for whoever is reading the output.
# Two layouts, three roots. A skill is `<dir>/<name>/SKILL.md`; a plugin
# command is `<dir>/<name>.md`, and the codex plugin ships `commands/review.md`
# carrying the very flag this verb exists to find. Searching only the user's
# skills dir found the unblocked `~/.claude/skills/review/SKILL.md`, reported
# `ok`, and never saw the blocked copy at all — a false green in the guard whose
# whole job is preventing false greens.
#
# An unmatched glob stays literal, which `[ -f ]` rejects, so a missing plugin
# cache costs nothing.
ISO_REVIEW_SKILL_DIRS="${ISO_REVIEW_SKILL_DIRS:-\
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills \
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/*/*/skills \
${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/*/*/commands}"

cmd_skill_check() {
  [ $# -gt 0 ] || die "skill-check needs at least one skill name"
  local name d f rc=0 hits blocked_paths open_paths n_hits n_blocked resolved=0
  for name in "$@"; do
    hits=""; blocked_paths=""; open_paths=""
    for d in $ISO_REVIEW_SKILL_DIRS; do
      for f in "$d/$name/SKILL.md" "$d/$name.md"; do
        [ -f "$f" ] || continue
        hits="$hits $f"
        if grep -qE '^disable-model-invocation:[[:space:]]*true' "$f"; then
          blocked_paths="$blocked_paths $f"
        else
          open_paths="$open_paths $f"
        fi
      done
    done

    n_hits=$(printf '%s' "$hits" | wc -w | tr -d ' ')
    n_blocked=$(printf '%s' "$blocked_paths" | wc -w | tr -d ' ')

    # No file is not a failure: the harness ships skills with no SKILL.md on
    # disk, and those are invocable. It is reported so a TYPO in a phase name
    # does not read as a clean pass.
    if [ "$n_hits" -eq 0 ]; then
      printf 'skill=%s state=builtin\n' "$name"
    elif [ "$n_blocked" -eq "$n_hits" ]; then
      printf 'skill=%s state=blocked path=%s\n' "$name" "${blocked_paths# }"; rc=1
    elif [ "$n_blocked" -gt 0 ]; then
      # Copies disagree, so which one answers decides whether the phase runs at
      # all — and nothing here can predict the resolution order. Reporting `ok`
      # would be a guess dressed as a check.
      printf 'skill=%s state=split blocked=%s open=%s\n' \
        "$name" "${blocked_paths# }" "${open_paths# }"; rc=1
    elif [ "$n_hits" -gt 1 ]; then
      printf 'skill=%s state=ok copies=%s path=%s\n' "$name" "$n_hits" "${open_paths# }"
    else
      printf 'skill=%s state=ok\n' "$name"
    fi
    [ "$n_hits" -gt 0 ] && resolved=$((resolved+1))
  done

  # The floor both sibling sweeps carry and this one lacked. `builtin` is a
  # pass, so a search that finds NOTHING passes everything -- and a moved
  # plugin cache, an extra depth level under plugins/cache, or a
  # CLAUDE_CONFIG_DIR that differs from the harness's all produce exactly that.
  # The guard against silent false greens would go silently false green.
  #
  # Only with 2+ names: a single genuinely-builtin name resolving to no file is
  # the normal case, not a broken sweep.
  if [ $# -gt 1 ] && [ "$resolved" -eq 0 ]; then
    printf 'skill-check: no name resolved to a file under: %s\n' \
      "$ISO_REVIEW_SKILL_DIRS" >&2
    die "the search found nothing at all — treat this as a broken sweep, not a pass"
  fi
  return "$rc"
}

# -------------------------------------------------------------- snapshot
# A tree object holding the working tree exactly as it is now, WITHOUT touching
# the real index. Built in a throwaway index, so the run-level snapshot the
# index carries — the user's own work — is left alone.
#
# This is a phase's undo point, and the index cannot serve as one: the index is
# the pre-RUN snapshot, so reverting to it would throw away every phase that
# already passed, turning one red gate into a lost run.
cmd_snapshot() {
  local idx tree; idx=$(mktemp)
  cp "$(git rev-parse --git-dir)/index" "$idx" 2>/dev/null || : > "$idx"
  GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1 || true
  tree=$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null) || true
  # Removed before the check below, so the failure path leaks no temp index.
  rm -f "$idx"
  # Printing nothing on failure is the dangerous shape here, not exiting. The
  # caller feeds this straight to `gate`, and gate with an empty snapshot takes
  # the `git checkout -- :/` fallback, which undoes EVERY earlier phase's work
  # as well. That fallback is a legitimate choice when the caller deliberately
  # omits the argument; it must never be what a failed snapshot picks silently
  # on the caller's behalf. So fail loudly and let the run stop.
  [ -n "$tree" ] || die "could not snapshot the working tree"
  printf '%s\n' "$tree"
}

# ------------------------------------------------------------------ gate
# gate <name> [snapshot-sha] -> "phase=<name> result=<unchecked|verified|reverted> files=<n>"
#
# Exits 0 on both outcomes. A red gate is a RESULT, not a failure: the phase
# ran, its edits were undone, and the next phase still has a tree to work on.
# Making this non-zero would make `set -e` in any caller turn a handled revert
# into an aborted run.
cmd_gate() {
  local name="${1:?gate needs a phase name}" snap="${2:-}" gate files created

  # Files this phase created. Captured BEFORE `add -N`, because that is the only
  # moment they are distinguishable: preflight left nothing untracked, so
  # anything untracked here was written during the phase.
  #
  # ponytail: newline-separated, so a filename containing a newline is missed
  # and survives a revert. `-z` cannot help — bash drops NUL bytes in command
  # substitution, which silently collapses the whole list into one name.
  # quotePath=false so a path with a space or a non-ASCII character arrives
  # literally rather than in git's escaped-and-quoted form.
  #
  # --full-name, because ls-files prints paths relative to the CWD and every
  # consumer below wants them relative to the repo root. Run from a
  # subdirectory without it, `$snap:sub-file` misses the file's real tree path
  # (`sub/sub-file`), an EARLIER phase's creation reads as this phase's, and
  # the revert deletes work that already passed its gate.
  created=$(git -c core.quotePath=false ls-files --full-name --others --exclude-standard -- :/)

  # Narrowed to files absent from the snapshot, because "untracked" alone is not
  # "created by this phase". Under the old in-script loop it was: every phase
  # went through one function whose `add -N` made the previous phase's creations
  # tracked. Driven as separate verbs, that invariant would rest on the caller
  # always running `gate` between phases — and the one time it did not, a revert
  # would `git clean` away an EARLIER phase's files. Asking the snapshot is the
  # same answer without the standing obligation.
  if [ -n "$snap" ] && [ -n "$created" ]; then
    # One `ls-tree`, not a `cat-file` per file. The loop cost a git fork per
    # untracked file on every phase; the snapshot's whole file list is one read.
    #
    # --full-tree for the same reason `ls-files` above needs --full-name: without
    # it, ls-tree from a subdirectory lists only that subdirectory, every path
    # above the cwd reads as "not in the snapshot", and the revert deletes an
    # earlier phase's file. The test for that caught this rewrite.
    created=$(printf '%s\n' "$created" \
      | grep -Fxv -f <(git -c core.quotePath=false ls-tree -r --full-tree --name-only \
                        "$snap" 2>/dev/null) 2>/dev/null || true)
  fi

  # Intent-to-add, not add: without this a file the phase CREATED is untracked,
  # `git diff` shows nothing, and the phase's output is partly invisible in the
  # one place the whole design says to read it.
  git add -N -- :/ >/dev/null 2>&1 || true
  # Against the SNAPSHOT, not the index. The index is pinned at run start, so
  # diffing it counts every phase before this one too - `simplify files=7` was
  # architecture's edits plus its own, under a label that names one phase. With
  # no snapshot there is nothing better to measure from, and the run-wide count
  # is the honest answer to "what changed", so the fallback keeps it.
  #
  # A concurrent session editing this checkout lands in the count either way.
  if [ -n "$snap" ]; then
    files=$(git diff --name-only "$snap" -- :/ | wc -l | tr -d ' ')
  else
    files=$(git diff --name-only -- :/ | wc -l | tr -d ' ')
  fi

  gate=$(iso_config_get test.command)
  if [ -z "$gate" ]; then
    printf 'phase=%s result=unchecked files=%s (ran; no test.command set, so nothing verified it)\n' \
      "$name" "$files"
    return 0
  fi
  # Subshell, so a gate command that calls `exit` or `cd` cannot take the caller
  # with it. Output discarded: the phase line is the record, and a test runner's
  # full output would bury it and blow the ticket comment cap.
  if ( eval "$gate" ) >/dev/null 2>&1; then
    printf 'phase=%s result=verified files=%s (ran; the test command was still green after it)\n' \
      "$name" "$files"
    return 0
  fi

  # Drop the intent-to-add entries first. `git clean` will not touch those paths
  # — the index entry makes them tracked — so without this a reverted phase
  # still contributes every file it created, which is the one thing a revert is
  # supposed to prevent.
  #
  # Only the recorded paths, never `git reset`: the index is the pre-run
  # snapshot of the user's own work, and resetting it would throw that away to
  # clean up after a phase.
  if [ -n "$created" ]; then
    printf '%s\n' "$created" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      # :(top,literal) to match --full-name above: a bare "$f" is read relative
      # to the CWD, and literal so a filename holding a glob character is not
      # read as a pattern.
      git rm -q --cached --force -- ":(top,literal)$f" >/dev/null 2>&1 || true
    done
  fi
  # `restore --worktree`, not `checkout -- .`: restores from THIS phase's
  # snapshot and leaves the index alone. Needs git 2.23 (2019) — there is no
  # pre-2.23 equivalent that spares the index, so that is the floor.
  #
  # `:/`, not `.`: a bare `.` is relative to the cwd, so running the skill from
  # a subdirectory would report a repo-wide `files=` count and then revert only
  # part of the tree, leaving the phase's edits above the cwd on disk under a
  # line that claims they were undone.
  if [ -n "$snap" ]; then
    git restore --source="$snap" --worktree -- :/ >/dev/null 2>&1 || true
  else
    git checkout -- :/ >/dev/null 2>&1 || true
  fi
  git clean -fdq -- :/ >/dev/null 2>&1 || true
  printf 'phase=%s result=reverted files=0 (the test command went red; this phase edits were undone)\n' \
    "$name"
  return 0
}

# ---------------------------------------------------------------- report
# The finished summary on stdin: echoed, and posted as one ticket comment.
#
# Capped AT the tracker's own comment limit, so the terminal and the board hold
# the same text rather than the board silently holding a shorter one. The number
# mirrors the `head -c` in iso-issue-tracking/scripts/tracking.sh's `comment`
# arm; it was 8000 against that 4000, which guaranteed the divergence this
# comment claims to prevent for every summary in between.
#
# Parameter expansion, not `| head -c`: under `set -o pipefail` a printf whose
# reader exits at the limit takes SIGPIPE, pipefail surfaces 141, and the run
# aborts with no summary at all — after every phase has already spent its
# tokens.
ISO_REVIEW_REPORT_CAP="${ISO_REVIEW_REPORT_CAP:-4000}"

cmd_report() {
  local summary key
  summary=$(cat)
  summary="${summary:0:$ISO_REVIEW_REPORT_CAP}"
  # Echoed before the check below, so a refusal costs the retyping of a report
  # and never the report itself — every phase has already spent its tokens by
  # the time this runs.
  printf '%s\n' "$summary"

  # A summary made only of machine lines is a receipt, not a report: it says a
  # phase ran and how many files it touched, and nothing about what it found.
  # This is a check rather than a line of prose in SKILL.md because the prose
  # version was already there, and runs kept posting the receipt anyway.
  if [ -z "$(printf '%s\n' "$summary" | grep -vE '^(index|base|note|phase)=' | tr -d '[:space:]')" ]; then
    die "report needs each phase's findings, not just its phase= line"
  fi

  # A ticket is optional. No tracker, or no row for this branch, means the
  # terminal is the whole report — the normal case for a quick branch. iso_track
  # is never fatal by construction, so a broken tracker cannot lose the refine
  # that already happened.
  key=$(iso_track ticket-for-branch 2>/dev/null | cut -f1)
  if [ -n "$key" ]; then
    printf '%s\n' "$summary" | iso_track comment "$key" >/dev/null 2>&1 || true
  fi
  return 0
}

case "${1:-}" in
  preflight) shift; cmd_preflight "$@" ;;
  scope)     shift; cmd_scope "$@" ;;
  skill-check) shift; cmd_skill_check "$@" ;;
  snapshot)  shift; cmd_snapshot "$@" ;;
  gate)      shift; cmd_gate "$@" ;;
  report)    shift; cmd_report "$@" ;;
  *) die "usage: review.sh {preflight|scope [base]|skill-check <name>...|snapshot|gate|report} [args]" ;;
esac

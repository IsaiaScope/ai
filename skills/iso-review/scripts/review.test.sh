#!/usr/bin/env bash
# Self-check for review.sh. Run: bash review.test.sh
# ponytail: asserts the git manipulation only — no phase ever runs here, so the
# whole file costs nothing and can be run on every edit.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/review.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
export ISO_GLOBAL_CONFIG=/nonexistent
# review.sh reaches the real tracking.sh through iso_sibling, so EVERY fixture
# below -- not just the ones that assert on tracking -- would otherwise read the
# user's live ledger and drive the real board. It hung the suite once, on a
# network call from inside a fixture repo. Both are set: the state dir isolates
# the ledger, and the silent default tracker means no test can reach the real
# one by forgetting to override it.
export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)
export ISO_TRACKING_SH; ISO_TRACKING_SH=$(mktemp -d)/noop.sh
printf '#!/usr/bin/env bash\nexit 0\n' > "$ISO_TRACKING_SH"; chmod +x "$ISO_TRACKING_SH"

work_repo() {  # a branch with real, committed work on it
  local d; d=$(newrepo)
  ( cd "$d" && git checkout -q -b "$1" && printf 'w\n' > w.txt && git add -A && git commit -q -m w )
  printf '%s' "$d"
}

newrepo() {
  local d; d=$(mktemp -d)
  git init -q -b dev "$d"
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  printf '%s' "$d"
}

echo "preflight"
t=$(mktemp -d); ( cd "$t" && bash "$SH" preflight ) >/dev/null 2>&1
check "outside a repo is refused" "$?" "1"

r=$(newrepo); ( cd "$r" && git checkout -q -b feat/x && git commit -q --allow-empty -m work )
printf 'w\n' > "$r/w.txt"
out=$( cd "$r" && bash "$SH" preflight )
check "prints an index sha" "$(printf '%s' "$out" | grep -c '^index=[0-9a-f]\{40\}$')" "1"
check "prints a base sha"  "$(printf '%s' "$out" | grep -c '^base=[0-9a-f]\{40\}$')"  "1"

r=$(newrepo); ( cd "$r" && git checkout -q -b feat/y )
( cd "$r" && bash "$SH" preflight ) >/dev/null 2>&1
check "a branch with nothing on it is refused" "$?" "1"

# The refusal is the path that most needs the sha: `git add -A` has already run
# by the time preflight decides to refuse, so a deliberate partial stage is gone
# and this line is the only way back to it.
#
# The fixture has to actually REACH a refusal. An unstaged file on an empty
# branch does not: `add -A` stages it, the branch stops being empty, preflight
# succeeds, and the assertion below passes on the success path -- which prints
# the same line -- while asserting nothing about a refusal. So: a branch whose
# only change is staged by hand and then undone on disk. `add -A` restages the
# base content, the diff against the base is empty, preflight refuses, and the
# hand-staged "b" is recoverable only through the sha it printed on the way.
r=$(newrepo)
( cd "$r" && printf 'a\n' > a.txt && git add -A && git commit -q -m a \
   && git checkout -q -b feat/y2 )
printf 'b\n' > "$r/a.txt"; ( cd "$r" && git add a.txt )
printf 'a\n' > "$r/a.txt"
out=$( cd "$r" && bash "$SH" preflight 2>/dev/null ); rc=$?
check "it really is a refusal"               "$rc" "1"
check "a refusal still prints the index sha" "$(printf '%s' "$out" | grep -c '^index=[0-9a-f]\{40\}$')" "1"
check "and the flattened stage is recoverable from it" \
  "$( cd "$r" && git show "$(printf '%s' "$out" | sed -n 's/^index=//p'):a.txt" )" "b"

echo "staging"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/z )
printf 'mod\n' > "$r/tracked.txt"
( cd "$r" && git add tracked.txt && git commit -q -m t )
printf 'changed\n' > "$r/tracked.txt"; printf 'new\n' > "$r/added.txt"
( cd "$r" && bash "$SH" preflight ) >/dev/null 2>&1
check "nothing is left unstaged" "$( cd "$r" && git diff --name-only | wc -l | tr -d ' ')" "0"
check "the untracked file was staged" \
  "$( cd "$r" && git diff --cached --name-only | grep -c added.txt )" "1"

echo "the index snapshot is real"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/w )
printf 'a\n' > "$r/a.txt"; ( cd "$r" && git add a.txt && git commit -q -m a )
printf 'staged-by-hand\n' > "$r/a.txt"; ( cd "$r" && git add a.txt )
printf 'then-changed\n' > "$r/a.txt"
sha=$( cd "$r" && bash "$SH" preflight | sed -n 's/^index=//p' )
check "the recorded tree is readable back" \
  "$( cd "$r" && git cat-file -t "$sha" )" "tree"
check "it holds what was staged, not what is on disk" \
  "$( cd "$r" && git show "$sha:a.txt" )" "staged-by-hand"

echo "staleness"
# The seam, stubbed: a real rebase needs a real remote, and what is asserted
# here is the POLICY around the seam, not git's rebase.
RB=$(mktemp -d)
mkstub() { printf '#!/usr/bin/env bash\necho "rebase $*" >> "%s/calls"\nexit %s\n' "$RB" "$1" > "$RB/rebase"; chmod +x "$RB/rebase"; }
mkstub 0

# Real content, not --allow-empty: an empty commit leaves no diff from the base,
# so preflight would refuse at "nothing to refine" and every staleness assertion
# below would pass without the staleness check existing at all.
behind() {   # a branch with one commit of its own, one commit behind dev
  local d; d=$(newrepo)
  ( cd "$d" && git checkout -q -b "$1" && printf 'mine\n' > mine.txt \
     && git add -A && git commit -q -m mine \
     && git checkout -q dev && printf 'theirs\n' > theirs.txt \
     && git add -A && git commit -q -m theirs \
     && git checkout -q "$1" )
  printf '%s' "$d"
}

r=$(behind feat/behind); : > "$RB/calls"
( cd "$r" && ISO_REVIEW_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "a behind local branch is rebased" "$(grep -c '^rebase ' "$RB/calls")" "1"

# @{upstream} needs the branch config, not just a remote-tracking ref — setting
# only refs/remotes/ leaves the branch reading as local and the assertion
# passing for the wrong reason.
( cd "$r" && git remote add origin . \
   && git update-ref refs/remotes/origin/feat/behind HEAD \
   && git config branch.feat/behind.remote origin \
   && git config branch.feat/behind.merge refs/heads/feat/behind )
: > "$RB/calls"
( cd "$r" && ISO_REVIEW_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "a published behind branch is refused" "$?" "1"
check "and is never rebased" "$(grep -c '^rebase ' "$RB/calls")" "0"

r=$(newrepo); ( cd "$r" && git checkout -q -b feat/current \
   && printf 'mine\n' > mine.txt && git add -A && git commit -q -m mine )
: > "$RB/calls"
( cd "$r" && ISO_REVIEW_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "an up-to-date branch is not rebased" "$(grep -c '^rebase ' "$RB/calls")" "0"

mkstub 1
r=$(behind feat/conflict)
( cd "$r" && ISO_REVIEW_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "a rebase conflict exits 2" "$?" "2"
rm -rf "$RB"

echo "scope"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/s )
printf 'a\n' > "$r/a.txt"; printf 'b\n' > "$r/b.txt"
( cd "$r" && git add -A && git commit -q -m two )
printf 'c\n' > "$r/c.txt"
out=$( cd "$r" && bash "$SH" scope )
check "names the base"         "$(printf '%s' "$out" | grep -c '^base=')"    "1"
check "lists committed work"   "$(printf '%s' "$out" | grep -c '^a\.txt$')" "1"
check "lists uncommitted work" "$(printf '%s' "$out" | grep -c '^c\.txt$')" "1"

# The point of `scope` is that it answers without spending a token. Asserted
# with a recording stub rather than by stripping PATH: git itself is not in
# /usr/bin on every machine, so a stripped PATH would pass because nothing ran.
CB=$(mktemp -d)
printf '#!/usr/bin/env bash\necho called >> "%s/calls"\n' "$CB" > "$CB/claude"
chmod +x "$CB/claude"; : > "$CB/calls"
( cd "$r" && PATH="$CB:$PATH" bash "$SH" scope ) >/dev/null 2>&1
check "no agent was invoked" "$(wc -l < "$CB/calls" | tr -d ' ')" "0"
rm -rf "$CB"

# `scope <base>` is the form a RUNNING phase calls, and the whole reason it
# exists is that the bare form re-runs preflight. A phase calling that would
# `git add -A` its predecessors' output into the index — staging exactly the
# changes the staging contract promises to keep unstaged.
base=$( cd "$r" && bash "$SH" scope | sed -n 's/^base=//p' )
printf 'phase-edit\n' >> "$r/a.txt"          # stands in for a phase's output
before=$( cd "$r" && git write-tree )
out=$( cd "$r" && bash "$SH" scope "$base" )
after=$( cd "$r" && git write-tree )
check "scope <base> stages nothing"   "$after" "$before"
check "scope <base> names that base"  "$(printf '%s' "$out" | grep -c "^base=$base$")" "1"
check "and still lists the scope"     "$(printf '%s' "$out" | grep -c '^a\.txt$')" "1"
check "a phase edit is not new scope" "$(printf '%s\n' "$out" | grep -vc '^base=')" "3"
( cd "$r" && bash "$SH" scope deadbeef ) >/dev/null 2>&1
check "a bad base is refused"         "$?" "1"

# Repo-relative, not cwd-relative: a phase given `a.txt` while standing in a
# subdirectory resolves it against the wrong root.
mkdir -p "$r/sub"; printf 'd\n' > "$r/sub/d.txt"
( cd "$r" && git add -A ) >/dev/null 2>&1
out=$( cd "$r/sub" && bash "$SH" scope "$base" )
check "paths are repo-relative from a subdirectory" \
  "$(printf '%s' "$out" | grep -c '^sub/d\.txt$')" "1"

echo "skill-check"
SK=$(mktemp -d); mkdir -p "$SK/open" "$SK/shut"
printf -- '---\nname: open\n---\n' > "$SK/open/SKILL.md"
printf -- '---\nname: shut\ndisable-model-invocation: true\n---\n' > "$SK/shut/SKILL.md"

out=$( ISO_REVIEW_SKILL_DIRS="$SK" bash "$SH" skill-check open ); rc=$?
check "an invocable skill is ok" "$out" "skill=open state=ok"
check "and exits 0"              "$rc"  "0"

out=$( ISO_REVIEW_SKILL_DIRS="$SK" bash "$SH" skill-check shut ); rc=$?
check "a blocked skill is named" "$(printf '%s' "$out" | grep -c '^skill=shut state=blocked')" "1"
check "and the path is printed"  "$(printf '%s' "$out" | grep -c "$SK/shut/SKILL.md")" "1"
check "and exits 1"              "$rc"  "1"

# A phase whose skill has no SKILL.md is not a failure — the harness ships some
# with no file — but a TYPOED phase name must not read as a clean pass either.
check "a missing file reports builtin" \
  "$( ISO_REVIEW_SKILL_DIRS="$SK" bash "$SH" skill-check nosuch )" "skill=nosuch state=builtin"

# One blocked skill must fail the whole check, not just its own line.
out=$( ISO_REVIEW_SKILL_DIRS="$SK" bash "$SH" skill-check open shut ); rc=$?
check "one blocked fails the batch" "$rc" "1"
check "and every skill still reports" "$(printf '%s\n' "$out" | grep -c '^skill=')" "2"

( bash "$SH" skill-check ) >/dev/null 2>&1
check "no names is refused" "$?" "1"
rm -rf "$SK"

echo "snapshot"
r=$(work_repo feat/snap)
snap=$( cd "$r" && bash "$SH" snapshot )
check "prints a tree sha" "$(printf '%s' "$snap" | grep -c '^[0-9a-f]\{40\}$')" "1"

# The whole reason snapshot exists: it must record the tree WITHOUT disturbing
# the index, which is holding the user's own pre-run work.
before=$( cd "$r" && git write-tree )
( cd "$r" && printf 'new\n' > n.txt && bash "$SH" snapshot ) >/dev/null 2>&1
after=$( cd "$r" && git write-tree )
check "leaves the real index alone" "$after" "$before"

echo "gate"
# An empty test.command is a real mode, not a broken one: phases run, nothing
# checks them, and the line says so rather than claiming a pass it did not earn.
r=$(work_repo feat/g1)
printf 'edit\n' >> "$r/w.txt"
out=$( cd "$r" && bash "$SH" gate architecture )
check "unset gate still passes"   "$(printf '%s' "$out" | grep -c '^phase=architecture result=pass')" "1"
check "and says it did not check" "$(printf '%s' "$out" | grep -c 'no gate configured')" "1"

gated() {  # a repo whose test.command is <cmd>
  local d; d=$(work_repo "$1"); shift
  mkdir -p "$d/docs/iso"
  printf '{"test":{"command":"%s"}}\n' "$1" > "$d/docs/iso/config.json"
  ( cd "$d" && git add -A && git commit -q -m gate )
  printf '%s' "$d"
}

r=$(gated feat/g2 true)
printf 'edit\n' >> "$r/w.txt"; printf 'made\n' > "$r/made.txt"
out=$( cd "$r" && bash "$SH" gate simplify "$( cd "$r" && bash "$SH" snapshot )" )
check "a green gate passes"        "$(printf '%s' "$out" | grep -c '^phase=simplify result=pass')" "1"
check "and counts both files"      "$(printf '%s' "$out" | sed -n 's/.*files=\([0-9]*\).*/\1/p')" "2"
check "the edit survives"          "$(grep -c edit "$r/w.txt")" "1"
check "the created file survives"  "$([ -f "$r/made.txt" ] && echo yes || echo no)" "yes"

r=$(gated feat/g3 false)
snap=$( cd "$r" && bash "$SH" snapshot )
printf 'edit\n' >> "$r/w.txt"; printf 'made\n' > "$r/made.txt"
out=$( cd "$r" && bash "$SH" gate review "$snap" ); rc=$?
check "a red gate reverts"        "$(printf '%s' "$out" | grep -c '^phase=review result=revert files=0')" "1"
check "and exits 0 anyway"        "$rc" "0"
check "the edit is undone"        "$(grep -c edit "$r/w.txt")" "0"
check "the created file is gone"  "$([ -f "$r/made.txt" ] && echo yes || echo no)" "no"
check "and nothing is left staged" "$(cd "$r" && git diff --cached --name-only | wc -l | tr -d ' ')" "0"

# The point of a PER-PHASE snapshot. A red gate in a later phase must not
# rewind the tree past the phases that already passed — reverting to the index
# would do exactly that, because the index is the pre-RUN snapshot.
#
# The earlier phase has to edit a TRACKED file for this to assert anything. A
# file it merely CREATED survives either way -- the `add -N` entry is what keeps
# `git clean` off it -- so a fixture built only from untracked files passes with
# the snapshot ignored and the revert reading from the index.
r=$(gated feat/g4 false)
printf 'first\n' >> "$r/w.txt"            # a phase that passed, editing tracked work
printf 'kept\n' > "$r/first.txt"          # and the file that phase created
snap=$( cd "$r" && bash "$SH" snapshot )  # the NEXT phase's undo point
printf 'second\n' >> "$r/w.txt"           # the phase whose gate goes red
printf 'lost\n' > "$r/second.txt"
( cd "$r" && bash "$SH" gate review "$snap" ) >/dev/null 2>&1
check "an earlier phase's edit survives" "$(grep -c '^first$' "$r/w.txt")" "1"
check "an earlier phase's file survives" "$([ -f "$r/first.txt" ] && echo yes || echo no)" "yes"
check "the red phase's edit does not"    "$(grep -c '^second$' "$r/w.txt")" "0"
check "the red phase's file does not"    "$([ -f "$r/second.txt" ] && echo yes || echo no)" "no"

# `gate` without a snapshot is the documented fallback, and the only path where
# dropping the intent-to-add entry is load-bearing: `git checkout` restores an
# `add -N` file to its zero-byte index content instead of deleting it, and
# `git clean` then skips it for being tracked. Without the `git rm --cached`
# the file a red phase created survives its own revert, as an empty stub.
r=$(gated feat/g5 false)
printf 'edit\n' >> "$r/w.txt"; printf 'made\n' > "$r/made.txt"
out=$( cd "$r" && bash "$SH" gate review )
check "a snapshotless red gate reverts" "$(printf '%s' "$out" | grep -c 'result=revert')" "1"
check "the edit is undone"              "$(grep -c edit "$r/w.txt")" "0"
check "the created file is gone, not emptied" \
  "$([ -e "$r/made.txt" ] && echo present || echo gone)" "gone"
check "and leaves no index entry behind" \
  "$( cd "$r" && git ls-files -- made.txt | wc -l | tr -d ' ')" "0"

# Everything above runs the gate from the repo root, where cwd-relative and
# repo-relative agree and every path bug below is invisible. Every pathspec in
# `gate` is repo-anchored on purpose, and so is the file list it derives them
# from -- run from a subdirectory, a cwd-relative one measures and reverts only
# the part of the tree under the cwd while the `phase=` line claims the phase
# was measured and undone.
subrepo() {  # a gated repo with a committed subdirectory
  local d; d=$(gated "$1" "$2")
  mkdir -p "$d/sub"; printf 's\n' > "$d/sub/s.txt"
  ( cd "$d" && git add -A && git commit -q -m sub )
  printf '%s' "$d"
}

r=$(subrepo feat/g6 true)
printf 'above\n' >> "$r/w.txt"; printf 'below\n' >> "$r/sub/s.txt"
out=$( cd "$r/sub" && bash "$SH" gate simplify "$( cd "$r" && bash "$SH" snapshot )" )
check "counts the whole tree from a subdirectory" \
  "$(printf '%s' "$out" | sed -n 's/.*files=\([0-9]*\).*/\1/p')" "2"

r=$(subrepo feat/g7 false)
snap=$( cd "$r" && bash "$SH" snapshot )
printf 'above\n' >> "$r/w.txt"            # an edit ABOVE the cwd the gate runs in
printf 'below\n' >> "$r/sub/s.txt"
printf 'made\n' > "$r/made.txt"           # and a file created above it
( cd "$r/sub" && bash "$SH" gate review "$snap" ) >/dev/null 2>&1
check "a revert from a subdirectory reaches above the cwd" "$(grep -c above "$r/w.txt")" "0"
check "and below it"                                       "$(grep -c below "$r/sub/s.txt")" "0"
check "and cleans what was created above it" \
  "$([ -e "$r/made.txt" ] && echo present || echo gone)" "gone"

# The file list `created` is built from is printed relative to the CWD, and the
# snapshot lookup that narrows it reads repo-relative tree paths. Where the two
# disagree, an earlier phase's file inside a subdirectory reads as this phase's
# and the revert deletes work that already passed its gate.
r=$(subrepo feat/g8 false)
printf 'kept\n' > "$r/sub/first.txt"      # an earlier phase's file, below the cwd
snap=$( cd "$r" && bash "$SH" snapshot )
printf 'lost\n' > "$r/sub/second.txt"
( cd "$r/sub" && bash "$SH" gate review "$snap" ) >/dev/null 2>&1
check "a subdirectory revert spares an earlier phase's file" \
  "$([ -e "$r/sub/first.txt" ] && echo yes || echo no)" "yes"
check "and still removes this phase's" \
  "$([ -e "$r/sub/second.txt" ] && echo yes || echo no)" "no"

# The snapshotless fallback is repo-anchored too, or a phase run from a
# subdirectory keeps every edit above it under a line that says it was undone.
r=$(subrepo feat/g9 false)
printf 'above\n' >> "$r/w.txt"; printf 'made\n' > "$r/made.txt"
( cd "$r/sub" && bash "$SH" gate review ) >/dev/null 2>&1
check "the snapshotless fallback reaches above the cwd" "$(grep -c above "$r/w.txt")" "0"
check "and cleans above it" \
  "$([ -e "$r/made.txt" ] && echo present || echo gone)" "gone"

echo "report"
r=$(work_repo feat/rep)
out=$( printf 'phase=architecture result=pass files=1\n' | ( cd "$r" && bash "$SH" report ) )
check "echoes what it was given" "$(printf '%s' "$out" | grep -c '^phase=architecture')" "1"

TB=$(mktemp -d)
mk_tracker() { printf '%s' "$1" > "$TB/tracking.sh"; chmod +x "$TB/tracking.sh"; : > "$TB/track"; : > "$TB/body"; }

mk_tracker '#!/usr/bin/env bash
echo "$@" >> '"$TB"'/track
cat > /dev/null'
printf 'phase=x result=pass files=0\n' | ( cd "$r" && ISO_TRACKING_SH="$TB/tracking.sh" bash "$SH" report ) >/dev/null 2>&1
check "no ticket means no comment" "$(grep -c '^comment' "$TB/track")" "0"

# With a ticket, the same text that reached the terminal reaches the board.
mk_tracker '#!/usr/bin/env bash
echo "$@" >> '"$TB"'/track
case "$1" in
  ticket-for-branch) printf "FIRE-9\ttodo\n" ;;
  comment) cat >> '"$TB"'/body ;;
esac'
printf 'phase=x result=pass files=0\nphase=y result=revert files=0\n' \
  | ( cd "$r" && ISO_TRACKING_SH="$TB/tracking.sh" bash "$SH" report ) >/dev/null 2>&1
check "a ticket gets one comment"   "$(grep -c '^comment FIRE-9' "$TB/track")" "1"
check "and the body is the summary" "$(grep -c '^phase=' "$TB/body")" "2"

# Capped under the tracker's own comment limit, so the terminal and the board
# hold the same text rather than the board silently holding a shorter one.
mk_tracker '#!/usr/bin/env bash
case "$1" in ticket-for-branch) printf "FIRE-9\ttodo\n" ;; comment) cat >> '"$TB"'/body ;; esac'
head -c 500 /dev/zero | tr '\0' 'x' \
  | ( cd "$r" && ISO_TRACKING_SH="$TB/tracking.sh" ISO_REVIEW_REPORT_CAP=100 bash "$SH" report ) >/dev/null 2>&1
check "the body is capped" "$(wc -c < "$TB/body" | tr -d ' ')" "101"

# A tracker that is absent or angry must not fail the report: the refine already
# happened, and the working tree is the deliverable.
mk_tracker '#!/usr/bin/env bash
exit 3'
printf 'phase=x result=pass files=0\n' \
  | ( cd "$r" && ISO_TRACKING_SH="$TB/tracking.sh" bash "$SH" report ) >/dev/null 2>&1
check "a broken tracker does not fail the report" "$?" "0"
rm -rf "$TB"

echo "scope without a base still prints the recovery sha"

# `scope` with no <base> re-runs preflight, whose `git add -A` flattens any
# hand-staged index. That makes it the one path that both destroys a partial
# stage and -- until this was fixed -- withheld the sha that restores it.
r=$(newrepo); (
  cd "$r" && printf 'staged\n' > s.txt && git add s.txt && printf 'loose\n' > l.txt
) >/dev/null 2>&1
out=$( cd "$r" && bash "$SH" scope 2>/dev/null )
check "bare scope prints index=" "$(printf '%s\n' "$out" | grep -c '^index=[0-9a-f]\{40\}$')" "1"
check "bare scope still prints base=" "$(printf '%s\n' "$out" | grep -c '^base=')" "1"
# The sha must be a real tree, or "recovery is git read-tree <sha>" is a lie.
idx=$(printf '%s\n' "$out" | sed -n 's/^index=//p')
( cd "$r" && git cat-file -t "$idx" ) 2>/dev/null | grep -qx tree
check "and it names a real tree object" "$?" "0"
# Regression guard: preflight ASSIGNS REVIEW_BASE, so capturing it through a
# command substitution would set it in a dead subshell and scope would die on
# an unbound variable. It did, once.
check "and scope did not die unbound" "$(printf '%s\n' "$out" | grep -c 'unbound variable')" "0"
rm -rf "$r"

echo "skill-check sees both layouts and every root"

SK2=$(mktemp -d); SK3=$(mktemp -d)
mkdir -p "$SK2/dual" "$SK3/dual"

# A plugin command is `<name>.md`, not `<name>/SKILL.md`. Searching only the
# skill layout found an unblocked copy, reported ok, and never saw the blocked
# command at all -- a false green in the guard whose job is false greens.
printf -- '---\nname: cmd\ndisable-model-invocation: true\n---\n' > "$SK2/cmd.md"
out=$( ISO_REVIEW_SKILL_DIRS="$SK2" bash "$SH" skill-check cmd ); rc=$?
check "a blocked plugin command is found" \
  "$(printf '%s' "$out" | grep -c '^skill=cmd state=blocked')" "1"
check "and exits 1" "$rc" "1"

# Copies disagreeing is the real hazard: which one answers decides whether the
# phase runs, and nothing here can predict the resolution order.
printf -- '---\nname: dual\n---\n' > "$SK2/dual/SKILL.md"
printf -- '---\nname: dual\ndisable-model-invocation: true\n---\n' > "$SK3/dual/SKILL.md"
out=$( ISO_REVIEW_SKILL_DIRS="$SK2 $SK3" bash "$SH" skill-check dual ); rc=$?
check "disagreeing copies report split" \
  "$(printf '%s' "$out" | grep -c '^skill=dual state=split')" "1"
check "and name the blocked one" "$(printf '%s' "$out" | grep -c "$SK3/dual/SKILL.md")" "1"
check "and name the open one" "$(printf '%s' "$out" | grep -c "$SK2/dual/SKILL.md")" "1"
check "and exit 1" "$rc" "1"

# Agreeing copies are invocable either way, so this is reportable, not fatal --
# but the count has to show, or a duplicate skill stays invisible.
printf -- '---\nname: dual\n---\n' > "$SK3/dual/SKILL.md"
out=$( ISO_REVIEW_SKILL_DIRS="$SK2 $SK3" bash "$SH" skill-check dual ); rc=$?
check "agreeing copies are ok" "$(printf '%s' "$out" | grep -c '^skill=dual state=ok')" "1"
check "and the count is reported" "$(printf '%s' "$out" | grep -c 'copies=2')" "1"
check "and exit 0" "$rc" "0"

# A root that does not exist must cost nothing: an unmatched glob stays
# literal, which [ -f ] rejects.
out=$( ISO_REVIEW_SKILL_DIRS="$SK2 /nope/*/skills" bash "$SH" skill-check cmd ); rc=$?
check "a missing root is harmless" "$(printf '%s' "$out" | grep -c '^skill=cmd state=blocked')" "1"
rm -rf "$SK2" "$SK3"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

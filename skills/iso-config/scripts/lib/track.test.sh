#!/usr/bin/env bash
# Self-check for track.sh. Run: bash track.test.sh
# ponytail: asserts on the two things a wrong answer breaks silently — that the
# stub seam is honoured (or no self-check downstream can stub the tracker), and
# that nothing here can fail a caller running under `set -e`.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/track.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

# shellcheck source=/dev/null
. "$LIB"
type iso_track_path >/dev/null 2>&1 || { echo "FATAL: no iso_track_path"; exit 1; }
type iso_track >/dev/null 2>&1 || { echo "FATAL: sourcing did not define iso_track"; exit 1; }
type iso_sibling >/dev/null 2>&1 || { echo "FATAL: track.sh did not pull in sibling.sh"; exit 1; }

tmp=$(mktemp -d)
# The stub lives OUTSIDE the fixture repo: its call log is a file, and a log
# written inside the repo would dirty the tree that other assertions read.
BIN="$tmp/bin"; mkdir -p "$BIN"
repo="$tmp/repo"; mkdir -p "$repo"; ( cd "$repo" && git init -q -b dev . )

cat > "$BIN/tracking.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
case "$1" in
  loud)  printf 'to-stderr\n' >&2; printf 'to-stdout\n' ;;
  angry) exit 3 ;;
  *)     printf 'said:%s\n' "$*" ;;
esac
STUB
chmod +x "$BIN/tracking.sh"
printf '#!/bin/sh\n' > "$BIN/noexec.sh"   # deliberately not chmod +x

echo "the stub seam"
cd "$repo" || exit 1
export ISO_TRACKING_SH="$BIN/tracking.sh"
check "stdout comes back"      "$(iso_track branch-of dev)"      "said:branch-of dev"
check "every argument arrives" "$(tail -1 "$BIN/calls")"         "branch-of dev"
check "no args is fine"        "$(iso_track ping)"               "said:ping"

echo "presence, separately from an answer"
# push.sh reports an unlinked PR to a human: it must be able to tell "no tracker
# here" (say nothing) from "tracker, but no row for this branch" (warn).
check "the runnable tracker is named"    "$(iso_track_path)"   "$BIN/tracking.sh"
check "a missing one names nothing"      "$(ISO_TRACKING_SH="$BIN/absent.sh" iso_track_path)" ""
check "a non-executable one names nothing" "$(ISO_TRACKING_SH="$BIN/noexec.sh" iso_track_path)" ""

echo "stderr belongs to the call site"
# The one real variation between the old copies: iso-write's cmd_track wants a
# failed transition visible. A flag here would have made every other caller
# carry it; a redirection at the call site costs nothing.
out=$(iso_track loud 2>/dev/null)
check "stdout survives a silencing redirect" "$out" "to-stdout"
err=$(iso_track loud 2>&1 >/dev/null)
check "stderr passes through by default"     "$err" "to-stderr"

echo "never fatal"
iso_track angry >/dev/null 2>&1
check "a failing verb still exits 0" "$?" "0"

ISO_TRACKING_SH="$BIN/absent.sh"
out=$(iso_track branch-of dev); rc=$?
check "a missing tracker exits 0" "$rc" "0"
check "a missing tracker is silent" "$out" ""

ISO_TRACKING_SH="$BIN/noexec.sh"
out=$(iso_track branch-of dev); rc=$?
check "a non-executable tracker exits 0" "$rc" "0"
check "a non-executable tracker is silent" "$out" ""

echo "outside a repo"
ISO_TRACKING_SH="$BIN/tracking.sh"
before=$(wc -l < "$BIN/calls")
cd "$tmp" || exit 1                        # $tmp is not a git repo
out=$(iso_track branch-of dev)
check "no repo means no answer" "$out" ""
check "no repo means the tracker is never run" "$(wc -l < "$BIN/calls")" "$before"

echo "a set -e caller survives"
# The regression this file exists to catch: one unguarded non-zero in iso_track
# kills every skill that sources it, and only on the machine with no tracker.
for verb in angry branch-of; do
  for t in "$BIN/tracking.sh" "$BIN/absent.sh"; do
    ( set -euo pipefail
      cd "$repo" || exit 9
      # shellcheck source=/dev/null
      . "$LIB"
      ISO_TRACKING_SH="$t" iso_track "$verb" >/dev/null 2>&1
      exit 0 ) >/dev/null 2>&1
    check "set -e survives $verb via $(basename "$t")" "$?" "0"
  done
done

echo "no tracker installed at all"
# The invariant this whole file exists for, and the one the suite could not
# reach: ISO_TRACKING_SH unset AND iso_sibling finding nothing, so $sh is empty
# rather than a path that fails -x. Inside this repo iso_sibling always
# resolves, so the only way to stage it is to make iso_sibling fail.
( set -euo pipefail
  cd "$repo" || exit 9
  # shellcheck source=/dev/null
  . "$LIB"
  unset ISO_TRACKING_SH
  iso_sibling() { return 1; }          # a machine with no iso-issue-tracking
  [ -z "$(iso_track_path)" ]          || exit 1
  [ -z "$(iso_track branch-of dev)" ] || exit 2
  # Bare, not wrapped: a command substitution swallows the status, so only an
  # unwrapped call can catch a missing `|| true` on the resolution. This is
  # iso-plan's exact shape -- `cmd_tracker() { iso_track_path; }` in a case arm.
  iso_track_path
  iso_track rebranch a b >/dev/null 2>&1
  exit 0 ) >/dev/null 2>&1
check "an unresolvable tracker is silent and never fatal" "$?" "0"

echo "real resolution"
# With no override, iso_sibling must find the tracker from track.sh's own
# directory — not from the caller's. Getting this wrong is invisible until a
# skill runs installed. Proven by making the real tracking.sh leave a trace: an
# unknown verb is logged and nothing else happens.
unset ISO_TRACKING_SH
export ISO_TRACKER_STATE_DIR="$tmp/state"   # never the user's real ledger
mkdir -p "$ISO_TRACKER_STATE_DIR"
cd "$repo" || exit 1
iso_track __nope__ >/dev/null 2>&1
check "iso_track reaches the real tracking.sh with no override" \
  "$(grep -c 'unknown subcommand: __nope__' "$ISO_TRACKER_STATE_DIR/log" 2>/dev/null || echo 0)" "1"

rm -rf "$tmp"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

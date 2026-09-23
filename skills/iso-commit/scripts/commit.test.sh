#!/usr/bin/env bash
# Self-check for commit.sh. Run: bash commit.test.sh
# ponytail: one file, asserts only the logic that can silently do harm —
# the secret guard and the preflight refusals. No framework.
set -uo pipefail

SH="$(cd "$(dirname "$0")" && pwd)/commit.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }

newrepo() {
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '%s' "$d"
}

echo "guard:"
d=$(newrepo); ( cd "$d" && touch app.js .env ); \
  (cd "$d" && bash "$SH" guard >/dev/null 2>&1); check ".env blocks" "$?" 2
d=$(newrepo); ( cd "$d" && touch app.js .env.example ); \
  (cd "$d" && bash "$SH" guard >/dev/null 2>&1); check ".env.example allowed" "$?" 0
d=$(newrepo); ( cd "$d" && mkdir -p k && touch k/server.pem ); \
  (cd "$d" && bash "$SH" guard >/dev/null 2>&1); check "nested .pem blocks" "$?" 2
d=$(newrepo); ( cd "$d" && touch id_ed25519 ); \
  (cd "$d" && bash "$SH" guard >/dev/null 2>&1); check "ssh key blocks" "$?" 2
d=$(newrepo); ( cd "$d" && touch keychain.js ); \
  (cd "$d" && bash "$SH" guard >/dev/null 2>&1); check "keychain.js not a false hit" "$?" 0

echo "preflight:"
d=$(mktemp -d); (cd "$d" && bash "$SH" preflight >/dev/null 2>&1); \
  check "non-repo refused" "$?" 1
d=$(newrepo); (cd "$d" && bash "$SH" preflight >/dev/null 2>&1); \
  check "clean tree refused" "$?" 1
d=$(newrepo); ( cd "$d" && touch a.txt ); \
  (cd "$d" && bash "$SH" preflight >/dev/null 2>&1); check "dirty tree passes" "$?" 0
d=$(newrepo); ( cd "$d" && touch a.txt && git add -A && git commit -qm x && git checkout -q --detach ); \
  (cd "$d" && bash "$SH" preflight >/dev/null 2>&1); check "detached HEAD refused" "$?" 1
d=$(newrepo); ( cd "$d" && touch a.txt ); \
  (cd "$d" && bash "$SH" preflight --staged >/dev/null 2>&1); check "--staged with empty index refused" "$?" 1

echo "commit:"
d=$(newrepo); ( cd "$d" && touch a.txt )
printf 'feat(x): thing\n\n- did a thing\n' > "$d/msg"
(cd "$d" && bash "$SH" stage >/dev/null 2>&1 && bash "$SH" commit msg >/dev/null 2>&1); \
  check "stage+commit succeeds" "$?" 0
check "body preserved" "$(git -C "$d" log -1 --format=%b | tr -d '\n')" "- did a thing"
# The old form here grepped a message nothing had touched, so it could only
# ever return 0 -- it asserted git's behaviour, not this script's, and passed
# even when the commit above had failed and there was nothing to read. The
# message file is not the last word on what lands: prepare-commit-msg hooks,
# commit.template and trailer.* config all append AFTER it, and --no-verify
# does not stop prepare-commit-msg. So drive the real failure mode.
check "no AI trailer" "$(git -C "$d" log -1 --format=%B | grep -ci 'co-authored-by' || true)" "0"

d=$(newrepo); ( cd "$d" && touch a.txt )
mkdir -p "$d/.git/hooks"
cat > "$d/.git/hooks/prepare-commit-msg" <<'HOOK'
#!/usr/bin/env bash
printf '\nCo-Authored-By: Claude <noreply@anthropic.com>\n' >> "$1"
HOOK
chmod +x "$d/.git/hooks/prepare-commit-msg"
printf 'feat(x): thing\n\n- did a thing\n' > "$d/msg"
out=$( cd "$d" && bash "$SH" stage >/dev/null 2>&1 && bash "$SH" commit msg 2>&1 ); rc=$?
check "an injected trailer fails the commit" "$rc" "1"
check "and the offending line is shown" \
  "$(printf '%s' "$out" | grep -ci 'co-authored-by')" "1"
# The remedy has to survive the injector. A bare `git commit --amend` re-runs
# prepare-commit-msg -- the very hook that put the trailer there -- so advice
# that omits the hook bypass sends the user into a loop.
check "and it says how to fix it" "$(printf '%s' "$out" | grep -c 'commit --amend')" "1"
check "and the fix bypasses the hook that injected it" \
  "$(printf '%s' "$out" | grep -c 'core.hooksPath')" "1"
rm -rf "$d"

# A body that merely mentions the word is not a violation -- the guard is
# anchored to trailer shapes, and a guard that fires on prose gets disabled.
d=$(newrepo); ( cd "$d" && touch a.txt )
printf 'fix(parse): handle claude model ids\n\n- generated with the new fixture\n' > "$d/msg"
( cd "$d" && bash "$SH" stage >/dev/null 2>&1 && bash "$SH" commit msg >/dev/null 2>&1 )
check "prose mentioning claude still commits" "$?" "0"
rm -rf "$d"

echo "branch gate"
export ISO_GLOBAL_CONFIG=/nonexistent
export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)
r=$(mktemp -d)
git init -q -b dev "$r"
git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
git -C "$r" commit -q --allow-empty -m init

g_act() { ( cd "$r" && bash "$SH" gate "$1" ) | sed -n 's/^action=//p'; }
g_brn() { ( cd "$r" && bash "$SH" gate "$1" ) | sed -n 's/^branch=//p'; }

check "on dev, a subject yields a create" "$(g_act 'feat(auth): add token refresh')" "create"
check "named from the subject" "$(g_brn 'feat(auth): add token refresh')" "feat/auth-add-token-refresh"
check "no subject yields ask" "$(g_act '')" "ask"

( cd "$r" && git checkout -q -b feat/existing )
check "on a feature branch, stay" "$(g_act 'feat: whatever')" "stay"
check "stay names the current branch" "$(g_brn 'feat: whatever')" "feat/existing"

echo "landing"
( cd "$r" && git checkout -q dev )
BINC=$(mktemp -d)
cat > "$BINC/tracking.sh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$TRACK_CALLS"
STUB
chmod +x "$BINC/tracking.sh"
export TRACK_CALLS="$BINC/calls"; : > "$TRACK_CALLS"

got=$( cd "$r" && ISO_TRACKING_SH="$BINC/tracking.sh" bash "$SH" land create feat/landed )
check "land prints the branch" "$got" "feat/landed"
check "land checked it out" "$(git -C "$r" branch --show-current)" "feat/landed"
grep -q 'rebranch dev feat/landed' "$TRACK_CALLS" \
  && ok "landing rebinds off the old branch" || bad "landing did not rebind"

# Staged work must survive the move, or the commit that follows is empty.
( cd "$r" && git checkout -q dev )
printf 'x\n' > "$r/staged.txt"; git -C "$r" add staged.txt
( cd "$r" && ISO_TRACKING_SH="$BINC/tracking.sh" bash "$SH" land create feat/carried ) >/dev/null
check "staged work carried across" "$(git -C "$r" diff --cached --name-only)" "staged.txt"

: > "$TRACK_CALLS"
( cd "$r" && ISO_TRACKING_SH="$BINC/tracking.sh" bash "$SH" land stay feat/carried ) >/dev/null
check "stay does not move" "$(git -C "$r" branch --show-current)" "feat/carried"
check "stay does not rebind" "$(wc -l < "$TRACK_CALLS" | tr -d ' ')" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

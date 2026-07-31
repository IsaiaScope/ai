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
check "no AI trailer" "$(git -C "$d" log -1 --format=%B | grep -ci 'co-authored-by\|claude' || true)" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

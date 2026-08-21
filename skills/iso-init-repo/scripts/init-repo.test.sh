#!/usr/bin/env bash
# ponytail: no network - a local bare repo stands in for origin, which is enough
# for every git-level verb. Asserts the request bodies, the branch order, the
# ladder's ancestry, the ancestor guard that keeps `retire-main` from deleting
# work, and all three shapes of pre-push hook assembly.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/init-repo.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

t=$(mktemp -d); ( cd "$t" && git init -q -b main . ); cd "$t" || exit 1
export ISO_GLOBAL_CONFIG=/nonexistent

echo "branch names"
check "default order" "$(bash "$SH" branches | tr '\n' ' ')" "dev test prod "
check "default branch defaults to development" "$(bash "$SH" default-branch)" "dev"

echo "overlay wins"
mkdir -p docs/iso
printf '%s\n' '{"branches":{"default":"prod"}}' > docs/iso/config.json
check "overlay sets default branch" "$(bash "$SH" default-branch)" "prod"
check "branch list unaffected" "$(bash "$SH" branches | tr '\n' ' ')" "dev test prod "
printf '%s\n' '{"branches":{"development":"trunk","test":"stage","production":"live"}}' > docs/iso/config.json
check "overlay renames the whole ladder" "$(bash "$SH" branches | tr '\n' ' ')" "trunk stage live "
check "default follows development" "$(bash "$SH" default-branch)" "trunk"
rm -f docs/iso/config.json

echo "protection body"
out=$(bash "$SH" protection-json dev)
check "is valid json"     "$(printf '%s' "$out" | jq -r 'type')" "object"
check "requires a PR"     "$(printf '%s' "$out" | jq -r '.required_pull_request_reviews != null')" "true"
check "blocks force push" "$(printf '%s' "$out" | jq -r '.allow_force_pushes')" "false"
check "blocks deletion"   "$(printf '%s' "$out" | jq -r '.allow_deletions')" "false"
check "development has no gate" "$(printf '%s' "$out" | jq -r '.required_status_checks.contexts | length')" "0"

for b in test prod; do
  out=$(bash "$SH" protection-json "$b")
  check "$b requires the gate" \
    "$(printf '%s' "$out" | jq -r '.required_status_checks.contexts[0]')" "Verify Source Branch"
done

echo "the gate follows renamed branches"
mkdir -p docs/iso
printf '%s\n' '{"branches":{"test":"stage"}}' > docs/iso/config.json
check "renamed staging still gated" \
  "$(bash "$SH" protection-json stage | jq -r '.required_status_checks.contexts[0]')" "Verify Source Branch"
check "old name no longer gated" \
  "$(bash "$SH" protection-json test | jq -r '.required_status_checks.contexts | length')" "0"


# --- git-level verbs, against a local bare "origin" ---------------------

SKILL_DIR="$(cd "$(dirname "$SH")/.." && pwd)"
newrepo() {   # echoes a fresh work tree whose origin is a local bare repo
  local d bare
  d=$(mktemp -d); bare=$(mktemp -d)
  git init -q --bare "$bare"
  ( cd "$d" && git init -q -b main . \
      && git config user.email t@e && git config user.name t \
      && git commit -q --allow-empty -m first \
      && git remote add origin "$bare" && git push -q -u origin main ) >/dev/null 2>&1
  printf '%s\n' "$d"
}

echo "create-branches"
r=$(newrepo); ( cd "$r" && bash "$SH" create-branches ) >/dev/null 2>&1
check "all three branches reach origin" \
  "$(cd "$r" && git ls-remote --heads origin | grep -cE 'refs/heads/(dev|test|prod)$')" "3"
# Ancestry is the whole point of creating them in reverse: dev and test are cut
# from prod, not from each other.
check "test descends from prod" \
  "$(cd "$r" && git merge-base --is-ancestor origin/prod origin/test && echo yes)" "yes"
check "dev descends from prod" \
  "$(cd "$r" && git merge-base --is-ancestor origin/prod origin/dev && echo yes)" "yes"
out=$(cd "$r" && bash "$SH" create-branches 2>&1)
check "a second run creates nothing" "$(printf '%s' "$out" | grep -c skip)" "3"

echo "retire-main"
r2=$(newrepo); ( cd "$r2" && bash "$SH" create-branches ) >/dev/null 2>&1
( cd "$r2" && bash "$SH" retire-main main ) >/dev/null 2>&1
check "main is gone once prod contains it" \
  "$(cd "$r2" && git ls-remote --heads origin | grep -c 'refs/heads/main$')" "0"

# The guard that matters: main carrying work prod has never seen must survive.
r3=$(newrepo); ( cd "$r3" && bash "$SH" create-branches ) >/dev/null 2>&1
( cd "$r3" && git checkout -q main && git commit -q --allow-empty -m stray && git push -q origin main ) >/dev/null 2>&1
out=$(cd "$r3" && bash "$SH" retire-main main 2>&1)
check "main with unmerged work survives" \
  "$(cd "$r3" && git ls-remote --heads origin | grep -c 'refs/heads/main$')" "1"
case "$out" in *"not in prod"*) ok "and says why" ;; *) bad "no reason given: $out" ;; esac
out=$(cd "$r3" && bash "$SH" retire-main dev 2>&1)
case "$out" in *"did not start on main"*) ok "a repo that never had main is skipped" ;;
  *) bad "wrong skip reason: $out" ;; esac

echo "gate-context"
gc=$(mktemp -d)
printf 'name: x\non: [pull_request]\njobs:\n  gate:\n    name: Verify Source Branch\n    runs-on: ubuntu-latest\n' > "$gc/wf.yml"
check "job name read from the workflow" "$(bash "$SH" gate-context "$gc/wf.yml")" "Verify Source Branch"
printf 'jobs:\n  gate:\n    runs-on: ubuntu-latest\n' > "$gc/nameless.yml"
( bash "$SH" gate-context "$gc/nameless.yml" >/dev/null 2>&1 )
check "a workflow with no job name is refused" "$?" "1"

echo "install-hook: three shapes"
h=$(newrepo); ( cd "$h" && bash "$SH" install-hook ) >/dev/null 2>&1
check "hook is executable" "$(cd "$h" && [ -x .githooks/pre-push ] && echo yes)" "yes"
check "hooksPath points at it" "$(cd "$h" && git config core.hooksPath)" ".githooks"
check "guard body present once" \
  "$(cd "$h" && grep -c '^# >>> iso-init-repo branch guard >>>$' .githooks/pre-push)" "1"
( cd "$h" && bash "$SH" install-hook ) >/dev/null 2>&1
check "re-running does not duplicate the guard" \
  "$(cd "$h" && grep -c '^# >>> iso-init-repo branch guard >>>$' .githooks/pre-push)" "1"

# An unmarked hook someone else wrote: splice above the rc summary, keep theirs.
h2=$(newrepo)
( cd "$h2" && mkdir -p .githooks && printf '#!/usr/bin/env bash\nrc=0\necho theirs\nif [ "$rc" -ne 0 ]; then\n  echo blocked\nfi\nexit "$rc"\n' > .githooks/pre-push )
( cd "$h2" && bash "$SH" install-hook ) >/dev/null 2>&1
check "existing hook body survives the splice" "$(cd "$h2" && grep -c 'echo theirs' .githooks/pre-push)" "1"
check "guard spliced in above the summary" \
  "$(cd "$h2" && awk '/iso-init-repo branch guard/{g=NR} /^if \[ "\$rc" -ne 0 \]/{s=NR} END{print (g<s)?"yes":"no"}' .githooks/pre-push)" "yes"

echo "verify-hook"
( cd "$h" && bash "$SH" verify-hook ) >/dev/null 2>&1
check "a correct hook verifies" "$?" "0"
# A hook that pushes nothing back is a hook that protects nothing.
( cd "$h" && printf '#!/usr/bin/env bash\nexit 0\n' > .githooks/pre-push && chmod +x .githooks/pre-push )
( cd "$h" && bash "$SH" verify-hook ) >/dev/null 2>&1
check "a permissive hook is refused" "$?" "1"
# Correct hook, never consulted: the failure the hooksPath check exists for.
( cd "$h2" && git config --unset core.hooksPath )
( cd "$h2" && bash "$SH" verify-hook ) >/dev/null 2>&1
check "an unconsulted hook is refused" "$?" "1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

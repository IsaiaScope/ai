#!/usr/bin/env bash
# iso-init-repo mechanics: everything about repository governance that a test can
# reach. The narrative — why dev<-test<-prod, what the gate is for — stays in
# SKILL.md, and so do the three steps that genuinely cannot be tested: `gh repo
# create`, `gh auth status`, and the protection PUTs. Everything else lives here
# because prose is re-derived by a model on every run and asserts nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

die() { printf 'iso-init-repo: %s\n' "$1" >&2; exit 1; }
TEMPLATES="$HERE/../templates"
GUARD="$TEMPLATES/pre-push-branch-guard.sh"
HOOK=.githooks/pre-push
WORKFLOW=.github/workflows/ci-branch-gate.yml

# The promotion ladder, in order. Always three names, whatever they are called.
cmd_branches() {
  iso_config_get branches.development
  iso_config_get branches.test
  iso_config_get branches.production
}

# What GitHub serves as the repository default. Distinct from the development
# branch: a marketplace repository wants consumers cloning released work, so
# this repository sets it to `prod` in its overlay. Re-running init must read
# that, not overwrite it.
cmd_default_branch() {
  local d; d=$(iso_config_get branches.default)
  [ -n "$d" ] && printf '%s\n' "$d" || iso_config_get branches.development
}

# The gate runs on the two branches work is promoted INTO, never on the one it
# is promoted FROM — a PR into test must have come from development, and a PR
# into production from test. Matched by configured name, so renaming a branch
# moves its gate with it.
cmd_protection_json() {
  local branch="${1:?usage: init-repo.sh protection-json <branch>}"
  local test_branch production checks
  test_branch=$(iso_config_get branches.test)
  production=$(iso_config_get branches.production)
  # null, not an empty contexts list: an empty list with strict:true would make
  # the development branch require an up-to-date ref, which it never has. This
  # matches the body the skill has always PUT.
  case "$branch" in
    "$test_branch"|"$production") checks='{"strict":false,"contexts":["Verify Source Branch"]}' ;;
    *)                            checks='null' ;;
  esac
  jq -n --argjson c "$checks" '{
    required_status_checks: $c,
    enforce_admins: false,
    required_pull_request_reviews: { required_approving_review_count: 0 },
    restrictions: null,
    allow_force_pushes: false,
    allow_deletions: false
  }'
}


# --- the ladder ---------------------------------------------------------

# Ladder order is development, test, production; creation order is the reverse.
# Production is cut from whatever the repository's head already was, and the
# other two are cut from production - creating them in ladder order would give
# each branch the wrong ancestor.
cmd_create_branches() {
  local head b parent production
  head=$(git symbolic-ref --short HEAD) || die "detached HEAD - check out a branch first"
  production=$(iso_config_get branches.production)
  git fetch -q origin 2>/dev/null || true
  for b in $(cmd_branches | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'); do
    if git rev-parse --verify -q "origin/$b" >/dev/null; then
      printf '  skip   %s already on origin\n' "$b"
      continue
    fi
    parent="$production"
    [ "$b" = "$production" ] && parent="$head"
    git checkout -q -b "$b" "$parent" 2>/dev/null || git checkout -q "$b"
    git push -q -u origin "$b" || die "could not push $b to origin"
    printf '  ok     %s created from %s\n' "$b" "$parent"
  done
}

# Retire the branch the repository started on, but only when production already
# contains every commit it carries. The ancestor test is the whole safety
# property: without it this deletes work, and `--is-ancestor` returning non-zero
# for "unknown ref" as well as "not an ancestor" is why the check is positive
# rather than negated.
cmd_retire_main() {
  local was="${1:?usage: init-repo.sh retire-main <original-head>}" production
  production=$(iso_config_get branches.production)
  [ "$was" = main ] || { printf '  skip   repository did not start on main (%s)\n' "$was"; return 0; }
  git rev-parse --verify -q origin/main >/dev/null \
    || { printf '  skip   no main branch to remove\n'; return 0; }
  git rev-parse --verify -q "origin/$production" >/dev/null \
    || { printf '  skip   %s not on origin yet\n' "$production"; return 0; }
  if git merge-base --is-ancestor origin/main "origin/$production" 2>/dev/null; then
    git push -q origin --delete main
    git branch -q -D main 2>/dev/null || true
    printf '  ok     main retired into %s\n' "$production"
  else
    printf '  warn   main has commits not in %s - merge them first, leaving it\n' "$production"
  fi
}

# --- the branch gate ----------------------------------------------------

# absent | stale | current. The gate has to be ON the development branch at
# origin before protection can require it, so this is the question the skill
# asks before deciding whether to write the workflow at all.
cmd_gate_status() {
  local development
  development=$(iso_config_get branches.development)
  git fetch -q origin 2>/dev/null || true
  git cat-file -e "origin/$development:$WORKFLOW" 2>/dev/null || { echo absent; return 0; }
  if git show "origin/$development:$WORKFLOW" 2>/dev/null | diff -q - "$TEMPLATES/ci-branch-gate.yml" >/dev/null 2>&1
  then echo current; else echo stale; fi
}

# The status-check context GitHub will require is the workflow's first job name,
# so it is read from the file rather than restated - a name typed twice is a
# name that drifts, and the drift shows up as a branch permanently un-mergeable.
cmd_gate_context() {
  local f="${1:-$WORKFLOW}" name
  [ -f "$f" ] || die "workflow not found: $f"
  name=$(awk '/^jobs:/{f=1} f && /^ {4}name:/{sub(/^ *name: */,""); print; exit}' "$f")
  [ -n "$name" ] || die "could not read a job name from $f"
  printf '%s\n' "$name"
}

# --- the pre-push hook --------------------------------------------------

# Three shapes of existing hook, one command. Fresh: write header, guard, rc
# summary. Marked: replace between the markers. Unmarked: splice in above the rc
# summary, or above the final exit if there is none. Prose could describe this;
# only a script can be asked whether it still does it.
cmd_install_hook() {
  local anchor
  [ -f "$GUARD" ] || die "guard template missing: $GUARD"
  mkdir -p "$(dirname "$HOOK")"

  if [ ! -f "$HOOK" ]; then
    { printf '#!/usr/bin/env bash\nset -uo pipefail\nrc=0\n\n'
      cat "$GUARD"
      printf '\nif [ "$rc" -ne 0 ]; then\n  echo "pre-push: blocked." >&2\nfi\nexit "$rc"\n'
    } > "$HOOK"
    printf '  ok     hook written\n'
  elif grep -q '^# >>> iso-init-repo branch guard >>>$' "$HOOK"; then
    awk -v f="$GUARD" '
      /^# >>> iso-init-repo branch guard >>>$/ { while ((getline l < f) > 0) print l; close(f); skip=1; next }
      /^# <<< iso-init-repo branch guard <<<$/ { skip=0; next }
      !skip
    ' "$HOOK" > "$HOOK.new" && mv "$HOOK.new" "$HOOK"
    printf '  ok     guard refreshed in place\n'
  else
    anchor=$(grep -n '^if \[ "\$rc" -ne 0 \]' "$HOOK" | head -1 | cut -d: -f1)
    if [ -z "$anchor" ]; then
      anchor=$(grep -n '^exit ' "$HOOK" | tail -1 | cut -d: -f1)
      printf '  warn   no rc summary found - inserting before the final exit\n'
    fi
    [ -n "$anchor" ] || die "cannot find an insertion point in $HOOK; add the guard by hand"
    { head -n $((anchor - 1)) "$HOOK"
      cat "$GUARD"; echo
      tail -n +"$anchor" "$HOOK"
    } > "$HOOK.new" && mv "$HOOK.new" "$HOOK"
    printf '  ok     guard spliced into the existing hook\n'
  fi

  chmod +x "$HOOK"
  # Per-clone, not committed, not automatic: without this git ignores .githooks
  # entirely and the hook that was just written protects nothing.
  git config core.hooksPath .githooks
}

# Prove the hook refuses what it exists to refuse. A hook that is present,
# executable and wrong is the failure this catches - and the hooksPath check
# catches a hook that is perfectly correct and never consulted.
cmd_verify_hook() {
  local production sha
  production=$(iso_config_get branches.production)
  [ -x "$HOOK" ] || die "$HOOK missing or not executable"
  sha=$(git rev-parse HEAD)
  if printf 'refs/heads/%s %s refs/heads/%s %s\n' "$production" "$sha" "$production" "$sha" \
     | "$HOOK" origin "$(git remote get-url origin 2>/dev/null || echo none)" >/dev/null 2>&1
  then die "hook did not refuse a push to $production"; fi
  [ "$(git config core.hooksPath)" = .githooks ] \
    || die "core.hooksPath is not .githooks - git will ignore this hook"
  printf '  ok     hook refuses %s, hooksPath set\n' "$production"
}

case "${1:-}" in
  branches)        cmd_branches ;;
  default-branch)  cmd_default_branch ;;
  protection-json) shift; cmd_protection_json "$@" ;;
  create-branches) cmd_create_branches ;;
  retire-main)     shift; cmd_retire_main "$@" ;;
  gate-status)     cmd_gate_status ;;
  gate-context)    shift; cmd_gate_context "$@" ;;
  install-hook)    cmd_install_hook ;;
  verify-hook)     cmd_verify_hook ;;
  *) die "usage: init-repo.sh branches | default-branch | protection-json <branch>
       | create-branches | retire-main <original-head> | gate-status
       | gate-context [file] | install-hook | verify-hook" ;;
esac

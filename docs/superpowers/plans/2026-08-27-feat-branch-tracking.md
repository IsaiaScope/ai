# Branch tracking across iso-* skills — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a ticket's `Branch` property and its ledger row name the branch the work is actually implemented on, and give every `iso-*` skill one shared answer to "am I standing on a branch I should be working on?".

**Architecture:** A new pure library `skills/iso-config/scripts/lib/branch.sh` becomes the only reader of `branches.protected` and the only place branch names are derived. It exports `iso_branch_gate`, which takes the current branch, the ticket's branch, and a proposed name, and prints a verdict (`stay`/`checkout`/`create`/`ask`). A new `rebranch` verb in `tracking.sh` rewrites both the ledger row and the board property; a matching `branch-of` verb reads the ledger row back. `iso-write`, `iso-commit`, and `iso-push` each call the gate and then `rebranch`.

**Tech Stack:** Bash 3.2 (macOS default — no associative arrays, no `${var,,}`), `jq`, `git`, the `multica` CLI behind `skills/iso-issue-tracking/scripts/adapters/multica.sh`. No build step. Tests are plain bash scripts run directly.

**Spec:** `docs/superpowers/specs/2026-08-27-branch-tracking-design.md`

## Global Constraints

- **Never commit.** This repository's `CLAUDE.md` says commits happen only when the user asks, and `/iso-commit` is the only trigger. Every task below ends at green tests, not at a commit. The `- [ ] Commit` step that normally closes a task is deliberately absent.
- **Tests are ad hoc.** Run a suite with `bash <path>/<name>.test.sh` from anywhere. There is no runner and no framework. Each test file defines its own `ok` / `bad` / `check` helpers — copy the existing header verbatim.
- **Every test file must pass in full**, not just its new block. Re-run the whole file after each change.
- **Sibling skills resolve through `iso_sibling`**, never through an absolute `$HOME` path. `$HOME/.claude/skills/…` is correct under exactly one of the four install topologies.
- **Tracking must never fail a run.** Every call into `tracking.sh` from another skill is wrapped so a missing script, a missing tracker, or a miss returns 0. This is load-bearing: `write.sh:107` and `push.sh:438` already document it.
- **Prose in files is normal English.** Terse chat style does not apply to code comments, `SKILL.md` bodies, or docs.
- **Bash 3.2.** No `declare -A`, no `${var^^}`, no `readarray`.
- **Every test file that can reach `tracking.sh` must isolate the tracker's state.** From Task 3 onward, `write.sh`, `push.sh`, and `commit.sh` resolve the real `tracking.sh` through `iso_sibling`, and its default state directory is the user's live ledger (`tracking.sh:19-21`). Any suite that exercises those paths must export a throwaway one **before** the first invocation:

  ```bash
  export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)
  ```

  Without it a test run scribbles on real tickets. `ISO_TRACKER_STATE_DIR` is the first variable `tracking.sh` consults, ahead of `MULTICA_STATE_DIR` and the configured ledger path.
- After code changes, run `graphify update .` (AST-only, no API cost).

---

### Task 1: The shared branch library

**Files:**
- Create: `skills/iso-config/scripts/lib/branch.sh`
- Create: `skills/iso-config/scripts/lib/branch.test.sh`
- Modify: `skills/iso-config/SKILL.md` (add a "Branch policy" section)
- Modify: `AGENTS.md` (architecture tree gains `branch.sh`)

**Interfaces:**
- Consumes: `iso_config_get` from `skills/iso-config/scripts/lib/config.sh` (already exists; `branch.sh` lazily sources it if the caller has not).
- Produces, for Tasks 3-5:
  - `iso_is_protected <branch>` — exit 0 when the branch is protected. An empty argument (detached HEAD) counts as protected.
  - `iso_branch_from_plan <plan-path>` — prints `<type>/<slug>`; exits 1 on a filename with no `YYYY-MM-DD-` prefix or an empty slug.
  - `iso_branch_from_subject <commit-subject>` — prints `<type>/<slug>`; never fails on non-empty input.
  - `iso_branch_gate <current> <ticket-branch> <proposed>` — prints exactly two lines, `action=stay|checkout|create|ask` and `branch=<name>` (empty for `ask`).

- [x] **Step 1: Write the failing test**

Create `skills/iso-config/scripts/lib/branch.test.sh`:

```bash
#!/usr/bin/env bash
# Self-check for branch.sh. Run: bash branch.test.sh
# ponytail: asserts the gate matrix and the two name derivations — the places a
# wrong answer creates a branch nobody wanted or strands work on the wrong one.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

export ISO_GLOBAL_CONFIG=/nonexistent
# shellcheck source=/dev/null
. "$HERE/branch.sh"
type iso_branch_gate >/dev/null 2>&1 \
  || { echo "FATAL: sourcing did not define iso_branch_gate"; exit 1; }
type iso_config_get >/dev/null 2>&1 \
  || { echo "FATAL: branch.sh did not pull in config.sh"; exit 1; }

echo "iso_is_protected"
iso_is_protected dev        && ok "dev is protected"        || bad "dev not protected"
iso_is_protected main       && ok "main is protected"       || bad "main not protected"
iso_is_protected feat/thing && bad "feature branch treated as protected" \
                            || ok "feature branch is not protected"
iso_is_protected ""         && ok "detached HEAD counts as protected" \
                            || bad "detached HEAD not protected"

echo "iso_branch_from_plan"
check "known type"    "$(iso_branch_from_plan 2026-05-26-feat-health-check.md)" "feat/health-check"
check "refactor type" "$(iso_branch_from_plan 2026-08-21-refactor-iso-config.md)" "refactor/iso-config"
check "unknown type defaults to feat" \
  "$(iso_branch_from_plan 2026-05-26-make-it-faster.md)" "feat/make-it-faster"
check "path is stripped" \
  "$(iso_branch_from_plan docs/superpowers/plans/2026-01-01-fix-a.md)" "fix/a"
iso_branch_from_plan 2026-05-26-feat-.md >/dev/null 2>&1
check "empty slug rejected" "$?" "1"
iso_branch_from_plan no-date-prefix.md >/dev/null 2>&1
check "missing date prefix rejected" "$?" "1"

echo "iso_branch_from_subject"
check "type and scope" \
  "$(iso_branch_from_subject 'feat(auth): add token refresh')" "feat/auth-add-token-refresh"
check "no scope" \
  "$(iso_branch_from_subject 'fix: broken pipe')" "fix/broken-pipe"
check "breaking marker" \
  "$(iso_branch_from_subject 'feat(api)!: drop v1')" "feat/api-drop-v1"
check "non-conventional falls back to chore" \
  "$(iso_branch_from_subject 'random words here')" "chore/random-words-here"
check "empty subject yields nothing" "$(iso_branch_from_subject '')" ""
long=$(iso_branch_from_subject 'feat(scope): aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk')
[ ${#long} -le 53 ] && ok "long slug truncated" || bad "long slug not truncated (${#long})"
case "$long" in *-) bad "truncated mid-separator" ;; *) ok "truncation lands on a word boundary" ;; esac

echo "iso_branch_gate"
# A real repo: the gate asks git whether the candidate branch exists.
r=$(mktemp -d)
git init -q -b dev "$r"
git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
git -C "$r" commit -q --allow-empty -m init
git -C "$r" branch feat/wiki-ingest
cd "$r" || exit 1

act() { iso_branch_gate "$@" | sed -n 's/^action=//p'; }
brn() { iso_branch_gate "$@" | sed -n 's/^branch=//p'; }

check "row 1  action" "$(act feat/wiki-ingest feat/wiki-ingest '')" "stay"
check "row 1  branch" "$(brn feat/wiki-ingest feat/wiki-ingest '')" "feat/wiki-ingest"
check "row 2  action" "$(act feat/hotfix-typo feat/wiki-ingest '')" "stay"
check "row 2  branch" "$(brn feat/hotfix-typo feat/wiki-ingest '')" "feat/hotfix-typo"
check "row 3  action" "$(act dev feat/wiki-ingest feat/other)" "checkout"
check "row 3  branch" "$(brn dev feat/wiki-ingest feat/other)" "feat/wiki-ingest"
check "row 3b action" "$(act dev feat/absent feat/other)" "create"
check "row 3b branch" "$(brn dev feat/absent feat/other)" "feat/absent"
check "row 4  action" "$(act dev '' feat/brand-new)" "create"
check "row 4  branch" "$(brn dev '' feat/brand-new)" "feat/brand-new"
check "row 4b action" "$(act dev '' feat/wiki-ingest)" "checkout"
check "row 5  action" "$(act dev '' '')" "ask"
check "row 5  branch" "$(brn dev '' '')" ""
# The staleness this whole design exists to fix: a ticket still naming dev must
# never send anyone back to dev.
check "stale ticket ignored" "$(act dev dev feat/brand-new)" "create"
check "stale ticket target"  "$(brn dev dev feat/brand-new)" "feat/brand-new"
check "detached uses proposed" "$(act '' '' feat/brand-new)" "create"
check "gate prints two lines" "$(iso_branch_gate dev '' feat/x | wc -l | tr -d ' ')" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run it to confirm it fails**

Run: `bash skills/iso-config/scripts/lib/branch.test.sh`
Expected: `FATAL: sourcing did not define iso_branch_gate` — the library does not exist yet, so the `.` fails and the type check aborts.

- [x] **Step 3: Write the library**

Create `skills/iso-config/scripts/lib/branch.sh`:

```bash
#!/usr/bin/env bash
# Shared branch vocabulary for iso-* skills. Sourced, never executed.
#
# The only reader of branches.protected, and the only place a branch name is
# derived from a plan filename or a commit subject. Before this file, iso-write
# and iso-push each carried their own copy of both, under different names.
#
# Pure on purpose: git state and config in, a verdict out. It never calls the
# tracker. iso-issue-tracking sources iso-config, so a call back the other way
# would be a dependency cycle — callers resolve the ticket with whatever
# identifier they already hold and pass the answer in.

# Callers normally source config.sh first. Pull it in if not, so this file works
# standalone in a test without every caller growing a second source line.
type iso_config_get >/dev/null 2>&1 || {
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
}

KNOWN_TYPES='feat fix chore refactor docs test perf'

# A place work is promoted TO, never worked ON. An empty branch is a detached
# HEAD and counts: work must not live on a ref nothing will find again.
iso_is_protected() {
  local b
  [ -z "$1" ] && return 0
  for b in $(iso_config_get branches.protected); do
    [ "$b" = "$1" ] && return 0
  done
  return 1
}

# YYYY-MM-DD-<type>-<slug>.md -> <type>/<slug>. An unrecognised second token is
# part of the slug and the type defaults to feat.
iso_branch_from_plan() {
  local base rest type slug t
  base=${1##*/}; base=${base%.md}
  rest=${base#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}
  [ "$rest" = "$base" ] && return 1
  type=feat; slug="$rest"
  for t in $KNOWN_TYPES; do
    if [ "${rest%%-*}" = "$t" ]; then type="$t"; slug="${rest#*-}"; break; fi
  done
  [ -n "$slug" ] || return 1
  printf '%s/%s\n' "$type" "$slug"
}

# "feat(scope): message" -> feat/scope-message. Nothing on empty input.
iso_branch_from_subject() {
  local subject="${1:-}" type scope msg slug
  [ -n "$subject" ] || return 0

  type=$(printf '%s' "$subject" | sed -n 's/^\([a-z][a-z]*\)[(!:].*/\1/p')
  case "$type" in
    feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert) ;;
    # Not a conventional subject. chore is the honest answer: it is what the
    # version bump would treat it as anyway, so the branch name agrees with what
    # the release will do rather than guessing something prettier.
    *) type=chore ;;
  esac

  scope=$(printf '%s' "$subject" | sed -n 's/^[a-z][a-z]*(\([^)]*\)).*/\1/p')
  msg=$(printf '%s' "$subject" | sed 's/^[^:]*: *//')

  slug=$(printf '%s-%s' "$scope" "$msg" | tr '[:upper:]' '[:lower:]' \
         | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-*//; s/-*$//')

  # Cut at a word boundary, never mid-word: a branch ending in `destro` invites
  # someone to wonder whether it was truncated or misspelled.
  if [ ${#slug} -gt 48 ]; then
    slug=$(printf '%s' "$slug" | cut -c1-48 | sed 's/-[^-]*$//')
  fi
  [ -n "$slug" ] || slug=work

  printf '%s/%s\n' "$type" "$slug"
}

# Where should this work live? Prints a verdict; it never checks anything out
# and never asks a question, because a script cannot ask one. The calling
# SKILL.md renders the prompt for `ask`, and performs the checkout otherwise.
#
#   $1 current branch      ("" for detached HEAD)
#   $2 the ticket's branch ("" when there is no ticket, or none recorded)
#   $3 a proposed name     ("" when the caller had nothing to derive one from)
#
# Prints:
#   action=stay|checkout|create|ask
#   branch=<name>          (the current branch for stay, empty for ask)
iso_branch_gate() {
  local cur="$1" tb="${2:-}" proposed="${3:-}" candidate=""

  # Standing on a feature branch is a deliberate act. Where you are is where you
  # are working, even when the ticket still names somewhere else.
  iso_is_protected "$cur" || { printf 'action=stay\nbranch=%s\n' "$cur"; return 0; }

  # The ticket's own branch beats a freshly derived name: resuming beats cutting
  # a near-duplicate and splitting one ticket across two branches. A ticket still
  # naming a protected branch is exactly the staleness this design fixes, so it
  # is ignored rather than followed back onto dev.
  if [ -n "$tb" ] && [ "$tb" != "$cur" ] && ! iso_is_protected "$tb"; then
    candidate="$tb"
  else
    candidate="$proposed"
  fi

  [ -n "$candidate" ] || { printf 'action=ask\nbranch=\n'; return 0; }

  # An existing candidate is a resume, not a collision. This is what replaces
  # write.sh's refusal to run twice against the same plan.
  if git rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null 2>&1; then
    printf 'action=checkout\nbranch=%s\n' "$candidate"
  else
    printf 'action=create\nbranch=%s\n' "$candidate"
  fi
}
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-config/scripts/lib/branch.test.sh`
Expected: every line `ok`, final line `N passed, 0 failed`, exit 0.

- [x] **Step 5: Confirm nothing else broke**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: `0 failed`. `branch.sh` sources `config.sh` but does not modify it.

- [x] **Step 6: Document the policy**

In `skills/iso-config/SKILL.md`, add a `## Branch policy` section after the existing configuration reference. It must contain, in normal prose:

- The rule: **no `iso-*` skill reads `branches.protected` directly.** Source `branch.sh` through `iso_sibling` and call `iso_is_protected`.
- The four signatures from this task's **Interfaces** block, verbatim.
- The seven-row verdict table copied from the spec's "The seven cases".
- The reason the gate is pure: `iso-issue-tracking` sources `iso-config`, so the gate cannot call the tracker without creating a cycle. Callers resolve the ticket themselves and pass `<ticket-branch>` in.
- The rule that `action=ask` is the only case that prompts a human, and that the prompt is rendered by the calling `SKILL.md`, never by a script.

- [x] **Step 7: Update the architecture tree**

In `AGENTS.md`, under the `skills/` block, `iso-config/SKILL.md` currently has one line. Add a sibling line for the new library so the tree lists it:

```
  iso-config/SKILL.md              — the Iso config every iso-* skill reads
  iso-config/scripts/lib/branch.sh — shared branch vocabulary: protected test, name derivation, the gate
```

Remember `CLAUDE.md` is a symlink to `AGENTS.md` — edit `AGENTS.md` only.

- [x] **Step 8: Refresh the graph**

Run: `graphify update .`
Expected: `Code graph updated.`

---

### Task 2: The `rebranch` and `branch-of` verbs

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh` (two new dispatch arms)
- Modify: `skills/iso-issue-tracking/scripts/tracking.test.sh` (new `rebranch` block)
- Modify: `skills/iso-issue-tracking/SKILL.md` (document both verbs)

**Interfaces:**
- Consumes: nothing from Task 1. This task is independent and can run first or in parallel.
- Produces, for Tasks 3-5:
  - `tracking.sh rebranch <identifier> <new-branch>` — rewrites the ledger row's `.branch` and the ticket's `Branch` property. `<identifier>` is a plan path **or** the branch the work is moving off. Always exits 0.
  - `tracking.sh branch-of <identifier>` — prints the ledger row's branch, or nothing. Always exits 0.

- [x] **Step 1: Write the failing test**

Append to `skills/iso-issue-tracking/scripts/tracking.test.sh`, immediately before the final `printf`/summary lines. It reuses `$g` (the fixture repo), `$BIN7` (the `multica` stub), `$STUB_CALLS`, and `$STUB_DESC` already established earlier in the file:

```bash
echo "rebranch"
S9=$(mktemp -d)
P9=docs/superpowers/plans/2026-08-27-feat-rb.md
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" \
    open rb1 "t" --plan "$P9" --scope be </dev/null ) >/dev/null 2>&1
check "fixture ticket opened on the base branch" \
  "$(jq -r '.["FIRE-9"].branch' "$S9/tracked.json")" "main"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" \
    rebranch "$P9" feat/rb ) >/dev/null 2>&1
check "resolves by plan path" "$(jq -r '.["FIRE-9"].branch' "$S9/tracked.json")" "feat/rb"
grep -q -- 'issue property set FIRE-9 --name Branch --value feat/rb' "$STUB_CALLS" \
  && ok "board follows the ledger" || bad "Branch property not rewritten"
check "the plan key survives the move" "$(jq -r '.["FIRE-9"].plan' "$S9/tracked.json")" "$P9"
check "other row fields survive" "$(jq -r '.["FIRE-9"].opened_by' "$S9/tracked.json")" "iso"

# iso-push holds a branch and never a plan path, so the old branch must resolve.
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" \
    rebranch feat/rb feat/rb2 ) >/dev/null 2>&1
check "resolves by old branch name" "$(jq -r '.["FIRE-9"].branch' "$S9/tracked.json")" "feat/rb2"

# Re-running a skill must not be a state change.
( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" \
    rebranch feat/rb2 feat/rb2 ) >/dev/null 2>&1
check "idempotent" "$(jq -r '.["FIRE-9"].branch' "$S9/tracked.json")" "feat/rb2"

# A miss is normal: a repo with no ticket for this work still has to run.
: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" \
    rebranch nothing/here feat/x ) >/dev/null 2>&1
check "miss exits 0" "$?" "0"
grep -q 'property set' "$STUB_CALLS" && bad "wrote to the board on a miss" \
                                     || ok "miss writes nothing"
grep -q 'rebranch: no ticket' "$S9/log" && ok "miss is logged" || bad "miss not logged"

: > "$STUB_CALLS"
( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" \
    rebranch "$P9" ) >/dev/null 2>&1
check "missing new-branch argument exits 0" "$?" "0"
grep -q 'property set' "$STUB_CALLS" && bad "wrote with no new branch" \
                                     || ok "missing argument writes nothing"

echo "branch-of"
check "reads back by plan path" \
  "$( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" branch-of "$P9" )" "feat/rb2"
check "reads back by branch name" \
  "$( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" branch-of feat/rb2 )" "feat/rb2"
check "miss prints nothing" \
  "$( cd "$g" && MULTICA_STATE_DIR="$S9" PATH="$BIN7:$PATH" bash "$SH" branch-of nothing/here )" ""
rm -rf "$S9"
```

Note: the fixture repo `$g` is initialised on `main`, so the ticket opens with `branch=main`. If the surrounding file's fixture uses a different name, use that name in the first `check` instead.

- [x] **Step 2: Run it to confirm it fails**

Run: `bash skills/iso-issue-tracking/scripts/tracking.test.sh`
Expected: the `rebranch` block fails — `resolves by plan path` reports `want="feat/rb" got="main"`, because an unknown subcommand falls through the `case` and exits 0 without doing anything.

- [x] **Step 3: Add both dispatch arms**

In `skills/iso-issue-tracking/scripts/tracking.sh`, add these two arms to the `case "${1:-}"` block. Put them immediately after the `ticket-for-branch)` arm, so the three read/write branch verbs sit together:

```bash
  # The branch a ticket lives on changes after the ticket is opened: /iso-write
  # cuts one from the plan filename, /iso-push rescues commits off a protected
  # branch, /iso-commit gates before the commit lands. Both the ledger row and
  # the board have to follow, and the ledger is the one that bites — it is the
  # key ticket_for_branch resolves by, so a stale row makes the ticket
  # unfindable from the branch the work is actually on.
  # $2 identifies the ticket: a plan path, or the branch it is moving OFF.
  # Resolve BEFORE the ledger write; afterwards the old identifier matches
  # nothing and a second run would look like a miss.
  rebranch)
    state_dir
    ident="${2:-}"; newbr="${3:-}"
    [ -n "$ident" ] && [ -n "$newbr" ] \
      || { logf "rebranch needs <identifier> <new-branch>"; exit 0; }
    key=$(ticket_for_plan "$ident") \
      || { logf "rebranch: no ticket for $ident"; exit 0; }
    row=$(ledger_get "$key")
    ledger_put "$key" "$(printf '%s' "$row" | jq -c --arg b "$newbr" '.branch=$b' 2>/dev/null)"
    ensure_property Branch text \
      && { tk_issue_property "$key" Branch "$newbr" \
           || logf "rebranch: branch property set failed on $key"; }
    logf "rebranch $key -> $newbr (from $ident)"
    ;;

  # The read half. /iso-commit needs the ticket's branch to offer a resume and
  # holds no plan path, so it cannot reach the ledger any other way.
  branch-of)
    state_dir
    key=$(ticket_for_plan "${2:-}") || exit 0
    ledger_get "$key" | jq -r '.branch // empty' 2>/dev/null
    ;;
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-issue-tracking/scripts/tracking.test.sh`
Expected: `0 failed`. The count rises by roughly 14 from the current 155.

- [x] **Step 5: Verify the dispatch guard still passes**

Run: `bash scripts/dispatch-integrity.test.sh`
Expected: pass. This guard asserts every dispatched verb resolves to something defined; both new arms are inline, so it should be satisfied without edits. If it reports the new verbs, read its output and follow whatever convention it enforces.

- [x] **Step 6: Document both verbs**

In `skills/iso-issue-tracking/SKILL.md`, add a subsection covering:

- `rebranch <identifier> <new-branch>` — what it rewrites (ledger row and `Branch` property), that `<identifier>` accepts a plan path or the old branch name, that it is idempotent, that it exits 0 on a miss, and that it posts **no** ticket comment because a branch move is bookkeeping and a comment per move would bury the retro.
- `branch-of <identifier>` — prints the ledger row's branch or nothing.
- One sentence naming the caller of each: `iso-write` after it resolves a workspace, `iso-commit` after its gate lands, `iso-push` inside `rescue_to_branch`.

- [x] **Step 7: Refresh the graph**

Run: `graphify update .`

---

### Task 3: Wire `iso-write`

**Files:**
- Modify: `skills/iso-write/scripts/write.sh` (delete `is_base_branch` and `cmd_branch_for`'s body, rewrite the default arm of `cmd_resolve`, add two tracking helpers)
- Modify: `skills/iso-write/scripts/write.test.sh`
- Modify: `skills/iso-write/SKILL.md` (the new `resumed-branch` mode)

**Interfaces:**
- Consumes: `iso_is_protected`, `iso_branch_from_plan`, `iso_branch_gate` from Task 1; `tracking.sh rebranch` and `branch-of` from Task 2.
- Produces: `write.sh resolve` gains a fifth mode value, `resumed-branch`, printed as `mode=resumed-branch`. `SKILL.md` and any caller reading that line must accept it.

- [x] **Step 1: Write the failing test**

Append to `skills/iso-write/scripts/write.test.sh`, before its summary:

```bash
# write.sh now calls the real tracking.sh through iso_sibling. Isolate its state
# before the first resolve, or these fixtures write to the user's live ledger.
export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)

echo "resuming a plan's existing branch"
r=$(newrepo dev)
( cd "$r" && git branch feat/thing )
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md )
check "mode is resumed-branch" "$(printf '%s' "$out" | grep '^mode=')"   "mode=resumed-branch"
check "branch is the existing one" "$(printf '%s' "$out" | grep '^branch=')" "branch=feat/thing"
check "landed on it" "$( cd "$r" && git branch --show-current )" "feat/thing"

echo "resuming carries uncommitted work"
r=$(newrepo dev)
( cd "$r" && git branch feat/thing )
printf 'dirty\n' > "$r/file.txt"
( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md ) >/dev/null
check "work came along on resume" "$(cat "$r/file.txt")" "dirty"

echo "an existing branch is no longer an error"
r=$(newrepo dev)
( cd "$r" && git branch feat/thing )
( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md ) >/dev/null 2>&1
check "exits 0 where it used to die" "$?" "0"
```

Then find and **delete** the existing assertion that a pre-existing branch is fatal (it asserts a non-zero exit or matches the string `already exists`). That behaviour is intentionally replaced. Search for it with:

```bash
grep -n "already exists" skills/iso-write/scripts/write.test.sh
```

- [x] **Step 2: Run it to confirm it fails**

Run: `bash skills/iso-write/scripts/write.test.sh`
Expected: `mode is resumed-branch` reports `want="mode=resumed-branch" got=""`, because `cmd_resolve` currently calls `die` before printing anything.

- [x] **Step 3: Rewrite `write.sh`**

Three edits.

**3a.** After the existing `config.sh` source line near the top, add the branch library:

```bash
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"
```

**3b.** Delete `is_base_branch` entirely, and replace `cmd_branch_for`'s body with a delegation. Its `die` messages are preserved here, because the library returns a code rather than printing:

```bash
cmd_branch_for() {
  iso_branch_from_plan "$1" \
    || die "plan filename lacks a YYYY-MM-DD- prefix, or has an empty slug: $1"
}
```

**3c.** Replace the `"")` arm of `cmd_resolve`'s `case` with the gate. The other three arms (`--no-branch`, `--branch=`, `--worktree`) are unchanged: they are explicit instructions and deliberately bypass the gate.

```bash
    "")
      proposed=$(cmd_branch_for "$plan")
      # The ticket's branch, so a resume beats cutting a near-duplicate. Empty
      # when there is no tracker, no ticket, or nothing recorded — all normal.
      tb=$(track_branch "$plan")
      gate=$(iso_branch_gate "$current" "$tb" "$proposed")
      action=$(printf '%s' "$gate" | sed -n 's/^action=//p')
      branch=$(printf '%s' "$gate" | sed -n 's/^branch=//p')
      case "$action" in
        stay)
          # A branch with no commits isolates nothing: same worktree, same index.
          # Cutting another one buys the bookkeeping and none of the separation.
          branch="$current"; mode=current-branch ;;
        checkout)
          label=$(stash_carry "$branch") || true
          git checkout -q "$branch"
          stash_pop "${label:-}"
          mode=resumed-branch ;;
        create)
          label=$(stash_carry "$branch") || true
          git checkout -q -b "$branch"
          stash_pop "${label:-}"
          mode=fresh-branch ;;
        *)
          # `ask` is unreachable here: cmd_branch_for always yields a name or dies.
          die "cannot decide a branch for $plan" ;;
      esac ;;
```

Add `proposed tb gate action` to that function's `local` declaration line.

**3d.** Add the two tracking helpers beside the existing `cmd_track`, and call the write half at the end of `cmd_resolve`, just before its `printf`:

```bash
# The ticket's branch, or nothing. Tracking must never fail a write run.
track_branch() {
  local s
  s=$(iso_sibling iso-issue-tracking scripts/tracking.sh 2>/dev/null) || return 0
  [ -x "$s" ] && git rev-parse --show-toplevel >/dev/null 2>&1 \
    && "$s" branch-of "$1" 2>/dev/null
  return 0
}

# Point the ticket at the branch this run actually landed on. Called in every
# mode, including current-branch: that is the case where the ticket is most
# likely already wrong, because the user moved themselves.
track_rebranch() {
  local s
  s=$(iso_sibling iso-issue-tracking scripts/tracking.sh 2>/dev/null) || return 0
  [ -x "$s" ] && git rev-parse --show-toplevel >/dev/null 2>&1 \
    && "$s" rebranch "$1" "$2" >/dev/null
  return 0
}
```

The call site:

```bash
  track_rebranch "$plan" "$branch"
  printf 'mode=%s\nbranch=%s\n' "$mode" "$branch"
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-write/scripts/write.test.sh`
Expected: `0 failed`, including every pre-existing assertion about `fresh-branch`, `--no-branch`, `--branch=`, and stash carrying.

- [x] **Step 5: Update the skill's documented contract**

In `skills/iso-write/SKILL.md`:

- Add `resumed-branch` to wherever the `mode=` values are listed, described as: the plan's branch already existed and was checked out rather than refused, so re-running `/iso-write` on the same plan resumes it.
- Remove any sentence saying an existing branch is an error or instructing the user to delete it, rename the plan, or pass `--branch=`.
- Note that the ticket's branch is updated on every run.

- [x] **Step 6: Refresh the graph**

Run: `graphify update .`

---

### Task 4: Wire `iso-push`

**Files:**
- Modify: `skills/iso-push/scripts/push.sh` (delete `is_protected`, thin `branch_name_from`, rebind inside `rescue_to_branch`)
- Modify: `skills/iso-push/scripts/push.test.sh`

**Interfaces:**
- Consumes: `iso_is_protected`, `iso_branch_from_subject` from Task 1; `tracking.sh rebranch` from Task 2.
- Produces: nothing new. `rescue_to_branch`'s printed output and exit behaviour are unchanged.

- [x] **Step 1: Write the failing test**

Append to `skills/iso-push/scripts/push.test.sh`, before its summary. Follow the file's existing fixture idiom — if it already has a helper that builds a repo with an `origin`, use that instead of the inline setup here:

```bash
echo "rescue rebinds the ticket"
r=$(mktemp -d); o=$(mktemp -d)
git init -q --bare "$o"
git init -q -b dev "$r"
git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
git -C "$r" remote add origin "$o"
git -C "$r" commit -q --allow-empty -m "init"
git -C "$r" push -q origin dev
git -C "$r" commit -q --allow-empty -m "feat(auth): add token refresh"

# Record what rescue asks the tracker to do, without a real tracker.
export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)
BINR=$(mktemp -d)
cat > "$BINR/tracking.sh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$TRACK_CALLS"
STUB
chmod +x "$BINR/tracking.sh"
export TRACK_CALLS="$r/track-calls"; : > "$TRACK_CALLS"

new=$( cd "$r" && ISO_TRACKING_SH="$BINR/tracking.sh" bash "$SH" rescue dev 2>/dev/null )
check "named from the commit subject" "$new" "feat/auth-add-token-refresh"
check "landed on it" "$(git -C "$r" branch --show-current)" "feat/auth-add-token-refresh"
grep -q 'rebranch dev feat/auth-add-token-refresh' "$TRACK_CALLS" \
  && ok "ticket rebound off dev" || bad "rescue did not rebind the ticket"
```

If `push.sh` exposes no `rescue` subcommand, add one that is a thin dispatch to `rescue_to_branch` — the function is currently only reachable from inside a larger flow, and a test needs a seam. Add the arm alongside the others in `push.sh`'s `case`:

```bash
  rescue) shift; rescue_to_branch "$@" ;;
```

- [x] **Step 2: Run it to confirm it fails**

Run: `bash skills/iso-push/scripts/push.test.sh`
Expected: `rescue did not rebind the ticket` — `rescue_to_branch` performs the checkout and returns without telling anyone.

- [x] **Step 3: Edit `push.sh`**

**3a.** After the existing `config.sh` source, add:

```bash
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"
```

**3b.** Delete the local `is_protected` function (lines 34-38) and its `PROTECTED=$(iso_config_get branches.protected)` assignment. Replace every call to `is_protected` with `iso_is_protected` — there are calls at roughly lines 477 and in `cmd_preflight`. Find them all:

```bash
grep -n "is_protected" skills/iso-push/scripts/push.sh
```

**3c.** Reduce `branch_name_from` to the git-log read, which is the only push-specific half:

```bash
# The last non-merge commit above origin/<base>, named as a branch.
branch_name_from() {   # <base> -> <type>/<slug>
  local subject
  subject=$(git log --format=%s --no-merges "origin/$1..HEAD" 2>/dev/null | tail -1)
  [ -n "$subject" ] || return 1
  iso_branch_from_subject "$subject"
}
```

**3d.** Add a tracking helper beside `ticket_key`, honouring an override so the test can substitute a stub:

```bash
# Point the ticket at the branch the work was just moved to. Never fatal.
track_rebranch() {
  local s
  s="${ISO_TRACKING_SH:-$(iso_sibling iso-issue-tracking scripts/tracking.sh 2>/dev/null)}" || return 0
  [ -x "$s" ] && "$s" rebranch "$1" "$2" >/dev/null 2>&1
  return 0
}
```

**3e.** In `rescue_to_branch`, add the call after the checkout and before the `printf`. The ledger still names the protected branch at this point, which is exactly the identifier that resolves the ticket:

```bash
  git checkout "$new" >&2
  track_rebranch "$prot" "$new"
  printf '%s\n' "$new"
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-push/scripts/push.test.sh`
Expected: `0 failed`, with every pre-existing assertion still green — especially the ones covering cascade refusal and PR reuse.

- [x] **Step 5: Confirm the PR link path**

Read `body_with_ticket` and `cmd_pr` and confirm no change is needed: `ticket_key` calls `ticket-for-branch`, which now resolves because the ledger is correct. There is nothing to edit here — this step is a read, and it exists so the implementer does not "fix" a function that was never broken.

- [x] **Step 6: Refresh the graph**

Run: `graphify update .`

---

### Task 5: Wire `iso-commit`

**Files:**
- Modify: `skills/iso-commit/scripts/commit.sh` (two new subcommands)
- Modify: `skills/iso-commit/scripts/commit.test.sh`
- Modify: `skills/iso-commit/SKILL.md` (the new step order)

**Interfaces:**
- Consumes: `iso_branch_gate`, `iso_branch_from_subject` from Task 1; `tracking.sh branch-of` and `rebranch` from Task 2.
- Produces:
  - `commit.sh gate <subject>` — prints the two gate lines.
  - `commit.sh land <action> <branch>` — performs the checkout or creation, rebinds the ticket, prints the branch it ended on.

- [x] **Step 1: Write the failing test**

Append to `skills/iso-commit/scripts/commit.test.sh`, before its summary. Reuse the file's existing repo fixture helper if it has one:

```bash
echo "branch gate"
r=$(mktemp -d)
git init -q -b dev "$r"
git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
git -C "$r" commit -q --allow-empty -m init
export ISO_GLOBAL_CONFIG=/nonexistent

export ISO_TRACKER_STATE_DIR; ISO_TRACKER_STATE_DIR=$(mktemp -d)

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
export TRACK_CALLS="$r/track-calls"; : > "$TRACK_CALLS"

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
```

- [x] **Step 2: Run it to confirm it fails**

Run: `bash skills/iso-commit/scripts/commit.test.sh`
Expected: `on dev, a subject yields a create` reports `want="create" got=""`. `commit.sh` has no `gate` subcommand, so its `case` falls through to `die` with the usage line.

- [x] **Step 3: Edit `commit.sh`**

`commit.sh` currently sources nothing. Add the two library sources after the `die` definition, near the top:

```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/branch.sh)"
```

Then add the two subcommands and the tracking helper:

```bash
# ------------------------------------------------------------------- tracking
# Never fatal: a repo with no tracker still has to be able to commit.
track_call() {   # <verb> <args...> -> prints the verb's stdout, or nothing
  local s
  s="${ISO_TRACKING_SH:-$(iso_sibling iso-issue-tracking scripts/tracking.sh 2>/dev/null)}" || return 0
  [ -x "$s" ] && "$s" "$@" 2>/dev/null
  return 0
}

# ----------------------------------------------------------------------- gate
# Where should this commit land? Prints the verdict; SKILL.md renders the
# prompt, because a script cannot ask a question.
cmd_gate() {
  local subject="${1:-}" cur tb proposed=""
  cur=$(git symbolic-ref --short HEAD 2>/dev/null) || cur=""
  tb=$(track_call branch-of "$cur")
  [ -n "$subject" ] && proposed=$(iso_branch_from_subject "$subject")
  iso_branch_gate "$cur" "$tb" "$proposed"
}

# ----------------------------------------------------------------------- land
# Carry out the gate's verdict, then point the ticket at where we ended up.
# The index survives both checkout forms, so the commit that follows still has
# its staged work; git refuses the checkout outright if it cannot carry it, and
# that refusal is the right answer.
cmd_land() {
  local action="${1:?usage: commit.sh land <action> <branch>}"
  local target="${2:?usage: commit.sh land <action> <branch>}"
  local cur
  cur=$(git symbolic-ref --short HEAD 2>/dev/null) || cur=""
  case "$action" in
    stay)     ;;
    checkout) git checkout -q "$target" ;;
    create)   git checkout -q -b "$target" ;;
    *) die "unknown gate action: $action" ;;
  esac
  [ "$cur" = "$target" ] || track_call rebranch "$cur" "$target" >/dev/null
  printf '%s\n' "$target"
}
```

Add both to the dispatch `case`:

```bash
  gate)       shift; cmd_gate "$@" ;;
  land)       shift; cmd_land "$@" ;;
```

and extend the usage line in the `*)` arm to name them.

- [x] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-commit/scripts/commit.test.sh`
Expected: `0 failed`, with the pre-existing preflight, candidates, guard, and stage assertions all still green.

- [x] **Step 5: Rewrite the documented flow**

In `skills/iso-commit/SKILL.md`, the `## Flow` list becomes six steps. Steps 1-4 keep their current wording; 5 is new and 6 is the old 5:

```
1. Preflight — commit.sh preflight [--staged].
2. Read the change — git diff HEAD, git log --oneline -10.
3. Stage — commit.sh stage [--staged]. Credential guard runs first.
4. Write the message to a temp file, following the format below.
5. Branch gate — commit.sh gate "<subject>", then commit.sh land <action> <branch>.
6. Commit — commit.sh commit <msgfile>.
```

Document step 5 in prose:

- Why it sits after the message and not in preflight: the gate names a branch from the subject, and the subject does not exist until step 4.
- The four verdicts and what to do with each. `stay`: call `land stay <branch>` and continue. `create` / `checkout`: show the user the branch name and land it. `ask`: the gate found nothing to derive a name from — ask the user for one, then call `land create <their-name>`.
- That `ask` is the only case that stops for a human.
- That the ticket's `Branch` follows automatically, so no one should write it by hand.

- [x] **Step 6: Full sweep**

Run every suite the change touches:

```bash
bash skills/iso-config/scripts/lib/config.test.sh
bash skills/iso-config/scripts/lib/branch.test.sh
bash skills/iso-issue-tracking/scripts/tracking.test.sh
bash skills/iso-issue-tracking/scripts/adapters/contract.test.sh
bash skills/iso-write/scripts/write.test.sh
bash skills/iso-push/scripts/push.test.sh
bash skills/iso-commit/scripts/commit.test.sh
bash scripts/dispatch-integrity.test.sh
node --test scripts/*.test.js
```

Expected: every suite reports `0 failed`.

- [x] **Step 7: Refresh the graph**

Run: `graphify update .`

- [x] **Step 8: Stop**

Leave the tree uncommitted. Report which suites ran and their counts. The user reviews the diff and runs `/iso-commit` themselves.

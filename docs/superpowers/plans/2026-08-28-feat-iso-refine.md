# iso-refine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `iso-review` with `iso-refine` — three headless phases that improve and then check a branch's changes, unattended, leaving everything readable as `git diff`.

**Architecture:** One dispatching shell script per skill, as everywhere else in this repo. `refine.sh` dispatches `preflight`, `scope`, `run` onto `cmd_*` functions; phase execution shells out to `claude -p` once per phase. Git is the state machine: the index holds the pre-run snapshot, so a phase revert is `git checkout -- .` and the whole output is `git diff`.

**Tech Stack:** bash 3.2 (macOS — no associative arrays, no `${var^^}`, no `readarray`), `jq`, `git`, `claude` CLI, `timeout` (coreutils; `gtimeout` on macOS via brew).

**Spec:** `docs/superpowers/specs/2026-08-28-iso-refine-design.md`

## Global Constraints

- **Never commit.** No task ends in a commit. The standing repo rule is that `/iso-commit` is the only thing that commits, and only when the user asks. Leave every task's work uncommitted.
- **bash 3.2.** macOS ships 3.2. No `declare -A`, no `${x^^}`, no `readarray`, no `&>>`.
- **`set -euo pipefail`** in every executable script; `set -uo pipefail` in test files so a failed assertion does not abort the run.
- **Tests are ad hoc.** `bash <path>/*.test.sh`. Each test file defines its own `ok`/`bad`/`check`; no framework, no fixtures directory.
- **`iso_sibling`, never `$HOME`.** Cross-skill paths resolve through `iso-config/scripts/lib/sibling.sh`. An absolute `~/.claude/skills/...` path is correct under exactly one of the four install topologies.
- **Every dispatched verb** must resolve to a defined `cmd_*` and be named in a `die "usage: ..."` string — `scripts/dispatch-integrity.test.sh` asserts both.
- **No AI attribution** anywhere: not in code comments, not in docs.

---

## File Structure

```
skills/iso-config/scripts/lib/config.sh          MODIFY  test.command default + overlay key
skills/iso-config/scripts/lib/config.test.sh     MODIFY  3 assertions
skills/iso-issue-tracking/scripts/tracking.sh    MODIFY  comment verb
skills/iso-issue-tracking/scripts/tracking.test.sh MODIFY 4 assertions
skills/iso-refine/SKILL.md                       CREATE  the skill
skills/iso-refine/scripts/refine.sh              CREATE  dispatcher + preflight + scope + run
skills/iso-refine/scripts/lib/phase.sh           CREATE  one phase: invoke, gate, revert, snapshot
skills/iso-refine/scripts/lib/phase.test.sh      CREATE
skills/iso-refine/scripts/refine.test.sh         CREATE
skills/iso-review/                               DELETE
skills/iso-todo/                                 DELETE
AGENTS.md, README.md, CONTEXT.md                 MODIFY  references
skills/iso-plan/SKILL.md                         MODIFY  iso-todo references
skills/iso-issue-tracking/SKILL.md               MODIFY  iso-todo references
docs/adr/0004-iso-config-two-scope-overlay.md    MODIFY  iso-todo mention
```

Split rationale: `phase.sh` is the only part that spends tokens, so it is the only part that needs stubbing in tests. Keeping it out of `refine.sh` means `preflight` and `scope` are assertable with no seam at all.

---

### Task 1: `iso-config` learns `test.command`

**Files:**
- Modify: `skills/iso-config/scripts/lib/config.sh`
- Test: `skills/iso-config/scripts/lib/config.test.sh`

**Interfaces:**
- Produces: `iso_config_get test.command` returns the configured command or empty string. Empty means no phase gate. Consumed by Task 6.

- [ ] **Step 1: Write the failing assertions**

Append to `config.test.sh`, before the final tally:

```bash
echo "test command"
check "no test command by default" "$(iso_config_get test.command)" ""
r=$(mktemp -d); mkdir -p "$r/docs/iso"
printf '%s\n' '{"test":{"command":"bash run-tests.sh"}}' > "$r/docs/iso/config.json"
check "overlay sets the test command" \
  "$( cd "$r" && iso_config_get test.command )" "bash run-tests.sh"
printf '%s\n' '{"test":{"cmd":"nope"}}' > "$r/docs/iso/config.json"
( cd "$r" && iso_config_validate_overlay docs/iso/config.json ) >/dev/null 2>&1
check "a misspelled test key is still rejected" "$?" "1"
rm -rf "$r"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: FAIL on "overlay sets the test command" — the overlay validator rejects `test.command` as unknown, so `iso_config` returns nothing.

- [ ] **Step 3: Add the default**

In `iso_defaults()`, after the `"paths"` block:

```json
  "test": {
    "command": null
  },
```

Null, not a string: there is no command that is right for every repo, and a guessed default would make the gate silently test the wrong thing.

- [ ] **Step 4: Allow it in the overlay**

In `ISO_OVERLAY_KEYS`, append to the last line:

```bash
paths.plans paths.specs paths.artifacts test.command'
```

It belongs in the overlay by the same rule the comment above the list states: the test command is a property of one repository, not of a person or a machine.

- [ ] **Step 5: Run the suite**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: 30 passed, 0 failed.

- [ ] **Step 6: Set it for this repo**

Create or extend `docs/iso/config.json`:

```json
{
  "test": {
    "command": "node --test scripts/*.test.js && for t in skills/*/scripts/*.test.sh skills/*/scripts/lib/*.test.sh skills/*/scripts/adapters/*.test.sh scripts/*.test.sh; do bash \"$t\" || exit 1; done"
  }
}
```

Verify: `bash -c \"$(cd . && ./skills/iso-config/scripts/config.sh get test.command)\"` runs the suite and exits 0.

---

### Task 2: `tracking.sh` learns `comment`

**Files:**
- Modify: `skills/iso-issue-tracking/scripts/tracking.sh`
- Test: `skills/iso-issue-tracking/scripts/tracking.test.sh`

**Interfaces:**
- Produces: `tracking.sh comment <KEY>` reads a body from stdin, redacts it, posts it. Always exits 0. Consumed by Task 8 through `iso_track`.

- [ ] **Step 1: Write the failing assertions**

Add a section to `tracking.test.sh`, modelled on the existing `retro` block which already stubs the CLI:

```bash
echo "comment"
SC=$(mktemp -d); STUB_CALLS="$SC/calls"
MB=$(mktemp -d)
cat > "$MB/multica" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$STUB_CALLS"
cat > "$STUB_CALLS.body"
STUB
chmod +x "$MB/multica"
S7=$(mktemp -d)
printf 'summary line\ntoken mul_abcdefghijklmnop1234\n' \
  | ( MULTICA_STATE_DIR="$S7" STUB_CALLS="$STUB_CALLS" PATH="$MB:/usr/bin:/bin" \
      bash "$SH" comment FIRE-1 ) >/dev/null 2>&1
check "comment exits 0" "$?" "0"
grep -q 'issue comment add FIRE-1' "$STUB_CALLS" \
  && ok "comment reached the board" || bad "comment never reached the board"
grep -q 'summary line' "$STUB_CALLS.body" \
  && ok "the body arrived" || bad "the body did not arrive"
grep -q 'mul_abcdefghijklmnop1234' "$STUB_CALLS.body" \
  && bad "a token reached the board unredacted" || ok "the body was redacted"
: > "$STUB_CALLS"
printf 'x\n' | ( MULTICA_STATE_DIR="$S7" PATH="$MB:/usr/bin:/bin" bash "$SH" comment ) >/dev/null 2>&1
check "a missing key exits 0" "$?" "0"
[ -s "$STUB_CALLS" ] && bad "a missing key still called the board" \
  || ok "a missing key writes nothing"
rm -rf "$SC" "$MB" "$S7"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-issue-tracking/scripts/tracking.test.sh`
Expected: FAIL on "comment reached the board" — `comment` hits the `*)` arm and only logs "unknown subcommand".

- [ ] **Step 3: Add the verb**

Insert a new arm before the `*)` arm, next to `retro` which does the same thing for a different reason:

```bash
  # A skill reporting to a human wants that report on the ticket too, so it
  # survives the terminal. Body on stdin rather than in argv: a summary is
  # multi-line and argv is the one place a newline gets mangled.
  #
  # Through redact for the same reason retro is: this crosses from the machine
  # to a board other people read, and a phase transcript can quote anything the
  # working tree contains.
  comment)
    state_dir
    key="${2:-}"
    [ -n "$key" ] || { logf "comment needs <key>"; exit 0; }
    redact | tk_issue_comment "$key" || logf "comment failed on $key"
    ;;
```

- [ ] **Step 4: Run the suite**

Run: `bash skills/iso-issue-tracking/scripts/tracking.test.sh`
Expected: 180 passed, 0 failed.

- [ ] **Step 5: Confirm the contract test still passes**

Run: `bash skills/iso-issue-tracking/scripts/adapters/contract.test.sh`
Expected: 35 passed, 0 failed. `tk_issue_comment` already exists in both adapters, so no adapter change is needed — this step is confirming that, not changing it.

---

### Task 3: `refine.sh` dispatcher and `preflight`

**Files:**
- Create: `skills/iso-refine/scripts/refine.sh`
- Test: `skills/iso-refine/scripts/refine.test.sh`

**Interfaces:**
- Produces: `refine.sh preflight` prints `index=<sha>` and `base=<sha>` on success. Consumed by Tasks 4, 5, 7.

- [ ] **Step 1: Write the failing test**

Create `refine.test.sh`:

```bash
#!/usr/bin/env bash
# Self-check for refine.sh. Run: bash refine.test.sh
# ponytail: asserts the git manipulation only — no phase ever runs here, so the
# whole file costs nothing to run and can be run on every edit.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/refine.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
export ISO_GLOBAL_CONFIG=/nonexistent

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
out=$( cd "$r" && bash "$SH" preflight )
check "prints an index sha" "$(printf '%s' "$out" | grep -c '^index=[0-9a-f]\{40\}$')" "1"
check "prints a base sha"  "$(printf '%s' "$out" | grep -c '^base=[0-9a-f]\{40\}$')"  "1"

r=$(newrepo); ( cd "$r" && git checkout -q -b feat/y )
( cd "$r" && bash "$SH" preflight ) >/dev/null 2>&1
check "a branch with nothing on it is refused" "$?" "1"

echo "staging"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/z )
printf 'new\n' > "$r/added.txt"; printf 'mod\n' > "$r/tracked.txt"
( cd "$r" && git add tracked.txt && git commit -q -m t && printf 'changed\n' > tracked.txt )
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: every assertion fails — `refine.sh` does not exist.

- [ ] **Step 3: Write the dispatcher and preflight**

Create `refine.sh`:

```bash
#!/usr/bin/env bash
# iso-refine mechanics: preflight, scope, and the three-phase run.
# Phase behaviour lives in lib/phase.sh — this file never talks to an agent.
set -euo pipefail

die() { printf 'iso-refine: %s\n' "$1" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

# --------------------------------------------------------------- preflight
# The index becomes the "before" snapshot for the whole run, so everything the
# phases write shows up as `git diff` and nothing else does.
#
# The write-tree comes FIRST and is printed, because `git add -A` overwrites a
# deliberate partial stage and nothing afterwards can tell "was staged" from
# "just got staged". The tree object survives in .git/objects either way, but
# only the sha makes it findable without `git fsck`.
cmd_preflight() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
  local index base ib
  index=$(git write-tree) || die "could not snapshot the index"
  git add -A
  ib=$(iso_config_get branches.development)
  [ -n "$ib" ] || ib=dev
  base=$(git merge-base "$ib" HEAD 2>/dev/null) \
    || die "no merge-base with $ib — is this branch related to it?"
  # An empty diff is not a failure to report on, it is nothing to run three
  # agents against. Measured from the base, not from the index: after `add -A`
  # the tree is clean by construction, so a dirty-tree check would always pass.
  git diff --cached --quiet "$base" \
    && die "nothing on this branch to refine (base $ib)"
  printf 'index=%s\nbase=%s\n' "$index" "$base"
}

case "${1:-}" in
  preflight) shift; cmd_preflight "$@" ;;
  *) die "usage: refine.sh {preflight} [args]" ;;
esac
```

- [ ] **Step 4: Run the tests**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: 8 passed, 0 failed.

- [ ] **Step 5: Run the dispatch sweep**

Run: `bash scripts/dispatch-integrity.test.sh`
Expected: 8 passed, 0 failed — `refine.sh` joins the sweep, its one verb resolves, and `preflight` appears in the usage string.

---

### Task 4: staleness and the rebase seam

**Files:**
- Modify: `skills/iso-refine/scripts/refine.sh`
- Test: `skills/iso-refine/scripts/refine.test.sh`

**Interfaces:**
- Consumes: `cmd_preflight` from Task 3.
- Produces: preflight rebases or refuses before printing. Exit 2 on a conflict.

- [ ] **Step 1: Write the failing assertions**

Append to `refine.test.sh`:

```bash
echo "staleness"
# The seam, stubbed: a real rebase needs a real remote, and what is being
# asserted is the POLICY around the seam, not git's rebase.
RB=$(mktemp -d)
printf '#!/usr/bin/env bash\necho "rebase $*" >> "$RB/calls"\n' > "$RB/rebase"
chmod +x "$RB/rebase"

r=$(newrepo); ( cd "$r" && git checkout -q -b feat/behind && git commit -q --allow-empty -m mine )
( cd "$r" && git checkout -q dev && git commit -q --allow-empty -m theirs && git checkout -q feat/behind )
: > "$RB/calls"
( cd "$r" && ISO_REFINE_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "a behind local branch is rebased" "$(grep -c '^rebase ' "$RB/calls")" "1"

( cd "$r" && git remote add origin . && git update-ref refs/remotes/origin/feat/behind HEAD )
: > "$RB/calls"
( cd "$r" && ISO_REFINE_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
rc=$?
check "a published behind branch is refused" "$rc" "1"
check "and is never rebased" "$(grep -c '^rebase ' "$RB/calls")" "0"

r=$(newrepo); ( cd "$r" && git checkout -q -b feat/current && git commit -q --allow-empty -m mine )
: > "$RB/calls"
( cd "$r" && ISO_REFINE_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "an up-to-date branch is not rebased" "$(grep -c '^rebase ' "$RB/calls")" "0"

printf '#!/usr/bin/env bash\nexit 1\n' > "$RB/rebase"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/conflict && git commit -q --allow-empty -m mine )
( cd "$r" && git checkout -q dev && git commit -q --allow-empty -m theirs && git checkout -q feat/conflict )
( cd "$r" && ISO_REFINE_REBASE="$RB/rebase" bash "$SH" preflight ) >/dev/null 2>&1
check "a rebase conflict exits 2" "$?" "2"
rm -rf "$RB"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: FAIL on "a behind local branch is rebased" — nothing calls the seam yet.

- [ ] **Step 3: Add the seam and the policy**

Insert into `refine.sh` above `cmd_preflight`:

```bash
# The rebase seam. Today it is iso-push's, which already runs unattended and
# leaves a conflict in progress rather than aborting; when iso-rebase exists,
# this points at it and nothing else here changes.
iso_refine_rebase() {
  local base="$1" sh
  sh="${ISO_REFINE_REBASE:-$(iso_sibling iso-push scripts/push.sh 2>/dev/null)}" || true
  [ -x "$sh" ] || die "no rebase available — install iso-push or set ISO_REFINE_REBASE"
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
```

Then inside `cmd_preflight`, after `base` is resolved and before the empty check:

```bash
  # Behind means the base is stale, and every phase after this would measure
  # its diff against the wrong thing.
  if [ "$(git rev-list --count "HEAD..$ib")" -gt 0 ]; then
    if branch_is_local; then
      iso_refine_rebase "$ib" || exit 2
      base=$(git merge-base "$ib" HEAD)
    else
      die "branch is $(git rev-list --count "HEAD..$ib") behind $ib and is published — rebase it yourself, then re-run"
    fi
  fi
```

- [ ] **Step 4: Run the tests**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: 13 passed, 0 failed.

---

### Task 5: `scope`

**Files:**
- Modify: `skills/iso-refine/scripts/refine.sh`
- Test: `skills/iso-refine/scripts/refine.test.sh`

**Interfaces:**
- Produces: `refine.sh scope` prints `base=<sha>` then one path per line. Consumed by Task 8's summary and by the human.

- [ ] **Step 1: Write the failing assertions**

```bash
echo "scope"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/s )
printf 'a\n' > "$r/a.txt"; printf 'b\n' > "$r/b.txt"
( cd "$r" && git add -A && git commit -q -m two )
printf 'c\n' > "$r/c.txt"
out=$( cd "$r" && bash "$SH" scope )
check "names the base"        "$(printf '%s' "$out" | grep -c '^base=')" "1"
check "lists committed work"  "$(printf '%s' "$out" | grep -c '^a\.txt$')" "1"
check "lists uncommitted work" "$(printf '%s' "$out" | grep -c '^c\.txt$')" "1"
check "spends no tokens" "$( cd "$r" && PATH=/usr/bin:/bin bash "$SH" scope >/dev/null 2>&1; echo $? )" "0"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: FAIL — `scope` hits the usage arm and dies.

- [ ] **Step 3: Add the verb**

```bash
# ----------------------------------------------------------------- scope
# What a run would act on, without acting. Exists so the diff-range decision is
# assertable without spending a token — the rest of the skill cannot be.
cmd_scope() {
  local out base
  out=$(cmd_preflight)
  base=$(printf '%s' "$out" | sed -n 's/^base=//p')
  printf 'base=%s\n' "$base"
  git diff --cached --name-only "$base"
}
```

And in the dispatch:

```bash
  scope)     shift; cmd_scope "$@" ;;
```

Update the usage string to `{preflight|scope}`.

- [ ] **Step 4: Run the tests**

Run: `bash skills/iso-refine/scripts/refine.test.sh` then `bash scripts/dispatch-integrity.test.sh`
Expected: 17 passed / 0, and the sweep still green with `scope` named in the usage string.

---

### Task 6: one phase

**Files:**
- Create: `skills/iso-refine/scripts/lib/phase.sh`
- Test: `skills/iso-refine/scripts/lib/phase.test.sh`

**Interfaces:**
- Consumes: `iso_config_get test.command` from Task 1.
- Produces: `phase_run <name> <prompt> <timeout>` — invokes the agent, marks new files intent-to-add, runs the gate, reverts on red. Prints `phase=<name> result=<pass|revert|error> files=<n>` then the agent's prose. Consumed by Task 7.

- [ ] **Step 1: Write the failing test**

Create `phase.test.sh`:

```bash
#!/usr/bin/env bash
# Self-check for phase.sh. Run: bash phase.test.sh
# ponytail: the agent is stubbed throughout. What is asserted is the git and
# gate policy around it — the only part that can be silently wrong.
set -uo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)/phase.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
export ISO_GLOBAL_CONFIG=/nonexistent

newrepo() {
  local d; d=$(mktemp -d)
  git init -q -b dev "$d"; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  printf '%s' "$d"
}

BIN=$(mktemp -d)
# The agent stub writes what its prompt tells it to, so one stub covers the
# edits-a-file, creates-a-file and does-nothing cases.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  edit)   printf 'edited\n' > touched.txt ;;
  create) printf 'new\n'    > created.txt ;;
  break)  printf 'broken\n' > touched.txt ;;
esac; done
printf 'did the thing\n'
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

echo "a passing phase"
r=$(newrepo); cd "$r" || exit 1
printf 'orig\n' > touched.txt; git add -A; git commit -q -m base
printf 'orig\n' > touched.txt; git add -A
. "$LIB"
out=$(phase_run simplify edit 30)
check "reports pass"        "$(printf '%s' "$out" | sed -n 's/.*result=\([a-z]*\).*/\1/p' | head -1)" "pass"
check "the edit survives"   "$(cat touched.txt)" "edited"
check "the edit is unstaged" "$(git diff --name-only | grep -c touched.txt)" "1"
check "the prose comes back" "$(printf '%s' "$out" | grep -c 'did the thing')" "1"

echo "a new file is visible in the diff"
r=$(newrepo); cd "$r" || exit 1
git commit -q --allow-empty -m base
phase_run architecture create 30 >/dev/null
check "the new file is intent-to-add" "$(git diff --name-only | grep -c created.txt)" "1"
check "and its content is not staged" "$(git diff --cached --name-only | grep -c created.txt)" "0"

echo "the phase gate"
r=$(newrepo); cd "$r" || exit 1
printf 'orig\n' > touched.txt; git add -A; git commit -q -m base
printf 'orig\n' > touched.txt; git add -A
mkdir -p docs/iso
printf '%s\n' '{"test":{"command":"grep -q orig touched.txt"}}' > docs/iso/config.json
out=$(phase_run simplify break 30)
check "a red gate reports revert" "$(printf '%s' "$out" | sed -n 's/.*result=\([a-z]*\).*/\1/p' | head -1)" "revert"
check "and the edit is undone"    "$(cat touched.txt)" "orig"

echo "no gate configured"
r=$(newrepo); cd "$r" || exit 1
printf 'orig\n' > touched.txt; git add -A; git commit -q -m base
printf 'orig\n' > touched.txt; git add -A
out=$(phase_run simplify break 30)
check "an ungated phase passes"  "$(printf '%s' "$out" | sed -n 's/.*result=\([a-z]*\).*/\1/p' | head -1)" "pass"
check "and says so"              "$(printf '%s' "$out" | grep -c 'no phase gate')" "1"

echo "a failing agent"
r=$(newrepo); cd "$r" || exit 1
git commit -q --allow-empty -m base
printf '#!/usr/bin/env bash\nexit 7\n' > "$BIN/claude"
out=$(phase_run review noop 30); rc=$?
check "reports error" "$(printf '%s' "$out" | sed -n 's/.*result=\([a-z]*\).*/\1/p' | head -1)" "error"
check "and returns non-zero" "$rc" "1"

cd /; rm -rf "$BIN"
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-refine/scripts/lib/phase.test.sh`
Expected: fails at the source — `phase.sh` does not exist.

- [ ] **Step 3: Write `phase.sh`**

```bash
#!/usr/bin/env bash
# One refine phase: invoke an agent headlessly, make its new files visible,
# gate its edits on the repo's tests, and undo them if the gate goes red.
# Sourced, never executed.
#
# The index is the revert mechanism. preflight staged everything before the
# first phase, so `git checkout -- .` restores exactly the pre-phase state with
# no stash, no snapshot bookkeeping and nothing to leak on a crash.

# <name> <prompt> <timeout-seconds> -> "phase=<n> result=<r> files=<n>" + prose
# Returns 1 only when the agent itself failed; a red gate is a handled outcome.
phase_run() {
  local name="$1" prompt="$2" secs="$3" out rc=0 gate files
  # timeout(1) is GNU; macOS ships it as gtimeout under coreutils. Without one
  # an unattended phase that stalls hangs forever with nobody watching.
  local TO=timeout; command -v timeout >/dev/null 2>&1 || TO=gtimeout
  command -v "$TO" >/dev/null 2>&1 \
    || { printf 'phase=%s result=error files=0\nno timeout(1) — brew install coreutils\n' "$name"; return 1; }

  out=$("$TO" "$secs" claude -p "$prompt" --permission-mode acceptEdits 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'phase=%s result=error files=0\n%s\n' "$name" "$out"
    return 1
  fi

  # Intent-to-add, not add: without this a file the phase CREATED is untracked
  # and `git diff` shows nothing, so the phase's output is partly invisible in
  # the one place the whole design says to read it.
  git add -N . >/dev/null 2>&1 || true
  files=$(git diff --name-only | wc -l | tr -d ' ')

  gate=$(iso_config_get test.command)
  if [ -z "$gate" ]; then
    printf 'phase=%s result=pass files=%s\nno phase gate configured (test.command unset)\n%s\n' \
      "$name" "$files" "$out"
    return 0
  fi
  if ( eval "$gate" ) >/dev/null 2>&1; then
    printf 'phase=%s result=pass files=%s\n%s\n' "$name" "$files" "$out"
  else
    git checkout -- . >/dev/null 2>&1 || true
    git clean -fdq >/dev/null 2>&1 || true
    printf 'phase=%s result=revert files=0\ngate failed, this phase was undone\n%s\n' "$name" "$out"
  fi
  return 0
}
```

- [ ] **Step 4: Run the tests**

Run: `bash skills/iso-refine/scripts/lib/phase.test.sh`
Expected: 13 passed, 0 failed.

Note `git clean -fdq` alongside `git checkout -- .`: checkout restores tracked files from the index but leaves the phase's *new* files on disk, so a reverted phase would otherwise still contribute the files it created.

---

### Task 7: `run` — the three phases

**Files:**
- Modify: `skills/iso-refine/scripts/refine.sh`
- Test: `skills/iso-refine/scripts/refine.test.sh`

**Interfaces:**
- Consumes: `phase_run` from Task 6, `cmd_preflight` from Tasks 3–4.
- Produces: exit 0 completed, 1 preflight refusal or phase error, 2 rebase conflict.

- [ ] **Step 1: Write the failing assertions**

```bash
echo "run"
PB=$(mktemp -d)
printf '#!/usr/bin/env bash\necho "$1" >> "%s/phases"\necho "phase=$1 result=pass files=0"\n' "$PB" > "$PB/phase"
chmod +x "$PB/phase"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/r && git commit -q --allow-empty -m w )
: > "$PB/phases"
( cd "$r" && ISO_REFINE_PHASE_STUB="$PB/phase" bash "$SH" run ) >/dev/null 2>&1
check "runs three phases"  "$(wc -l < "$PB/phases" | tr -d ' ')" "3"
check "architecture first" "$(sed -n 1p "$PB/phases")" "architecture"
check "simplify second"    "$(sed -n 2p "$PB/phases")" "simplify"
check "review last"        "$(sed -n 3p "$PB/phases")" "review"

: > "$PB/phases"
( cd "$r" && ISO_REFINE_PHASE_STUB="$PB/phase" bash "$SH" run --no-simplify ) >/dev/null 2>&1
check "--no-simplify drops one" "$(wc -l < "$PB/phases" | tr -d ' ')" "2"
check "and it is simplify"      "$(grep -c simplify "$PB/phases")" "0"

( cd "$r" && ISO_REFINE_PHASE_STUB="$PB/phase" bash "$SH" run ) >/dev/null 2>&1
check "a clean run exits 0" "$?" "0"

printf '#!/usr/bin/env bash\necho "phase=$1 result=error files=0"; exit 1\n' > "$PB/phase"
( cd "$r" && ISO_REFINE_PHASE_STUB="$PB/phase" bash "$SH" run ) >/dev/null 2>&1
check "a phase error exits 1" "$?" "1"
: > "$PB/phases"
rm -rf "$PB"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: FAIL — no `run` verb.

- [ ] **Step 3: Write `cmd_run`**

```bash
# The three phase prompts. The architecture phase's override is the one place
# non-interactivity is asserted rather than configured: its SKILL.md ends by
# asking which candidate to explore, and under -p there is nobody to answer.
ARCH_PROMPT='/improve-codebase-architecture implement the strong candidates directly. Do not write an HTML report, do not open a browser, do not ask which candidate to explore, and do not enter a grilling loop. Apply the changes and summarise what you changed and why in under ten lines.'
SIMPLIFY_PROMPT='/simplify'
REVIEW_PROMPT='/review medium --fix'

ISO_REFINE_TIMEOUT="${ISO_REFINE_TIMEOUT:-1800}"

# ------------------------------------------------------------------- run
cmd_run() {
  local do_arch=1 do_simp=1 do_rev=1 pre phases summary key rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-architecture) do_arch=0 ;;
      --no-simplify)     do_simp=0 ;;
      --no-review)       do_rev=0 ;;
      *) die "unknown flag: $1" ;;
    esac
    shift
  done

  # cmd_preflight dies on refusal (exit 1) and exits 2 on a rebase conflict, so
  # a non-zero here has already left the process. The assignment is just to
  # capture the shas.
  pre=$(cmd_preflight)

  # The stub seam. Real runs source lib/phase.sh; the self-check points this at
  # a script so the whole orchestration is assertable without an agent.
  if [ -n "${ISO_REFINE_PHASE_STUB:-}" ]; then
    phase_run() { "$ISO_REFINE_PHASE_STUB" "$@"; }
  else
    # shellcheck source=/dev/null
    . "$HERE/lib/phase.sh"
  fi

  # `if`, not `[ x ] && { ... }`: under set -e a false test at the end of a
  # command list exits the shell, so `--no-architecture` would abort the run
  # instead of skipping a phase.
  phases=""
  if [ "$do_arch" -eq 1 ]; then
    phases="$phases$(phase_run architecture "$ARCH_PROMPT" "$ISO_REFINE_TIMEOUT")"$'\n' || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$do_simp" -eq 1 ]; then
    phases="$phases$(phase_run simplify "$SIMPLIFY_PROMPT" "$ISO_REFINE_TIMEOUT")"$'\n' || rc=1
  fi
  if [ "$rc" -eq 0 ] && [ "$do_rev" -eq 1 ]; then
    phases="$phases$(phase_run review "$REVIEW_PROMPT" "$ISO_REFINE_TIMEOUT")"$'\n' || rc=1
  fi
  return "$rc"
}
```

Add `run)` to the dispatch and `|run` to the usage string.

- [ ] **Step 4: Run the tests**

Run: `bash skills/iso-refine/scripts/refine.test.sh` and `bash scripts/dispatch-integrity.test.sh`
Expected: 25 passed / 0, sweep green.

---

### Task 8: the summary

**Files:**
- Modify: `skills/iso-refine/scripts/refine.sh`
- Test: `skills/iso-refine/scripts/refine.test.sh`

**Interfaces:**
- Consumes: `iso_track` from `iso-config/scripts/lib/track.sh`, `comment` from Task 2.
- Produces: the summary on stdout; the same text posted to a ticket when one exists.

- [ ] **Step 1: Write the failing assertions**

```bash
echo "summary"
PB2=$(mktemp -d)
printf '#!/usr/bin/env bash\necho "phase=$1 result=pass files=0"\necho "said something"\n' > "$PB2/phase"
chmod +x "$PB2/phase"
r=$(newrepo); ( cd "$r" && git checkout -q -b feat/sum && git commit -q --allow-empty -m w )
out=$( cd "$r" && ISO_REFINE_PHASE_STUB="$PB2/phase" bash "$SH" run 2>/dev/null )
check "names the index sha"   "$(printf '%s' "$out" | grep -c 'index=[0-9a-f]')" "1"
check "one line per phase"    "$(printf '%s' "$out" | grep -c '^phase=')" "3"
TB=$(mktemp -d)
printf '#!/usr/bin/env bash\necho "$@" >> "%s/track"\ncat >> "%s/body"\n' "$TB" "$TB" > "$TB/tracking.sh"
chmod +x "$TB/tracking.sh"
( cd "$r" && ISO_TRACKING_SH="$TB/tracking.sh" ISO_REFINE_PHASE_STUB="$PB2/phase" bash "$SH" run ) >/dev/null 2>&1
check "no ticket means no comment" "$(grep -c 'comment' "$TB/track" 2>/dev/null || echo 0)" "0"
rm -rf "$TB" "$PB2"
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL on "names the index sha" — `cmd_run` prints the preflight block but no assembled summary.

- [ ] **Step 3: Assemble and post**

Source `track.sh` at the top of `refine.sh`:

```bash
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/track.sh)"
```

Collect each phase's output into a variable instead of printing it directly, then at the end of `cmd_run`:

```bash
  # Capped per phase: this text crosses into a ticket comment through redact,
  # and an unbounded phase transcript there is noise, not a record.
  summary=$(printf '%s\n%s\n' "$pre" "$phases" | head -c 8000)
  printf '%s\n' "$summary"

  # A ticket is optional. No tracker, or no row for this branch, means the
  # terminal is the whole report — which is the normal case for a quick branch.
  key=$(iso_track ticket-for-branch 2>/dev/null | cut -f1)
  [ -n "$key" ] && printf '%s\n' "$summary" | iso_track comment "$key" >/dev/null 2>&1
  return "$rc"
```

- [ ] **Step 4: Run the tests**

Run: `bash skills/iso-refine/scripts/refine.test.sh`
Expected: 29 passed, 0 failed.

---

### Task 9: `SKILL.md`

**Files:**
- Create: `skills/iso-refine/SKILL.md`

- [ ] **Step 1: Write it**

Frontmatter `name` and `description` following the house pattern — the description names the invocation, the flags, and what it leaves behind, because that is what the agent matches on. Body covers: the three phases and their order, the staging contract (`git diff --cached` is yours, `git diff` is the skill's), the flags, the exit codes, the phase gate and what "no gate" means, and the rebase behaviour including the published-branch refusal.

Say plainly that the architecture phase's non-interactivity rests on prompt text, not a contract — a reader debugging a hung phase needs that sentence.

- [ ] **Step 2: Verify the skill is discoverable**

Run: `node scripts/install.js`
Expected: `iso-refine` symlinked into both agents and added to `plugins/isaiascope-eng/.claude-plugin/plugin.json`.

---

### Task 10: delete the old skills and fix every caller

**Files:**
- Delete: `skills/iso-review/`, `skills/iso-todo/`
- Modify: `AGENTS.md`, `README.md`, `skills/iso-plan/SKILL.md`, `skills/iso-issue-tracking/SKILL.md`, `docs/adr/0004-iso-config-two-scope-overlay.md`

- [ ] **Step 1: Delete**

```bash
git rm -r skills/iso-review skills/iso-todo
```

- [ ] **Step 2: Find every live reference**

```bash
grep -rn 'iso-review\|iso-todo' --include='*.md' --include='*.sh' --include='*.js' --include='*.json' . \
  | grep -v graphify-out | grep -v docs/iso/logs | grep -v docs/superpowers
```

Historical specs and plans under `docs/superpowers/` stay as written — they record what was true when they were written.

- [ ] **Step 3: Update `AGENTS.md`**

Replace the two tree lines with one:

```
  iso-refine/SKILL.md              — three-phase refine of the branch's changes, headless, no commit
```

- [ ] **Step 4: Update the rest**

`README.md`, `skills/iso-plan/SKILL.md`, `skills/iso-issue-tracking/SKILL.md`, and the passing mention in `docs/adr/0004`. `CONTEXT.md` was already done when the design was agreed.

- [ ] **Step 5: Regenerate the manifests**

```bash
node scripts/install.js
```

Expected: both deleted skills pruned as dangling links, `plugin.json` regenerated. Commit the regenerated `plugin.json` diff with the rest.

- [ ] **Step 6: Run everything**

```bash
node --test scripts/*.test.js
for t in skills/*/scripts/*.test.sh skills/*/scripts/lib/*.test.sh \
         skills/*/scripts/adapters/*.test.sh scripts/*.test.sh; do
  printf '%-34s ' "$(basename "$t")"; bash "$t" >/dev/null 2>&1 && echo ok || echo FAIL
done
```

Expected: every suite ok. `dispatch-integrity` must still report ≥5 dispatching scripts — deleting two skills reduces the count, and its vacuous-sweep guard is what catches a sweep that stopped looking.

- [ ] **Step 7: Leave it uncommitted**

Do not commit. The user runs `/iso-commit` when they have read the diff.

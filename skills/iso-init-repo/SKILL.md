---
name: iso-init-repo
description: Set up a repo with IsaiaScope governance defaults — GitHub repo creation, prod/test/dev branch structure with protection, and branch-gate CI enforcing the cascade order. Use when the user runs /iso-init-repo or asks to set up repo governance.
---

# iso-init-repo

Set up GitHub repo governance. Run from inside the target repo.

All templates live in `templates/` next to this file.

## Pre-flight

Run these checks before any step.

### git
```bash
command -v git &>/dev/null \
  || { echo "✗ git not found. Install Xcode CLI tools: xcode-select --install"; exit 1; }
```

### gh (GitHub CLI)
```bash
if ! command -v gh &>/dev/null; then
  echo "⚠ gh not found — installing..."
  brew install gh
  command -v gh &>/dev/null \
    || { echo "✗ gh install failed. Run manually: brew install gh"; exit 1; }
  echo "✓ gh installed"
fi
```

### gh authentication

Authentication is interactive — cannot be automated. If not authenticated, stop and run the login command manually.

```bash
if ! gh auth status &>/dev/null; then
  echo "⚠ gh not authenticated."
  echo "  Run: gh auth login"
  echo "  Then re-run /iso-init-repo"
  exit 1
fi
```

### Remote detection
```bash
git remote get-url origin 2>/dev/null || echo "no remote"
```

All checks pass → proceed to Step 1.

## Idempotency

**Every step probes its own postcondition first and skips when already met.**
Re-running on a governed repo is safe and expected — it is the documented path
after upgrading a plan, and the only way a repo set up by an older version of
this skill gets repaired.

Report each skip out loud (`⏭️ dev already default`) rather than silently doing
nothing. A step that is quiet about skipping is indistinguishable from a step
that is broken.

## Step 1 — GitHub repo

### No remote → create

Ask user for repo name (default: current directory name) and visibility (private/public).

```bash
gh repo create <name> --private --source=. --remote=origin --push
```

### Remote exists → verify

```bash
gh repo view --json nameWithOwner,visibility -q '"⏭️ repo exists: \(.nameWithOwner) (\(.visibility))"'
```

Confirm accessible, then continue.

## Step 2 — Branch structure

Target: `dev` (default, daily work) ← `test` (staging) ← `prod` (release)

Record the branch the repository started on before anything moves — Step 2's
second half needs it, and by then HEAD has moved:

```bash
WAS=$(git symbolic-ref --short HEAD)   # likely 'main'
scripts/init-repo.sh create-branches
```

Then the default branch, which is the one `gh` call here. Set it once, then
never move it again:

```bash
cur=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
governed=$(scripts/init-repo.sh branches | tr '\n' ' ')
case " $governed develop " in
  *" $cur "*) echo "⏭️ '$cur' already a governed default branch — left alone" ;;
  *) gh repo edit --default-branch "$(scripts/init-repo.sh default-branch)" ;;
esac
```

A repository whose default branch is not its development branch is unusual but
deliberate for a marketplace: `/plugin marketplace add` clones whatever GitHub
reports as default, so consumers must land on released work. Set
`branches.default` in the repository's overlay; this skill reads it rather than
assuming. That is the fix for the recurring annoyance where re-running this
step reset the default to `dev` and quietly served unreleased daily work to
every consumer.

**Which of the three is default is a repo-shaped decision, so this step sets one
and then defers to it.** A default already pointing at `dev`, `develop`, `test`
or `prod` is left exactly as it is; only `main`/`master`/anything else is moved,
and it moves to `dev`.

The trade-off it is deferring to:

| default | wins | costs |
|---|---|---|
| `dev` | the web UI's "Compare & pull request" opens with base `dev` — right every time | a fresh clone, and anything that tracks the default, gets unreleased work |
| `prod` | clones get released work — the right call when the repo is consumed, e.g. a plugin marketplace | web-UI PRs open with base `prod`, which the branch gate rejects; you retarget by hand |

`iso-push` is unaffected either way: it resolves the base by probing `origin` for
`dev`/`develop`, and always passes `gh pr create --base` explicitly. Nothing in
the promotion flow reads the default branch.

To choose `prod`, run `gh repo edit --default-branch prod` once. This step will
preserve it from then on — an earlier version reset it to `dev` on every re-run,
silently undoing the choice.

`main` is deleted only when it was the starting point **and** `prod` now exists
on origin with that history. Never delete it to reach the target shape — the
target is reached by creating `prod`, and removing `main` is only tidying up
after that succeeded.

```bash
scripts/init-repo.sh retire-main "$WAS"
```

It refuses unless production already contains every commit `main` carries. That
ancestor test is the whole safety property, which is why it lives in a script
with an assertion behind it rather than in this paragraph.

## Step 3 — GitHub files

**Commits only — this skill never pushes to `dev`, `test` or `prod`.** Those
branches are PR-only from the moment they exist, and a setup skill that pushed
straight to one would be breaking the rule it is here to write.

Read `templates/ci-branch-gate.yml` → write to `.github/workflows/ci-branch-gate.yml`.

If `.github/workflows/ci-prod-gate.yml` exists, this supersedes it — `git rm` the old file in the same commit.

Enforces source branch on both gated targets:
- PR → `prod` must come from `test`
- PR → `test` must come from `dev`

`dev` restricts no source — any feature branch may open a PR into it. That is
about *where a PR may come from*, not about direct pushes: `dev` is PR-only too.

Probe first — skip when the gate is already on `origin/dev` and matches:

```bash
scripts/init-repo.sh gate-status   # absent | stale | current
```

`current` → skip to Step 4. `absent` or `stale` → write the workflow below.

Otherwise write the file and **stop there**.

**This skill never commits, never branches, never pushes.** It leaves the file
in the working tree exactly where it wrote it. Committing is `/iso-commit`'s
job — it decides the message, the split, and what gets staged. Branching and
landing are `/iso-push`'s.

That also sidesteps a trap: `dev` is PR-only, so a commit made on local `dev`
could never be pushed — `dev` cannot PR into itself. By not committing at all,
the skill has no branch to be wrong about.

Leave it uncommitted and say so:

```
✓ .github/workflows/ci-branch-gate.yml written (uncommitted)
  Run /iso-commit when ready, then /iso-push to land it on dev.
```

## Step 4 — Branch protection

All three branches become PR-only. `required_pull_request_reviews` is what
removes direct push — with it set, a `git push origin dev` is rejected.

**Precondition: the gate must already be on `origin/dev`.** 4b marks
`Verify Source Branch` a *required* check. GitHub accepts a required context it
has never seen and then waits for it forever — so if the workflow is only in the
working tree, every PR into `test` and `prod` hangs pending, with no way to merge
and no failure explaining why.

Since Step 3 deliberately leaves the file uncommitted, **4b usually runs on a
later invocation** — after `/iso-commit` and `/iso-push` have landed it. That is
normal, not an error: the skill is re-runnable precisely so this can happen in
two passes.

```bash
[ "$(scripts/init-repo.sh gate-status)" = absent ] \
  && echo "⏭️ gate not on the development branch yet — land it with /iso-commit
     then /iso-push, and re-run /iso-init-repo."   # → skip to Step 5
```

Skip, don't `exit 1` — the earlier steps did real work and Step 5 should still
report it.

### 4a — Capability probe

Branch protection is paywalled: a **private** repo on **GitHub Free** returns `403` from the protection API. Probe before writing anything.

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

case "$(gh api "repos/$REPO/branches/dev/protection" 2>&1)" in
  *'"status":"403"'*) GATE_OK=0 ;;  # paywalled — private repo on Free
  *)                  GATE_OK=1 ;;  # readable, or 404 "not set" — API available
esac
echo "GATE_OK=$GATE_OK"
```

`GATE_OK` decides how much of the gate can be enforced. Step 3 has already run either way — the workflow is identical in both cases; only its consequence differs.

| | `GATE_OK=1` (public, or paid plan) | `GATE_OK=0` (private + Free) |
|---|---|---|
| Step 4b protection | ✅ applied | ⏭️ skipped (403) |
| Step 3 workflow | ✅ installed | ✅ installed |
| Wrong-source PR | **blocked** — merge button disabled | annotated — red ✗, merge still allowed |

`GATE_OK=0` → skip 4b and warn — Step 3 has already landed the gate:

```
⚠ Branch protection unavailable — private repo on GitHub Free.
  GitHub returns 403 from the protection API.

  The branch gate is still installed, but it can only advise:
  a wrong-source PR gets a red ✗ and an error annotation, and stays mergeable.
  Nothing blocks a direct push to prod either.

  To enforce: upgrade to GitHub Pro, or make the repo public.
  Then re-run /iso-init-repo — Steps 1–3 are idempotent; only 4b is added.
```

Then run 4c and skip to Step 5.

### 4c — Local guard (only when `GATE_OK=0`)

With protection unavailable, the pre-push hook is the only thing in the repo
that can refuse a direct push. Install it *only* in this branch — on a public or
paid repo GitHub already refuses, and a second copy of the rule is just somewhere
for the two to disagree.

`templates/pre-push-branch-guard.sh` is a **block, not a whole hook** — it has no
shebang and no `exit`, and it sets `rc=1` in a host that owns the accumulator.
It is wrapped in markers so it can be found, replaced and removed:

```
# >>> iso-init-repo branch guard >>>
# <<< iso-init-repo branch guard <<<
```

Three cases:

**No hook** → generate a minimal host around the block.

```bash
scripts/init-repo.sh install-hook
```

One command, three cases: no hook yet (write header, guard, rc summary), a hook
carrying the `# >>> iso-init-repo branch guard >>>` markers (replace between
them), or someone else's hook with no markers (splice the guard in above the rc
summary, or above the final `exit` if there is none). It also sets
`core.hooksPath`, without which git ignores `.githooks/` entirely and the hook
just written protects nothing.

### Verify the hook actually refuses

A hook can install and still do nothing — `core.hooksPath` unset, file not
executable, block landed after the `exit`. All of those exit 0 and produce a
guard that guards nothing, discovered on the one day it mattered. Test-fire it:

```bash
scripts/init-repo.sh verify-hook
```

It feeds the hook a push to production and fails if the hook allows it, then
checks `core.hooksPath` — a hook that is perfectly correct and never consulted
fails the same way as one that is wrong.

Leave it uncommitted, same as Step 3:

```
✓ .githooks/pre-push written (uncommitted), core.hooksPath set
  Run /iso-commit when ready.
```

`core.hooksPath` is local config, not a file — it takes effect immediately and
is never committed either way.

Tell the user plainly what they just got:

```
⚠ .githooks/pre-push installed — local guard only.

  A fresh clone needs `git config core.hooksPath .githooks` before it runs at
  all, it cannot see a push made from the web UI or another machine, and like
  every client-side hook it can be skipped.

  It is a guardrail against habit, not a control. Delete it once 4b can run.
```

### 4b — Apply protection (only when `GATE_OK=1`)

`required_status_checks.contexts` is what converts the gate from advisory to
blocking. With `null` there, protection still forces a PR — but a failing gate
would not stop the merge.

**Derive the context, never hardcode it.** It is the **job name** from the
workflow (not the workflow name), so read it back out of the file just installed:

```bash
CONTEXT=$(scripts/init-repo.sh gate-context)
```

Read from the workflow, never retyped: a job name written twice is a job name
that drifts, and the drift shows up as a branch nobody can merge into.

Rename the job later and a re-run re-syncs protection to the new name, because
the comparator below reads a mismatch and repairs it.

### Compare before writing

Protection may already exist — and may be *wrong*. Versions of this skill before
the branch-gate rework wrote `"required_status_checks": null`, which forces a PR
but lets a failing gate merge clean. Skipping on "has protection" would preserve
that bug forever, so compare the two fields this skill actually asserts and leave
everything else untouched:

```bash
needs_apply() {   # $1 = branch, $2 = required context ("" for dev)
  local cur; cur=$(gh api "repos/$REPO/branches/$1/protection" 2>/dev/null) || return 0
  [ "$(jq -r '.required_pull_request_reviews != null' <<<"$cur")" = true ] || return 0
  [ -z "$2" ] && return 1
  [ "$(jq -r --arg c "$2" '(.required_status_checks.contexts // []) | index($c) != null' <<<"$cur")" = true ] \
    && return 1 || return 0
}
```

Approval counts, dismiss-stale, linear history and anything else you set by hand
are neither read nor written.

```bash

# prod and test are gated on the workflow; dev requires a PR but gates no source.
# All three are equally PR-only — only the SOURCE differs.
DEVELOPMENT=$(scripts/init-repo.sh branches | head -1)
for b in $(scripts/init-repo.sh branches); do
  want="$CONTEXT"; [ "$b" = "$DEVELOPMENT" ] && want=""
  if ! needs_apply "$b" "$want"; then
    echo "⏭️ $b protection already correct"
    continue
  fi
  scripts/init-repo.sh protection-json "$b" \
    | gh api "repos/$REPO/branches/$b/protection" --method PUT --input -
done
```

Branch protection can't restrict PR source branch — that's what `ci-branch-gate.yml` handles.

### Verify (read back)

A PUT that returns 200 can still have applied the wrong thing — that is exactly
how the `null` bug survived. Re-run the comparator against what GitHub now
reports, and only then claim success:

```bash
DEVELOPMENT=$(scripts/init-repo.sh branches | head -1)
for b in $(scripts/init-repo.sh branches); do
  want="$CONTEXT"; [ "$b" = "$DEVELOPMENT" ] && want=""
  needs_apply "$b" "$want" \
    && { echo "✗ $b protection did not take effect"; exit 1; } \
    || echo "✓ $b verified"
done
```

## Step 5 — Summary

`GATE_OK=1`:

```
✓ GitHub repo created/configured
✓ Branches: dev ← test ← prod (default branch reported above, left alone if already governed)
✓ Protection: PR required on dev, test, prod (no direct push)
✓ .github/workflows/ci-branch-gate.yml — test accepts PRs from dev only
                                       — prod accepts PRs from test only
```

`GATE_OK=0`:

```
✓ GitHub repo created/configured
✓ Branches: dev ← test ← prod (default branch reported above, left alone if already governed)
⚠ Protection: SKIPPED — private repo on GitHub Free (403 from protection API)
✓ .github/workflows/ci-branch-gate.yml — written, ADVISORY ONLY
✓ .githooks/pre-push — written, core.hooksPath set, refuses prod

  A wrong-source PR gets a red ✗ and an error annotation naming the rule,
  but stays mergeable — and only this working copy refuses a direct push.
  Upgrade to GitHub Pro or make the repo public, then re-run for Step 4b.
```

Always close with the handoff — the skill wrote files and stopped:

```
Nothing committed. Run /iso-commit to commit, then /iso-push to land on dev.
```

Cascade: `<any branch> → dev → test → prod`

Branch gate: a PR that skips a rung (feature → `test`, `dev` → `prod`) fails CI automatically.

Day-to-day work runs through the standalone skills:

- `/iso-commit` — conventional-commit message + commit
- `/iso-push` — rebase onto dev, push, open PR, `--cascade test|prod` to promote

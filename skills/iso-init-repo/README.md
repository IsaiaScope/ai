# 🏛️ iso-init-repo

> Wire GitHub repo governance in one command — branch structure, protection rules, and a CI branch-gate that keeps releases moving in one direction.

---

## 🎯 The Shape

```
any branch  (feature work, fixes)
     ↓  PR — any source allowed
    dev  (daily work — GitHub default branch)
     ↓  PR — source must be dev
   test  (staging / QA)
     ↓  PR — source must be test
   prod  (release)
```

Three rules, and they are separate things people routinely conflate:

| Rule | Enforced by |
|---|---|
| **No direct pushes** to `dev`, `test`, `prod` — every change enters by PR | `required_pull_request_reviews` |
| **No rung-skipping** — `feat/x` cannot PR into `test`, `dev` cannot PR into `prod` | `ci-branch-gate.yml` + `required_status_checks` |
| **No force pushes** to the three | branch protection |

`dev` accepts a PR from anywhere. That is about *where a PR may come from* — it does **not** mean you may push to `dev` directly. All three branches are PR-only.

---

## ⚠️ The Catch: GitHub Paywalls Enforcement

**Branch protection is a paid feature for private repositories.** On a private repo on the Free plan, the protection API answers every request the same way:

```json
{ "message": "Upgrade to GitHub Pro or make this repository public to enable this feature.",
  "status": "403" }
```

Rulesets — the newer replacement API — return the identical 403. There is no free server-side path.

This is the single fact that shapes the whole skill. It probes for that 403 and adapts, rather than pretending the rules landed.

> **The axis is `private + Free`, not `private`.** A private repo on Pro, Team, or Enterprise behaves exactly like a public one here.

---

## 🔀 What You Actually Get

### Capabilities

| | 🌍 Public or 💳 Paid | 🔒 Private + Free |
|---|:---:|:---:|
| Direct push to `dev`/`test`/`prod` | **rejected by GitHub** | refused locally only |
| Force push to those branches | **rejected** | allowed |
| PR into `dev` | **required** | optional (convention) |
| Wrong-source PR (`feat/x → test`) | **merge blocked** | red ✗, merges anyway |
| Wrong-source PR (`dev → prod`) | **merge blocked** | red ✗, merges anyway |
| Edit via github.com web UI | **subject to the rules** | unguarded |
| Push from another clone / machine | **subject to the rules** | unguarded |

### What the skill installs

| | 🌍 Public or 💳 Paid | 🔒 Private + Free |
|---|:---:|:---:|
| Repo + `prod`←`test`←`dev` branches | ✅ | ✅ |
| `.github/workflows/ci-branch-gate.yml` | ✅ | ✅ |
| Branch protection rules | ✅ | ⏭️ skipped — 403 |
| `required_status_checks` wiring | ✅ | ⏭️ skipped — 403 |
| `.githooks/pre-push` guard | ⏭️ not needed | ✅ installed |

The workflow is byte-identical in both columns. **Only its consequence differs** — detection is free, enforcement is not.

---

## 🧩 Steps

Runs from inside any git repo, after a pre-flight check.

0. **✈️ Pre-flight** — verifies `git`, installs `gh` if missing, hard-stops when `gh` isn't authenticated (login is interactive and can't be scripted)
1. **🐙 GitHub repo** — creates a private/public repo, or verifies the existing remote
2. **🌿 Branch structure** — `prod` ← `test` ← `dev`, sets `dev` as default, retires `main` once `prod` holds its history
3. **🚦 Branch gate** — writes `ci-branch-gate.yml`
4. **🔒 Protection** — probes the API, then applies rules (`4b`) or installs the local guard (`4c`)
5. **📋 Summary** — reports what is enforced and what merely advises

**Every step is idempotent.** Each probes its own postcondition, prints `⏭️ already done`, and moves on. Re-running is the documented path after upgrading a plan — and the only way a repo governed by an older version gets repaired.

**It never commits, branches, or pushes.** Files are left in the working tree; [`iso-commit`](../iso-commit/) decides the message and the split, [`iso-push`](../iso-push/) opens the PR. Branch *creation* in step 2 is the one exception — branches have to exist on origin to be governed at all.

That handoff also avoids a trap. `dev` is PR-only, so a commit made on local `dev` could never be pushed — `dev` cannot PR into itself. By not committing, the skill has no branch to be wrong about.

> **Step 4b usually runs on a second invocation.** Protection can only mark the gate a required check once the workflow is actually on `origin/dev` — GitHub waits forever on a check it has never seen. So: run the skill, `/iso-commit`, `/iso-push`, run the skill again. It skips everything already done.

---

## ▶️ Trigger

```
/iso-init-repo
```

Or ask: *"set up repo governance"*, *"create branch structure"*, *"add prod protection"*

---

## ✅ Output

**Public or paid**

```
✓ GitHub repo created/configured
✓ Branches: dev (default) ← test ← prod
✓ Protection: PR required on dev, test, prod (no direct push)
✓ .github/workflows/ci-branch-gate.yml — test accepts PRs from dev only
                                       — prod accepts PRs from test only
✓ prod verified   ✓ test verified   ✓ dev verified
```

**Private + Free**

```
✓ GitHub repo created/configured
✓ Branches: dev (default) ← test ← prod
⚠ Protection: SKIPPED — private repo on GitHub Free (403 from protection API)
✓ .github/workflows/ci-branch-gate.yml — installed, ADVISORY ONLY
✓ .githooks/pre-push — refuses direct pushes from this working copy
```

Every ✓ is **observed, not claimed** — protection is read back after writing, and the hook is test-fired with a fake `prod` ref before the skill reports success.

---

## 🪝 The Local Guard

Installed only when protection is unavailable. It refuses `git push origin dev|test|prod` from your working copy.

**It is a habit guard, not a control.** For a solo repo the realistic failure is your own muscle memory, and this catches exactly that. It cannot see:

- a merge or file edit made in the GitHub web UI
- a push from another clone or another machine
- anything in a clone where `core.hooksPath` was never set

Client-side hooks are also skippable by design — git provides a documented escape for every one of them. That is not a flaw in this hook; it is what "client-side" means, and it is why the paid tiers are the only place real enforcement can live.

### Setup, once per clone

```bash
git config core.hooksPath .githooks
```

**Not committed. Not automatic.** A fresh clone has no guard until someone runs it, with nothing to indicate it's missing.

### Removing it

The block is marker-delimited:

```bash
# >>> iso-init-repo branch guard >>>
# <<< iso-init-repo branch guard <<<
```

Delete between the markers once you're on a paid plan or public. Keeping both means two copies of one rule with room to disagree.

---

## 🔧 Dependencies

| Tool | Purpose | Source |
|---|---|---|
| `git` | branches, remotes, hooks | [git-scm.com](https://git-scm.com) |
| `gh` | repo creation, protection API | [cli.github.com](https://cli.github.com) |
| `jq` | building and comparing protection payloads | ships with `gh` |

```bash
brew install gh    # macOS
gh auth login
```

Stack-agnostic — nothing assumes Node, Python, or a `package.json`.

---

## 📦 Templates

| Template | Writes to | Purpose |
|---|---|---|
| `ci-branch-gate.yml` | `.github/workflows/ci-branch-gate.yml` | enforces cascade order into `test` and `prod` |
| `pre-push-branch-guard.sh` | `.githooks/pre-push` | refuses direct pushes locally — **private + Free only** |

Edit either to change behavior; no SKILL.md change needed.

---

## 📎 Notes

- **Protection needs repo admin access** *and* a public repo or paid plan. The skill probes with a `GET` and distinguishes `403` (paywalled → advisory mode) from `404` (available, not yet set → proceed).
- **`required_status_checks.contexts` is what makes a failing gate block a merge.** With `null` there, protection still forces a PR, but a wrong-source PR merges clean. Earlier versions of this skill wrote `null` — the comparator detects that shape and repairs it on re-run.
- **The context string is the *job* name** (`Verify Source Branch`), not the workflow name. The skill derives it from the installed workflow rather than hardcoding it, so renaming the job and re-running re-syncs protection.
- **A required check that never reports blocks forever.** GitHub accepts a context it has never seen and waits indefinitely, so step 4 refuses to run until the workflow is actually on `origin/dev`.
- **`enforce_admins: false`** — an admin can bypass every rule above. Deliberate for a solo repo; worth knowing it's a hole.
- **Only asserted fields are compared.** Approval counts, dismiss-stale, linear history and anything else you set by hand are neither read nor written.
- **`ci-branch-gate.yml` passes branch names through `env:`**, never inline `${{ }}` in `run:`. A fork PR branch name is attacker-controlled, and inline interpolation would splice it into the shell.
- **The gate is `on: pull_request`.** A direct push fires no workflow at all — not a failing one, none. There is nothing to report because a push is not a pull request.

---

## 🔗 Related

- [`iso‑ai‑init`](../iso-ai-init/) — AI *tooling* setup (caveman, graphify, statusline); pairs with this skill's repo *governance*.
- [`iso‑commit`](../iso-commit/) — conventional-commit message + commit.
- [`iso‑push`](../iso-push/) — push, open a PR against `dev`, land it fast-forward; `--cascade test|prod` to promote.
- [`iso‑write`](../iso-write/) — builds reviewed work on the feature branches this governance protects.

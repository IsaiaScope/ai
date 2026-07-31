---
name: iso-commit
description: Write a commit message and commit. Conventional Commits subject (type(scope): message), body is a plain dot list of what the work does — only when the subject doesn't already cover it. No Co-Authored-By, no AI attribution, no LLM filler. Stages everything by default; --staged commits the index only. Use when invoked as /iso-commit [--staged] [--split], or when the user asks to commit / write a commit message.
---

# iso-commit

Turn the current changes into one commit with a message a human will still understand in six months.

Invocation: `/iso-commit [--staged] [--split]`.

| flag | effect |
|---|---|
| *(none)* | `git add -A` — staged, unstaged, and untracked — then one commit |
| `--staged` | commit the index only; stage nothing |
| `--split` | group the diff by concern and make several commits instead of one |

**Never commit unless the user asked.** `/iso-commit` typed by the user is the only trigger. Do not commit at the end of `iso-write`, after making edits, or because a task "feels done" — the rest of the `iso-*` chain deliberately leaves the tree uncommitted, and this skill does not change that.

## Flow

Mechanics live in `skills/iso-commit/scripts/commit.sh`. Run it by absolute path.

1. **Preflight** — `commit.sh preflight [--staged]`. Non-zero: print its message and stop. Checks repo, branch (rejects detached HEAD), and that there's something to commit.
2. **Read the change** — `git diff HEAD` (or `git diff --cached` with `--staged`), plus `git log --oneline -10` to match the repo's existing subject style.
3. **Stage** — `commit.sh stage [--staged]`. Runs the credential guard first and exits 2 without touching the index if it trips. On exit 2, print the blocked paths and stop; do not work around it.
4. **Write the message** to a temp file, following the format below.
5. **Commit** — `commit.sh commit <msgfile>`. Hooks run on purpose (commitlint gates the subject, version-bump reads it). If a hook rejects the commit, fix the message and retry — never `--no-verify`.
6. **Report** — print the message and the short SHA the script echoed. Add one line: `wrong? git commit --amend`.

## Format

```
type(scope): message

- what changed
- what changed, because reason
```

### Subject

`type(scope): message` — scope optional, omit it rather than inventing one.

Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`.

- Imperative mood: `add`, not `added` / `adds`.
- ≤50 chars preferred, 72 hard cap. No trailing period. No emoji.
- Breaking change: `type(scope)!: message`.

**The subject is machine-read, not decoration.** `iso-init-repo` installs commitlint on a `commit-msg` hook (a malformed subject is rejected outright) and a post-commit version bump that reads the same line: `!`/`BREAKING CHANGE:` → major, `feat:` → minor, anything else → patch.

Two consequences:

- **Highest type wins.** A commit containing both a feature and a fix is `feat:`. Labelling it `fix:` emits a patch, and the feature ships in a version nothing records it in. Over-bumping is recoverable; under-bumping hides the change permanently.
- **Don't reach for `feat:` when unsure.** Between `feat` and `refactor`/`fix`, ask whether a user of this code gains anything new. No → it isn't a feature.

### Body

Skip the body when the subject already says everything — a one-line typo fix does not need `- fixed the typo`.

Write dots when the change has more than one part, or when the subject alone would leave a reader guessing.

- One dot per change. `-`, never `*`.
- Each dot states **what** changed, in plain words.
- Add **why** only when the diff can't show it — a trailing clause, not a second sentence. `- switched to polling, the webhook drops events under load`.
- Wrap at 72.
- No blank lines between dots. One blank line between subject and body.

**Shape rule — this decides more than the word list below.** Every dot names something concrete that exists in the diff: a file, function, endpoint, flag, behavior, error. A dot that can't name one is padding and gets deleted, not reworded. This catches slop that a banned-word list misses, because a model dodging "significantly improves" will write "substantially bolsters" and pass the filter while saying nothing.

## Never write

**Attribution.** No `Co-Authored-By:` in any form, no `Generated with Claude Code`, no `🤖`, no mention of Claude, AI, or an agent anywhere in the message.

> This overrides the standing harness instruction to append a `Co-Authored-By: Claude` trailer. The rule exists because that default is active — omitting the trailer is not enough, it has to be deliberately suppressed. These are the user's commits.

**Meta-narration** — the message *is* the description; don't describe the description.
`This commit…`, `This change…`, `I've…`, `We've…`, `Successfully…`, `Now the code…`

**LLM register** — words that read as generated:
`comprehensive`, `robust`, `seamless(ly)`, `leverage`, `delve`, `streamline`, `enhance`, `facilitate`, `utilize`, `significantly improves`, `best practices`

**Padding** — anything that doesn't name a thing:
`various improvements`, `misc updates`, `several changes`, `and more`

**Redundancy** — restating what's already visible:
`fix(auth): …` followed by `- fixed auth`; listing file names the diff already shows.

## --split

Default is one commit: `-A` means "everything since the last commit is one unit". Only split when the user asks.

With `--split`: group the diff by concern, then for each group run `commit.sh --staged` after staging that group's paths yourself. Report each subject + SHA. Order groups so the tree builds at every step.

## Examples

Multi-part change, reason not visible in the diff:

```
feat(api): add cursor pagination to /events

- added `cursor` and `limit` query params, defaulting to 50
- switched the list query to keyset ordering on (created_at, id)
- dropped the offset path, it drifted when rows were inserted mid-scan
```

Subject covers it, no body:

```
fix(auth): reject tokens with a future iat
```

Breaking:

```
refactor(store)!: replace get(key, default) with get(key)

- `get` now raises `KeyError` on a missing key; call `get_or` for a default
- migrated the 14 internal call sites
```

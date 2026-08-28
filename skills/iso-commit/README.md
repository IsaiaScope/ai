# iso-commit

Commit messages that read like a person wrote them.

`type(scope): message` on the subject, a dot list of what the work does underneath — and nothing else. No `Co-Authored-By`, no `🤖 Generated with`, no *comprehensive robust seamless* filler.

```
/iso-commit
```

## What it does

Stages everything, writes the message, commits. One command.

```
feat(api): add cursor pagination to /events

- added `cursor` and `limit` query params, defaulting to 50
- switched the list query to keyset ordering on (created_at, id)
- dropped the offset path, it drifted when rows were inserted mid-scan
```

Trivial change, no body needed:

```
fix(auth): reject tokens with a future iat
```

## Flags

| flag | effect |
|---|---|
| *(none)* | `git add -A` — staged, unstaged, untracked — then one commit |
| `--staged` | commit the index only, stage nothing |
| `--split` | several commits grouped by concern instead of one |

## Rules it follows

**Claude never commits on its own.** Typing `/iso-commit` is the only thing that produces a commit — not the end of `iso-write`, not "that looks done". The rest of the `iso-*` chain leaves the tree uncommitted on purpose and this doesn't change it.

**The subject is machine-read.** `iso-init-repo` puts commitlint on a `commit-msg` hook and a version bump on `post-commit`. That one line is a gate *and* a semver input: `!` → major, `feat:` → minor, else patch. So when a commit holds both a feature and a fix, it's `feat:` — under-bumping ships a feature in a version that doesn't record it.

**Credential guard.** `git add -A` sweeps untracked files, so it checks the file list *before* staging and aborts on `.env`, `*.pem`, `*.key`, ssh keys, `.npmrc`, `credentials.json` and friends. `.env.example` and other `.example`/`.sample`/`.template` files pass. Nothing gets staged when it trips.

**Body only when it earns its place.** Subject says it all → no body. More than one change, or a reason the diff can't show → dots.

**Every dot names something real** — a file, function, endpoint, flag, behavior. A dot that can't name one is padding and gets cut. This is the rule that actually kills slop; a banned-word list just teaches synonyms.

## Layout

```
iso-commit/
├── SKILL.md                  the message contract — what a model reads
├── README.md
└── scripts/
    ├── commit.sh             preflight · guard · stage · commit
    └── commit.test.sh        13 assertions, no framework
```

Run the checks:

```bash
bash skills/iso-commit/scripts/commit.test.sh
```

Deterministic steps live in the script so they behave identically every run; only the judgment — picking the type, writing the dots — lives in `SKILL.md`.

## Replaces

`caveman-commit`. Same ban on AI attribution, opposite body rule — caveman-commit compresses and usually drops the body, which is the wrong trade for the one artifact you read months later with no context.

## Related

- [`iso-write`](../iso-write/) — builds a plan, leaves everything uncommitted for this to close out
- [`iso-review`](../iso-review/) — improves, simplifies and reviews the uncommitted tree before you commit it
- [`iso-init-repo`](../iso-init-repo/) — installs the commitlint + version-bump hooks this format feeds

---
name: iso-issue-tracking
description: Record agent work on the work tracker every iso-* skill files against. The iso-* chain drives the ticket at its own boundaries — /iso-plan opens it, /iso-write moves it, /iso-push closes it with a retro — and you open or bind rows by hand for work with no plan behind it. Use when a request changes something durable inside a git repo. Inert outside a repo.
---

# iso-issue-tracking

## Adapters

The board is reached through fourteen `tk_*` verbs defined in
`scripts/adapters/<kind>.sh`, selected by `tracker.kind` in the Iso config.
`tracking.sh` owns the parts that must not vary — the ledger, redaction, plan
resolution, the transition gates — and never names a vendor.

| kind | adapter |
|---|---|
| `multica` | `adapters/multica.sh` — the shipping adapter |
| `none` | `adapters/none.sh` — every verb a successful no-op |

An unknown kind falls back to `none` and logs it, because tracking may never
fail the run that invoked it.

A new adapter defines all fourteen verbs and returns **normalised** output —
list verbs emit `<id>\t<name>` lines, not the vendor's JSON — so nothing
downstream has to imitate another board's field names.
`scripts/adapters/contract.test.sh` is the check.

Redaction stays in `tracking.sh`, deliberately: an adapter is the file most
likely to be written quickly against an unfamiliar API, and it is the last
place a `[redacted]` should depend on.

`scripts/tracking.sh` is called by the Claude Code session hooks for `reconcile`
and `end`. The `iso-*` skills call it at their own boundaries, and you call it
for the work that never went through a plan.

The board answers "what is being worked on and where is it", not "what happened
step by step". Every status change corresponds to a point the chain already
reaches and already announces; nothing infers intent from a prompt.

| transition | fact that drives it | who writes it |
|---|---|---|
| → `todo` | `/iso-plan` finished writing the plan | `iso-plan` |
| → `in_progress` | `/iso-write` resolved its workspace | `iso-write` |
| → `blocked` | `/iso-write` halted and wrote its blocked marker | `iso-write` |
| → `in_review` | `/iso-write` stamped the plan `implemented (uncommitted)` | `iso-write` |
| → `done` + retro | `/iso-push` landed the PR | `iso-push` |
| → `done`, no retro | the merge happened outside a session | reconciler |
| → `cancelled` | branch gone, `gh` reachable, `opened_by=claude` | reconciler |

**`in_review` does not depend on a PR.** It means "Iso should look at this" — a
claim about attention, not about GitHub. A PR can be open on work still in
progress, and work can be ready to read with no PR at all.

The four plan-driven writes, each resolving the ticket from a plan path **or** a
branch — whichever the calling skill happens to hold. One plan resolves to
exactly one ticket, so each is a single status write:

| command | effect |
|---|---|
| `progress <plan-or-branch>` | ticket → `in_progress` |
| `blocked <plan-or-branch>` | ticket → `blocked` |
| `review <plan-or-branch>` | ticket → `in_review` |
| `retro <plan-or-branch>` | stdin becomes one comment, then ticket → `done` |

**A ticket can outlive its plan.** When the first attempt was wrong, or came back
from review needing a different approach, the second plan is the same piece of
work and belongs on the same ticket. A second ticket would split one story across
two rows and leave the first sitting in `in_review` for good.

| command | effect |
|---|---|
| `ticket-for-branch` | prints `<KEY>\t<status>` for this branch's live ticket, or nothing |
| `addplan <session_id> --plan <path> [--key KEY] [--title T]` | the previous plan shipped: marks it `done`, adds this one, ticket → `in_progress` |
| `replan <session_id> --plan <path> [--key KEY] [--title T]` | the previous plan was wrong: marks it `superseded`, adds this one, ticket → `todo` |
| `comment <KEY>` | stdin becomes one comment. No status write, no ledger change |

`comment` is `retro` with the ending removed — the same redaction and the same
4000-character cap, without the close. `/iso-review` uses it to leave its run
summary somewhere that outlives the terminal, on work that is not finished.
Takes a key, not a plan, because the caller already knows which ticket it is
reporting on.

`ticket-for-branch` is the question `/iso-plan` asks before writing anything:
empty means open a fresh ticket, a key means replan against that one. It hides
`done` and `cancelled` tickets, because a new plan against shipped work is new
work — and `replan` refuses them for the same reason.

`todo`, not `in_progress`: a new plan means nothing has been implemented yet,
and `/iso-write` still owns the promotion. The description is **replaced** so
the ticket describes the plan being worked now; the switch itself goes in a
comment, which is where this ticket's history already lives.

And the ones you still call by hand, for work with no plan behind it:

| situation | command |
|---|---|
| an existing open issue already covers the request | `tracking.sh bind <session_id> <KEY>` |
| trackable work | `open <session_id> "<title>" --scope <scope>` — always safe to call: on a feature branch that already has a live ticket this adds the plan to it and returns that ticket's key instead of creating a second one |
| Iso says the work is finished and no merge will show it | `tracking.sh done <session_id>` |

## Writing the row

The board is a kanban Iso scans, not a log he reads. Someone glancing at a ticket
a week from now should understand what is going on without opening it.

```bash
printf '%s\n' \
  'A single 5xx aborts a whole upload batch and those records are lost. The' \
  'retry wrapper treats the batch as one unit, so a partial failure discards' \
  'the rows that did land. Nothing surfaces it: the job exits 0 and the count' \
  'is only wrong the next morning.' \
  | "$(iso_sibling iso-issue-tracking scripts/tracking.sh)" \
      open "$SESSION_ID" "🐛 Uploader drops a whole batch when S3 returns 5xx" \
      --scope be,data --priority high
```

**Title: a plain sentence a human understands.** Emoji, then what is actually
happening — not a ticket stub. "🐛 Uploader drops a whole batch when S3 returns
5xx", not "🐛 Fix uploader". Add the emoji only when the topic is unambiguous;
a wrong icon is worse than none, because the board is skimmed by shape.

| | | | |
|---|---|---|---|
| 🐛 bug fix | ✨ feature | ♻️ refactor | 📝 plan, spec, docs |
| 🚀 deploy, release | ⚙️ config, infra | 🔒 security | 🧪 tests |

**One branch, one ticket.** Every plan that lands on a branch is a section in
that branch's ticket, marked `done`, `current` or `superseded`. Nothing is ever
deleted to make room, and only the `current` section carries a runnable
`/iso-write` line. `addplan` and `replan` differ in exactly one thing: what the
outgoing plan becomes. Both take an optional `--title`, which broadens the
ticket's title as the topics on a branch diverge; omit it and the title is left
alone, so a plan continuing the same topic does not churn it.

`open` enforces this itself — it looks up the current branch and redirects to
`addplan` rather than creating a second row. There is no `--force-new`. Base
branches are exempt, because `dev` accumulates unrelated tickets by design.

**No sub-issues.** There are no sub-issues and no `--parent` — the CLI
supports both, so this is a choice, not a limit. Two rows on one branch close in
the same instant whatever line is drawn between them. A plan that
touches three scopes is still one ticket carrying three scope labels — splitting
it produced rows nobody moved independently and a status that had to be written
four times to mean one thing.

**Description: context first, then whatever explains it.** Two parts, in this
order.

**Part one — three or four sentences of prose.** Not one. One line leaves the
reader with a title and a link, which is what the ticket exists to spare them.
Four sentences is enough to say what changes, what it replaces, why the old
thing was wrong, and what it means going forward — and short enough that
someone skimming the board actually reads it.

**Part two — whatever makes it concrete.** Append it below the prose. There is
no fixed set of blocks; reach for the shape the change actually has:

| Shape | Good for |
|---|---|
| 3-column table: thing / before / after | a swap of behaviour |
| **Why** — dot list | reasons the title does not carry |
| **Watch out** — dot list | a migration, a secret, a manual step, a breaking change |
| fenced code block | the one command to run, or the failing line |
| `>` blockquote | a quoted error or log line |

Skip anything that has nothing to say. A one-file config change may be four
sentences and nothing else; a subsystem rewrite earns the table.

Everything is in **English**, including the labels. Two things you never write
by hand: a scope line (scopes are a structured field already, and a copy of a
field goes stale) and the plan path — `open` appends it for you, see below.

```markdown
The wiki stops relying on a nightly crawl and gets an explicit `wiki ingest`
command, plus a scheduled push at 03:07. The crawl was implicit and silent, so
any page created after midnight was invisible until the following night. There
was no way to force a reindex short of waiting. From here, ingest is something
you run and can see fail.

| Thing | Before | After |
|---|---|---|
| ingest | implicit nightly crawl | `wiki ingest <path>` |
| push | by hand, when someone remembered | cron 03:07 |

**Why**
- the crawl skipped every page created after midnight
- no way to force a reindex without waiting for the night

**Watch out**
- `WIKI_INGEST_TOKEN` must be in secrets **before** the deploy, or the cron fails silently
```

**The plan path is appended for you.** When `open` is given `--plan`, it adds
two blocks below the body, after a `---` rule:

````markdown
**Resume this session:**

```bash
cd /path/to/repo && claude --resume <session-id> --dangerously-skip-permissions
```

**Then implement the plan:**

```
/iso-write docs/superpowers/plans/2026-02-02-feat-wiki.md
```
````

Two blocks, not one line: the first is a shell command, the second is a slash
command you paste once you are inside the session. Each copies on its own — the
resume is worth running by itself just to read the session back.

Do not write a `**Plan:**` line yourself; it would be a second, staler copy of a
path the script already emits. Without `--plan` only the resume block appears.
With `--agent codex` neither does, since the command would resume a session it
cannot reach.

**A big change repeats the pattern per topic.** When the work spans genuinely
different parts of the app, do not flatten it into one blurred paragraph and do
not split it into more tickets. Give each topic a `##` heading, then the same
shape underneath: three or four sentences, then whatever makes it concrete.

```markdown
## Ingest

The wiki stops relying on a nightly crawl... (3-4 sentences)

| Thing | Before | After |
...

## Scheduling

The push moves off a human remembering... (3-4 sentences)

**Watch out**
- ...
```

Two or three topics is the useful range. Past that the headings stop being
topics and start being a table of contents, which is what the plan file is for.
This is what sub-issues used to do, minus four rows nobody moved.

**Length: roughly 40 lines per topic.** The limit is not brevity for its own
sake — it is that past that you are re-typing the plan file, which `--plan`
already links. Prose gets the room it needs; step-by-step detail does not. A
ticket is a briefing plus one retro comment at the merge; that is the whole
record.

Pipe the whole thing on stdin: multi-line safe, no quoting. Same redaction as
comments, so a pasted secret never reaches the board.

**Descriptions and comments render as Markdown.** Use it to make the important
parts findable at a glance:

- `` `backticks` `` for file paths, flags, commands, symbols, error strings —
  anything the reader might search for or copy
- **bold** for the one thing that matters most in a paragraph, used sparingly;
  bolding three things bolds nothing
- fenced code blocks for a command to run, a stack line, or a two-line snippet
  that is faster to read as code than as prose
- `>` blockquote for a quoted error or log line
- nested bullets only one level deep

Do not paste diffs, full stack traces, or whole functions. The ticket is a
pointer to the work, not a copy of it.

**Never restate what already has its own field.** The ticket carries the branch,
the PR, the scope, the priority and the assignee as structured fields — writing
them into the description too just creates a second copy that goes stale:

| already a field | do not write in the description |
|---|---|
| `Branch` property, set at bind | "on branch feat/x" |
| the linked pull requests (`multica issue pull-requests <key>`) | the PR link or number |
| labels | "this is backend work" |
| priority | "this is urgent" |
| assignee | "assigned to Iso" |
| status column | "in progress", "done" |

The description is for what the fields cannot say: what is going on and why.

**The resume block is automatic, when Claude is doing the work.** `open` appends
a fenced `cd <repo_root> && claude --resume <session_id>
--dangerously-skip-permissions` to the description, so the work can be picked
back up from the ticket anywhere — the `cd` is what makes it runnable from a
reader's shell, not just from inside the repo. Do not write it yourself.

Pass **`--agent codex`** when the implementation runs in Codex instead — as
`/iso-write` does — and the block is omitted
entirely. `claude --resume` cannot reach a Codex session, and a resume line that
resumes nothing is worse than none: it reads as an offer. Default is `claude`,
so omitting the flag keeps the block.

**Small emoji in the body, to reinforce a point** — not decoration. One or two
per ticket, always attached to a specific claim, never at the start of every
bullet:

| | | | |
|---|---|---|---|
| ⚠️ risk, gotcha | ✅ verified, works | ❌ broken, wrong | 🔁 retry, loop |
| 🔒 security-sensitive | 🐌 slow, perf cost | 🚧 in progress, partial | 📌 the key fact |

If a ticket ends up with an emoji on every line, remove them all — the signal only
works while it is rare.

**One trap:** redaction removes any bare hex run of 32 characters or more, which
includes a full 40-character commit SHA. Use the short form — `401693a` survives,
the full SHA becomes `[redacted]`. This is deliberate; the pattern is there to
catch tokens and HMACs, and it is not worth weakening for cosmetics.

**Scope: which part of the system.** The repo is already the project, so a repo
label would only restate it. Emoji says what *kind* of change; scope says what
*area*. **A row may carry several** — repeat the flag or use a comma list:
`--scope fe,api` or `--scope be --scope db`.

| scope | covers |
|---|---|
| `fe` | Next.js, React Native, UI, styling |
| `be` | server code, services, business logic |
| `db` | Postgres, schema, migrations, indexes |
| `data` | ingestion, RAG, knowledge graph, backups |
| `ai` | agents, prompts, models, personas, blocks |
| `api` | HTTP surface, contracts, webhooks |
| `auth` | login, sessions, tokens, permissions |
| `ci` | pipelines, branch gates, releases |
| `gh` | GitHub itself — repo settings, Actions, PR flow |
| `vps` | servers, containers, Docker, Dokploy, Hetzner |
| `security` | secrets, hardening, exposure |
| `doc` | plans, specs, ADRs, README |
| `test` | test suites, fixtures, coverage |
| `perf` | latency, throughput, cost |

The list is closed — an unrecognised scope is dropped with a log line rather
than minting a permanent label. Omit scope entirely when the area is genuinely
unclear; a wrong label is worse than none.

**Priority: `--priority`, and it defaults to `medium`.** Never `none` — a board
where everything is unprioritised sorts by nothing. Judge it from consequence,
not from how interesting the work is.

| priority | when |
|---|---|
| `urgent` | broken in production, data loss, or Iso is blocked right now |
| `high` | a real defect, or work that blocks the next thing he wants to do |
| `medium` | normal work — the default, and most rows belong here |
| `low` | cleanup, cosmetics, nice-to-have, no one is waiting |

If everything is `high`, nothing is. Reach for it when there is a concrete
consequence to leaving the row alone.

**Assignee is automatic** — every row is assigned to the authenticated user, so
the board never shows unowned work.

## The branch on the ticket

`open` records the branch you were standing on when the ticket was written —
usually a base branch, because planning happens before the work has a branch of
its own. Two verbs keep it honest afterwards.

```bash
tracking.sh rebranch <identifier> <new-branch>   # point the ticket at where the work moved
tracking.sh branch-of <identifier>               # read it back; prints nothing on a miss
```

`<identifier>` is **either a plan path or the branch the work is moving off** —
`ticket_for` matches both, so a caller passes whichever it already holds.
`/iso-write` has the plan path. `/iso-push` and `/iso-commit` have only a branch.

`rebranch` rewrites two things: the ledger row's `branch`, and the ticket's
`Branch` property. **The ledger is the one that matters.** It is the key
`ticket-for-branch` resolves by, so a stale row makes the ticket unfindable from
the branch the work is actually on — which is what makes `reconcile` miss the
pull request entirely, since it matches PRs on `headRefName` against that same
field, and so never sees the branch as merged.

It is idempotent, and a miss is normal: no ticket for this work still has to
exit 0, like every other write here. It posts **no comment** — a branch move is
bookkeeping, and one comment per move buries the retro that matters.

Who calls it:

| skill | when |
|---|---|
| `/iso-write` | after it resolves a workspace, in every mode |
| `/iso-commit` | after its branch gate lands |
| `/iso-push` | inside `rescue_to_branch`, once the commits have moved |

## Breaking up larger work

**Open a second ticket, never a child.** There is no hierarchy: multi-part work
becomes one ticket per unit Iso would want to see move on its own, each with its
own scope and priority.

```bash
… open "$SESSION_ID" "⚙️ Provision VPS-1 and its firewall" --scope vps --priority high
… open "$SESSION_ID" "🔒 Move secrets into Dokploy env"    --scope security
… open "$SESSION_ID" "🚀 First deploy and smoke test"      --scope ci
```

A parent whose status was only ever the sum of its children was a row that had
to be moved four times to say one thing, and the ordering it encoded lived in
the plan file anyway. When sequence matters, say so in the ticket body under
**Watch out**.

Split when the parts have different scopes, land in different branches, or
would each be worth reading about separately. Do not split a one-afternoon task
into four tickets; a board of trivia is as unreadable as a board of vagueness.

**Match before creating.** Search the tracker for the words in the request
first — search covers titles, descriptions and comment bodies, so a conclusion
that only ever landed in a comment is still findable.

> **Known gap.** The adapter contract has no `tk_issue_search`, so this one step
> reaches past the adapter to the vendor CLI — `multica issue search <words>` on
> the shipping adapter. It is the only place in this skill that names a vendor,
> and it will keep leaking until search joins the contract's verbs.
 Never search a bare
number or an identifier like `WOR-412`: number-shaped queries rank number
matches first and the prefix is not validated, so an identifier from another
tracker surfaces an unrelated local issue at the top.

**The bar.** Open a row when the request leaves something durable — code
changed, a plan or spec written, a branch created, a deploy, a config change, a
decision recorded. Do not open one for questions, reading or explaining code,
status checks, or exploration that changed nothing. **Ambiguous counts as not
trackable**: say so in one line and let Iso answer "track it".

Announce every bind as `→ WOR-n`, so the board never grows silently.

**Never** infer `blocked` — the only automatic writer is `/iso-write`, at its
own halt, where the blockage is a fact it just recorded in a marker file. Every
other kind of blockage lives outside anything the machinery can read. **Never** create a Multica agent, start the daemon, or add
an autopilot or webhook trigger. This is outbound only: nothing on the board
may cause execution here.

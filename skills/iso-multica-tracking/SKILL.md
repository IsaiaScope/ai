---
name: iso-multica-tracking
description: Record Claude Code work on the Multica board. Bind the session to an issue when the work is trackable and let the reconciler close the row on merge. Use when a request changes something durable inside a git repo. Inert outside a repo.
---

# iso-multica-tracking

`scripts/multica-session.sh` is called by the Claude Code hooks for `prompt`,
`reconcile` and `end`. You call it for the three decisions a hook cannot make.

| situation | command |
|---|---|
| an existing open issue already covers the request | `multica-session.sh bind <session_id> <KEY>` |
| the request is one piece of a larger open issue | `open <session_id> "<title>" --parent <KEY>` |
| trackable work, no matching issue | `open <session_id> "<title>" --scope <scope>` |
| Iso says the work is finished and no merge will show it | `multica-session.sh done <session_id>` |

## Writing the row

The board is a kanban Iso scans, not a log he reads. Someone glancing at a card
a week from now should understand what is going on without opening it.

```bash
printf '%s' 'The uploader sends records to S3 in batches. A single 5xx aborts the
whole batch and those records are lost - **nothing retries**, and nothing is
written anywhere we could replay from. It shows up as silent gaps in a day of
data, which is why it went unnoticed for a week.

**Working on:**
- capped exponential backoff in `upload_batch()`, 5 attempts
- dead-letter the batch to `state/dead/` after the last failure
- touches `scripts/upload.sh` and the uploader block' \
  | ~/.claude/skills/iso-multica-tracking/scripts/multica-session.sh \
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

**Description: context first, then the list.** Two parts, always in this order.

1. **A short paragraph of context** — two or three sentences, plain language,
   explaining what is going on and why it matters. Assume the reader has not
   seen the code and does not remember the conversation. Say what the thing
   does, what is wrong or wanted, and what the visible consequence is. This is
   the part that makes a card understandable a month later.
2. **`Working on:` followed by a dot list** — three to five bullets, one line
   each, of what is actually being changed. Concrete: the fix, the approach, the
   files or areas touched.

Keep it synthetic — the paragraph is context, not an essay, and the bullets are
work items, not a diff. Do not restate the title in either part. Pipe the whole
thing on stdin: multi-line safe, no quoting. Same redaction as comments, so a
pasted secret never reaches the board.

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

Do not paste diffs, full stack traces, or whole functions. The card is a
pointer to the work, not a copy of it.

**Never restate what already has its own field.** The card carries the branch,
the PR, the scope, the priority and the assignee as structured fields — writing
them into the description too just creates a second copy that goes stale:

| already a field | do not write in the description |
|---|---|
| `Branch` property, set at bind | "on branch feat/x" |
| `PR` property, set by the reconciler | the PR link or number |
| labels | "this is backend work" |
| priority | "this is urgent" |
| assignee | "assigned to Iso" |
| status column | "in progress", "done" |

The description is for what the fields cannot say: what is going on and why.

**The resume block is automatic, when Claude is doing the work.** `open` appends
a fenced `claude --resume <session_id> --dangerously-skip-permissions` to the
description, so the work can be picked back up from the card. Do not write it
yourself.

Pass **`--agent codex`** when the implementation runs in Codex instead — as
`/iso-todo --impl-agent codex` and `/iso-write` do — and the block is omitted
entirely. `claude --resume` cannot reach a Codex session, and a resume line that
resumes nothing is worse than none: it reads as an offer. Default is `claude`,
so omitting the flag keeps the block.

**Small emoji in the body, to reinforce a point** — not decoration. One or two
per card, always attached to a specific claim, never at the start of every
bullet:

| | | | |
|---|---|---|---|
| ⚠️ risk, gotcha | ✅ verified, works | ❌ broken, wrong | 🔁 retry, loop |
| 🔒 security-sensitive | 🐌 slow, perf cost | 🚧 in progress, partial | 📌 the key fact |

If a card ends up with an emoji on every line, remove them all — the signal only
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

## Breaking up larger work

One card per unit of work Iso would want to see move on its own. When a request
is genuinely multi-day or multi-part, open a **parent** row and hang children
off it rather than writing one vague card that sits `in_progress` for a week.

```bash
PARENT=$(… open "$SESSION_ID" "✨ Self-hosted Multica on VPS-1" --scope vps --priority high)
… open "$SESSION_ID" "⚙️ Provision the box and firewall"  --parent "$PARENT" --stage 1 --scope vps
… open "$SESSION_ID" "🔒 Move secrets into Dokploy env"   --parent "$PARENT" --stage 1 --scope security
… open "$SESSION_ID" "🚀 First deploy and smoke test"     --parent "$PARENT" --stage 2 --scope ci
```

`--stage N` groups children into ordered barriers: everything in stage 1 is
meant to finish before stage 2 is meaningful. Use it only when the order really
matters — omit it and the children are simply unordered. `--stage` without
`--parent` is dropped with a log line, since a stage is meaningless on a
top-level row.

Split when the parts have different scopes, land in different branches, or
would each be worth reading about separately. Do not split a one-afternoon task
into four cards; a board of trivia is as unreadable as a board of vagueness.

**Match before creating.** Run `multica issue search <words from the request>`
first — it searches titles, descriptions and comment bodies, so a conclusion
that only ever landed in a comment is still findable. Never search a bare
number or an identifier like `WOR-412`: number-shaped queries rank number
matches first and the prefix is not validated, so an identifier from another
tracker surfaces an unrelated local issue at the top.

**The bar.** Open a row when the request leaves something durable — code
changed, a plan or spec written, a branch created, a deploy, a config change, a
decision recorded. Do not open one for questions, reading or explaining code,
status checks, or exploration that changed nothing. **Ambiguous counts as not
trackable**: say so in one line and let Iso answer "track it".

Announce every bind as `→ WOR-n`, so the board never grows silently.

**Never** set `blocked` automatically — blockage lives outside anything the
machinery can read. **Never** create a Multica agent, start the daemon, or add
an autopilot or webhook trigger. This is outbound only: nothing on the board
may cause execution here.

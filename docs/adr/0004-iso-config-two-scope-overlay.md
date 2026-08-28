# Iso config is two scopes merged per key, with a sparse repo overlay

The eleven `iso-*` skills hardcode the author. Branch vocabulary (`dev`, `test`,
`prod`) appears across twenty files; `multica` is named twenty-four times as
though it were the only issue tracker; `herdr` fourteen times as though it were
the only terminal; the ledger sits at a literal `$HOME/.claude/multica`. Three
skills reach a sibling through `$HOME/.claude/skills/iso-tracking/...`,
a path that resolves under one of the four install topologies the skills
actually ship through and silently fails under the rest.

Configuration is now read from two scopes and merged **per key**. Global
(`~/.config/iso/iso.json`) describes the person; the repo scope describes one
repository. The repo scope is an **overlay**: only the keys that differ, valid
at any size, and it may carry `branches` and `paths` only.

An unknown or misspelled key in the overlay is a hard error naming the key.

**Amended by 0005.** The overlay now also carries `test`, the command the refine
phase gate runs. It is admitted on the same test as the original two — it
describes the repository, not the person, and no clone of it can redirect where
work is filed. The list below records what was chosen at the time; the current
allowlist lives in `ISO_OVERLAY_KEYS` in `iso-config/scripts/lib/config.sh`.

## Considered Options

- **Defaults everywhere, config purely additive** (rejected) — a fresh
  marketplace install would work with no config at all, which is the better
  first run. But the values that most want configuring are the ones where a
  wrong guess is silent and expensive: writing to the wrong board, pushing to
  the wrong org. Defaulting those means the failure surfaces as work filed
  somewhere nobody looks.

- **Global scope only** (rejected) — a single file cannot honestly hold both
  "I prefer herdr" and "this repository integrates on `dev`". One of the two
  ends up lying, and the repository fact is the one that changes per clone.

- **Repo scope may override anything** (rejected) — cloning a repository would
  then be able to redirect the tracker or the identity, so checking out
  somebody's code silently changes where your work gets filed. That is the
  `$HOME/.claude` hardcode again with a longer reach.

- **Two scopes, repo limited to `branches` and `paths`** (chosen) — the split
  follows what the values actually describe. Cost: two files to look at instead
  of one, and a merge step every reader pays.

- **Unknown overlay key ignored, global wins** (rejected) — `{"branches":
  {"defualt":"prod"}}` would then behave exactly like a correct file that
  happened to change nothing. This repository already shipped one bug of that
  shape: `git merge-base --is-ancestor` is vacuously true for a commitless
  branch, so rows closed having shipped nothing, and every casual test passed.
  A silent no-op on a typo is the same failure wearing different clothes.

## Consequences

### Prerequisites are classified, not merely checked

Absence is not one condition. `jq`, `gh` and `multica` install without asking;
`codex` and `claude` are auth-gated, so their steps get printed for a human;
`herdr` is a personal build under `~/.local/bin` with no package, so it stops
the skill. The code branches on the classification, never on the binary.

`jq` is the prerequisite this decision creates — the whole design reads JSON,
and no skill checks for it today. It is verified before anything reads config,
or the failure surfaces as `jq: command not found` from inside a skill.

### Readiness is stamped, not re-probed

The global config records that the sweep passed, with a timestamp and the
version of the prerequisite list it ran against. Skills trust the stamp. Adding
a prerequisite bumps the version, which invalidates every stamp in the field —
so the check re-triggers on skill update without anyone remembering to.

A bare boolean was rejected for going stale precisely on the upgrade that adds
a prerequisite.

### Sibling skills are addressed relative to the caller

`${BASH_SOURCE[0]}` resolves `../<sibling>` under all four topologies: the
development symlink into `~/.claude/skills/`, the marketplace clone at
`~/.claude/plugins/marketplaces/marketonfire`, the `~/.agents/skills/`
indirection, and the repository itself. `$HOME/.claude` resolves under one.

### `.iso/` becomes `docs/iso/`, and is tracked

Run artifacts move beside the config and are committed. This is deliberate and
was chosen with the costs visible: the tree measures 595 KB across 8 files, of
which a single spawn sidecar is 589 KB and everything else is under 8 KB; the
review subdirectory is deleted and rewritten at the start of every run; and
spawn sidecars record absolute paths under the author's home directory plus
Codex session identifiers — in a public marketplace repository.

(An earlier draft of this section said 13 MB. That was `du` reporting allocated
blocks on a volume with 1 MB clusters. Git stores bytes, so the real cost is
roughly one twentieth of what the decision was first weighed against.)

The one mitigation taken: sidecars write `~` rather than the expanded `$HOME`.
The information is preserved; the home path is not.

### The Codex install is already broken

`install.js` symlinks each skill into `~/.claude/skills/` and `~/.codex/skills/`.
The latter is empty, while `CLAUDE.md` documents both as working. This is not
caused by the decision above but is found by it, and it is what `doctor` exists
to catch: the claim and the filesystem disagreeing.

### The tracker sits behind an adapter, and the skill loses the vendor's name

`iso-tracking` names one board in the skill, the script
(`tracking.sh`), and every call site that reaches it. Thirteen CLI verbs
are the entire coupling:

    auth status                      project list --output json
    issue create --title --project --status [--assignee]
    issue get / issue status / issue comment add
    issue label add / issue property set
    label create / label list / property create / property list

`issue children`, `--parent` and `--stage` were in this list until sub-issues
were retired (see the deferred note below); the seam shrank rather than grew.

Thirteen verbs is small enough that the seam costs less than living without it,
so the skill becomes `iso-tracking`: `scripts/tracking.sh` keeps the
orchestration — the ledger, redaction, plan resolution, the transition gates —
and `scripts/adapters/<kind>.sh` holds the verbs. `tracker.kind` picks the file.

A `none` adapter answers every verb with success and does nothing, so a fresh
marketplace install is inert rather than erroring at a board it has never heard
of. `adapters/contract.test.sh` is what any future adapter is held to.

Rejected: a `tracker.kind` check that exits early. It makes the board optional
without making a second board possible, and the work to fix that later is the
same work, done against a file that has drifted further.

The redaction boundary stays in `tracking.sh`, deliberately. An adapter is the
part most likely to be written in a hurry against an unfamiliar API, and it is
the last place a `[redacted]` should depend on.

## Deferred

- **Sub-issues are gone, and with them two adapter verbs.** A plan opened one
  parent plus one child per scope; the children carried the parent's status,
  were never moved independently, and were titled by the bare scope (`be`,
  `doc`), which read as noise on the board. One plan is now one card, so
  `tk_issue_children` left the contract, `--parent`/`--stage`/`--sub` left
  `open`, and the `---8<---` block splitter left stdin entirely — a literal
  `---` in a card body is now just a horizontal rule. The card body absorbs
  what the children carried, as a structured briefing rather than a scope label.
  Reversing this means re-adding one verb and a fan-out loop; the ledger never
  held child rows, so nothing else knows they existed.
- **Agent kinds stay a closed set.** Per-kind data becomes configurable —
  transcript directory, permission flag, tab label, all currently hardcoded in
  `agentkind.sh`. The set itself does not open. `codex` and `claude` are
  branched on throughout `iso-spawn` (and, when this was written, `iso-review`
  and `iso-todo`, since replaced by `iso-refine`, now `iso-review`); admitting a
  third kind by configuration alone would require every one of those branches
  to have a tested fallback for an agent nobody has run.

- **Only two adapters ship.** `multica` and `none`. A GitHub Issues adapter is
  writable from `docs/agents/issue-tracker.md`, which already documents the `gh`
  calls, but writing it now would mean testing a board nobody files work on. The
  contract test is the deliverable that makes it cheap later, not the adapter.

- **No schema validation library.** The overlay's key list is fixed and small,
  so a hand-rolled check covers it. This follows ADR-0003, which reached the
  same conclusion for the same reason.

- **`push-via-iso-push` stays prose.** "Never fall back to raw `git push`" is a
  habit rule with no value to encode, so it belongs in `CLAUDE.md`. The
  `prod`-as-default-branch fact is data and moves into the repo overlay, where
  re-running `/iso-init-repo` can no longer silently reset it.

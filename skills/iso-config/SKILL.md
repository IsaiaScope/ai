---
name: iso-config
description: Read and check the Iso config that every iso-* skill uses — branch vocabulary, paths, tracker, terminal, identity. Two scopes merged per key: ~/.config/iso/iso.json describes you, docs/iso/config.json describes one repo. Use when invoked as /iso-config [init|show|doctor], when a skill reports a missing or wrong config value, or when setting up iso-* skills on a new machine.
---

# iso-config

Owns the Iso config and the library every other `iso-*` skill reads it through.

Invocation: `/iso-config [init | show | doctor]`. Default is `show`.

| Command | What it does |
|---|---|
| `init` | Writes `~/.config/iso/iso.json` seeded with the defaults. Refuses to overwrite. |
| `show` | Prints which scope files exist, then the merged document. |
| `doctor` | Validates the overlay, sweeps prerequisites, checks the skill dirs and the tracker hooks, records the readiness stamp. |

All three run `scripts/config.sh`. This file describes the surface; it holds no logic.

## Scopes

`~/.config/iso/iso.json` describes **you** — tracker, terminal, identity, agent
data. `docs/iso/config.json` in a repository describes **that repository**, and
may carry `branches`, `paths` and `test` only. Repo wins per key, not per file.

An overlay is meant to be tiny: only the values that differ from the global
ones, which for most repositories is a handful.

`test.command` is the odd one out, and belongs to the repository for a reason a
global value could not serve — it is the shell command that proves this
repository still works. `/iso-review` runs it between phases and undoes a phase
that turns it red. Unset (the default) means no gate: phases still run, and
nothing checks them.

A key the overlay is not allowed to carry is a hard error naming the key, never
a silent fall-through to global. A typo in a five-line file must not behave
like a correct file that changed nothing.

## Reading config from another skill

Resolve the library relative to your own script, never through `$HOME/.claude` —
that path is correct under one of the four install topologies and silently
wrong under the rest.

    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    . "$HERE/../../iso-config/scripts/lib/sibling.sh"
    . "$(iso_sibling iso-config scripts/lib/config.sh)"
    development=$(iso_config_get branches.development)

## Telling a user how to install something

No `iso-*` skill names a package manager. `config.sh` exports the one this
machine actually has, so a hint stays runnable off macOS — `brew install jq`
handed to a Debian reader is advice they cannot follow, and it read as correct
here for as long as only one machine ever ran these skills.

    iso_pkg_install     # -> "brew install" | "sudo apt-get install -y" | "sudo dnf install -y"
                        #    "sudo pacman -S" | "sudo apk add" | "install"

It names the manager, not the package: names do differ between them, but a
per-distro name table goes stale unnoticed, and a reader handed the right
manager reconciles a rename in seconds. `iso_prereq_hint` already composes the
two, so prefer that for anything in `ISO_PREREQS`.

Agent config directories follow the same rule: read them from
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}` and `${CODEX_HOME:-$HOME/.codex}`, never
bare. A bare path fails silently for a user who moved theirs — the file is
written, just not where the agent reads it. `scripts/portability.test.sh`
sweeps for all of this.

## Branch policy

No `iso-*` skill reads `branches.protected` directly. Source `branch.sh` beside
`config.sh` and use what it exports — before it existed, `iso-write` and
`iso-push` each carried their own copy of the membership test and of the
name-derivation logic, under different names.

    . "$(iso_sibling iso-config scripts/lib/branch.sh)"

    iso_is_protected        <branch>                          # "" (detached) counts as protected
    iso_branch_from_plan    <plan-path>                       # YYYY-MM-DD-<type>-<slug>.md -> <type>/<slug>
    iso_branch_from_subject <commit-subject>                  # "feat(scope): msg"          -> feat/scope-msg
    iso_branch_gate         <current> <ticket-branch> <proposed>

`iso_branch_gate` answers "where should this work live?" and prints exactly two
lines — `action=stay|checkout|create|ask` and `branch=<name>`, empty for `ask`:

| on | ticket branch | proposed | verdict |
|---|---|---|---|
| a feature branch | anything | — | `stay` on the current branch |
| protected | a feature branch that exists | anything | `checkout` it |
| protected | a feature branch that does not exist | anything | `create` it |
| protected | empty, or a protected branch | a name that exists | `checkout` it |
| protected | empty, or a protected branch | a name that does not exist | `create` it |
| protected | empty, or a protected branch | empty | `ask` |

A ticket still naming a protected branch is ignored rather than followed, which
is what stops a stale row sending someone back to `dev`.

**The gate is pure, and it is deliberately blind to the tracker.**
`iso-issue-tracking` sources `iso-config`, so a call back the other way would be
a dependency cycle. The caller resolves the ticket with whatever identifier it
already holds — a plan path for `/iso-write`, the current branch for
`/iso-commit` — and passes the answer in as `<ticket-branch>`.

**`ask` is the only verdict that stops for a human,** and the prompt is rendered
by the calling `SKILL.md`. A script cannot ask a question, so the gate returns a
verdict and never blocks.

## Reaching the tracker

No `iso-*` skill resolves `tracking.sh` for itself. Source `track.sh` beside
`config.sh`. Before it existed, seven call sites hand-rolled the same resolve,
test, run, swallow sequence, and had drifted apart on all three of the details
that matter.

    . "$(iso_sibling iso-config scripts/lib/track.sh)"

    iso_track <verb> [args...]   # the verb's stdout; ALWAYS exits 0
    iso_track_path               # the runnable tracker, or nothing

`iso_track` can never fail a run. No tracker installed, no git repo, or a verb
that errors all come back as exit 0 and empty stdout — a caller that needs to
know it got nothing reads the stdout, never the status. It does not silence
stderr; a caller that wants silence redirects at the call site, which is the
only place the choice differs between callers.

`iso_track_path` exists because "no tracker here" and "a tracker that knows
nothing about this branch" are different answers when the caller reports to a
human: the first deserves silence, the second a warning. `iso-push` uses it to
decide whether an unlinked PR is worth mentioning.

`ISO_TRACKING_SH` overrides resolution. That is the seam every self-check uses,
and it now works from every skill instead of two.

It lives in `iso-config` rather than in `iso-issue-tracking` on purpose: a
caller must be able to source it *without* knowing whether the tracker is
installed, and `iso-config` is the one skill that is always present.


## Prerequisites

Classified by what can be done when one is absent, in `scripts/prereq.sh`:
`auto` installs unattended, `manual` prints steps for a human, `hardcut` stops
the skill. Bump `ISO_PREREQ_VERSION` when the list changes — it invalidates
every readiness stamp, so the sweep re-runs without anyone remembering to.

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
may carry `branches` and `paths` only. Repo wins per key, not per file.

An overlay is meant to be tiny. This repository's is two lines, because two
values differ from the global ones.

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

## Prerequisites

Classified by what can be done when one is absent, in `scripts/prereq.sh`:
`auto` installs unattended, `manual` prints steps for a human, `hardcut` stops
the skill. Bump `ISO_PREREQ_VERSION` when the list changes — it invalidates
every readiness stamp, so the sweep re-runs without anyone remembering to.

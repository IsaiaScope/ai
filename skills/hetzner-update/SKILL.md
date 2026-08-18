---
name: hetzner-update
description: Align the version of a self-hosted open-source app between your Mac and a Hetzner VPS, upgrading whichever side is behind. Reads the software registry at ~/.config/hetzner/hetzner.json, compares both halves, classifies every release in between as safe or breaking, and stops for approval before crossing a breaking change. Takes a database backup before touching the server and verifies from the server's own logs afterwards. Use when invoked as /hetzner-update [app], or when asked to "update multica", "align versions with the VPS", "upgrade the self-hosted app", "is the server behind", or to check whether a self-hosted service and its local client have drifted.
---

# hetzner-update

Keep a self-hosted app and its local half on the same version, and refuse to cross a
breaking change without asking.

**Invocation:** `/hetzner-update [app] [--to <version>] [--check]`
`app` is a key under `software` in the registry. Omit it to do every entry.
`--check` reports drift and stops, changing nothing.

Sibling skills: `/hetzner-ssh` (connect) · `/hetzner-create` · `/hetzner-delete`.
Server connection details come from the fleet roster those skills own; this skill only
names a server, never redefines one.

> **This changes a running production service.** Step 5 always confirms before applying,
> and Step 4 always takes a backup first. Never skip either, and never infer approval
> from the invocation.

---

## The model

Two halves that must agree, and a third thing that pretends to be one of them.

| | |
|---|---|
| **local** | the client on your Mac. Often a desktop app that self-updates and cannot be pinned |
| **remote** | the service on the VPS. Pinned to a tag, and the half you can actually set |
| **companions** | other binaries of the same name that speak to nothing. They may lag harmlessly, but they answer `--version` first and will lie to you about whether the halves agree |

Companions exist because a Homebrew CLI and a bundled daemon can share a name and a
`$PATH`. Read versions with the exact commands in the registry, never a bare binary name.

---

## Step 0 — Load the registry

```bash
cat ~/.config/hetzner/hetzner.json
```

| Condition | Action |
|-----------|--------|
| File missing | First run on this machine. Create it from the schema in [README.md](README.md). Do not invent entries for apps the user has not mentioned |
| Invalid JSON | Report the parse error and the offending line. Do not rewrite the file. Stop |
| Requested `app` not in `software` | Print the available keys and stop. **Never guess a neighbouring name** |

Each entry names a `server` key. That key must exist in `fleet.servers` of
`~/.config/hetzner/hetzner.json`; if it does not, stop and say so rather than guessing an
ssh alias.

---

## Step 1 — Read both versions

```bash
.claude/skills/hetzner-update/scripts/read-state.py <app>
```

Read-only. It resolves `{alias}` from the fleet roster, runs every `version_cmd`, compares
by semver, and reports `drift` plus `plan_from`. Do not hand-substitute the alias or eyeball
the comparison — `0.4.9` looks larger than `0.4.19` to a string compare, and the resulting
plan is built from the wrong starting point while looking entirely reasonable.

Add `--print-cmds` to see the resolved commands without running any of them.

Report every half as a table before doing anything else.

| `drift` | Meaning |
|---|---|
| `aligned` | halves agree. If `--check`, stop. Otherwise continue: both may still be behind upstream |
| `local ahead` | server is behind — the normal case, since desktop apps self-update |
| `remote ahead` | local is behind. If `self_updating`, the output carries `blocked` — relay it and **stop**. Never downgrade the server to meet a stale client |
| `unknown` | a `version_cmd` failed or printed something unparseable. Fix the registry entry, do not guess the version |

A `version_cmd` that prints two lines is rejected rather than parsed. That is deliberate:
`multica --version` prints a version line *and* a Go runtime line, and a lenient parser
silently takes the wrong field.

`companions_lagging` is **not** drift. Say so explicitly so it does not read as a problem.

---

## Step 2 — Plan the move

```bash
.claude/skills/hetzner-update/scripts/plan-upgrade.py \
  --repo <repo> --current <plan_from>
```

Both values come straight from Step 1's output. `plan_from` is already the half that is
behind, so the plan closes the real gap rather than the one you happened to look at first.

Prints JSON. `status` decides Step 3:

| `status` | Meaning | Then |
|---|---|---|
| `current` | nothing newer exists | align the halves to each other and stop |
| `latest` | every release ahead is safe | target the newest |
| `partial` | a breaking release sits between here and newest | target is the last safe one. **Ask** before going further |
| `blocked` | the very next release is breaking | nothing safe to take. **Ask** |

The script classifies each hop two ways, and either one is enough to flag it:

- **version boundary** — below 1.0.0 the minor is the compatibility line (`0.4 -> 0.5`), at or above it the major
- **release notes** — `BREAKING CHANGE`, a conventional-commit `!:` marker, "action required", a manual migration

It deliberately ignores a bare mention of "migration". An app that applies schema
migrations automatically on boot names them in nearly every release, so flagging that
word flags everything and the check stops carrying information.

`--allow-breaking` targets the newest release regardless. Only pass it after the user
has said yes to that specific version in Step 3.

Rate limits: unauthenticated GitHub allows 60 requests/hour. The script uses
`GITHUB_TOKEN`, `GH_TOKEN`, or `gh auth token` when present.

---

## Step 3 — Confirm

Always. Show the user, in this order:

1. current local, current remote, proposed target
2. how many releases the jump covers
3. **every breaking release found, with its reason** — not a count, the tags and why
4. what will actually run

Then stop and wait.

**A breaking change is never assumed acceptable.** Say which release breaks, say what the
notes claim breaks, and ask whether to stop short of it or go through it. If the user
says go through, re-run Step 2 with `--allow-breaking` so the plan matches what was
approved rather than being overridden by hand.

If the entry has `release_notes_url`, offer it. Reading it is cheap next to a bad upgrade.

---

## Step 4 — Back up first

Run the entry's `backup_cmd` before changing anything on the server. **Not a dry run** —
a dry run verifies the app is in a backup set, it does not produce a restore point.

Verify what came out rather than trusting the exit code: file exists, is non-empty,
decompresses, and contains the expected structure.

```bash
# e.g. for a Postgres-backed app
ssh <alias> 'zcat <dump> | grep -c "^CREATE TABLE"'
```

State the backup path in the final report. It is the rollback plan.

---

## Step 5 — Apply

Pull before swapping, so a bad tag fails while the old version is still serving:

```bash
ssh <alias> 'cd <dir> && docker compose pull'    # if the entry is container-based
```

Then run `remote.upgrade_cmd` with `{version}` substituted for the approved target.

Never write the target into the registry before the upgrade succeeds. The registry
records what is running, not what was attempted.

---

## Step 6 — Verify from the far side

The point of this step is that a version check on the machine you are standing on can
agree with you for the wrong reason.

1. **Service health** — wait for the healthcheck, do not assume. Poll, do not sleep blind.
2. **Migrations** — read the log for errors, and note whether any actually applied. If
   none did, the schema never moved and rollback is a tag flip rather than a restore.
   Say which case it is, because it changes what the user can do next.
3. **Version, reported by the service itself** — a config endpoint, or the connection
   log showing what each client presented. Never the local binary.
4. **Companions** — level them if the user wants (`companions[].upgrade_cmd`), and say
   plainly that a lagging one breaks nothing.

Then update the registry's `pinned` field to the version now running.

---

## Rolling back

Cheap only if no migration ran. Put the previous tag back and roll again.

If migrations did run, the schema is ahead of the old binary and downgrading fails in
confusing ways — restore from Step 4's backup instead. This is why Step 4 is not optional.

---

## Adding another app

Append an entry to `hetzner.json`. No code changes: every command the skill runs comes
from the registry. See [README.md](README.md) for the schema and a worked example.

The script is generic over any GitHub project that tags releases as semver. An app that
does not is not a fit — say so rather than half-supporting it.

# Iso Config: Two-Scope Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all eleven `iso-*` skills read who-and-where from a two-scope config instead of hardcoding the author, and move every deterministic step out of SKILL.md prose into a tested script.

**Status:** implemented (uncommitted) @ 2026-08-21T11:06:57Z

**Architecture:** A new `iso-config` skill owns `scripts/lib/config.sh`. Sibling skills source it by a path resolved from `${BASH_SOURCE[0]}`, which works under all four install topologies. Configuration merges per key from `~/.config/iso/iso.json` (global) and a sparse repo overlay. Prerequisites are classified auto / manual / hard-cut, swept once by `doctor`, and recorded as a versioned readiness stamp.

**Tech Stack:** Bash (`set -euo pipefail`), `jq` for all JSON, `git`, `gh`. No frameworks: tests are assertion scripts in the shape of `skills/iso-tracking/scripts/tracking.test.sh` (named `multica-session.test.sh` until Task 9).

**Spec:** `docs/adr/0004-iso-config-two-scope-overlay.md`. Vocabulary in `CONTEXT.md` (Iso config, Config scope, Overlay, Prerequisite, Readiness stamp, Run artifact).

## Global Constraints

- **Never commit.** `/iso-write` executes this plan and commits nothing. One branch, one review at the end.
- **`jq` is the hard prerequisite this design creates.** Task 3 verifies it before any code reads config.
- **No secrets in config.** Same rule as ADR-0003's Hetzner config: connection metadata and preferences only.
- **Repo overlay carries `branches` and `paths` only.** Any other top-level section in an overlay is a hard error.
- **Unknown or misspelled overlay key is a hard error naming the key.** Never a silent fall-through to global.
- **Defaults are today's hardcoded values.** A machine with no config behaves exactly as the skills do now.
- **Every extracted script gets an assertion test** using `ok` / `bad` / `check` / `contains`, stubbed binaries on a temp `PATH`, and a sourced-guard so the test can source the script without running it.
- **Deliberate simplifications carry a `# ponytail:` comment** naming the ceiling and the upgrade path.
- Shell style follows `skills/iso-commit/scripts/commit.sh`: `die()` prefixed with the skill name, `cmd_<name>()` subcommand functions, dispatch via `case "${1:-}" in`.

## Config schema

The full document, with today's hardcoded values as the defaults:

```json
{
  "branches": {
    "development": "dev",
    "test": "test",
    "production": "prod",
    "default": "dev",
    "pr_base": "dev",
    "protected": ["dev", "develop", "test", "prod", "main", "master"]
  },
  "paths": {
    "plans": "docs/superpowers/plans",
    "specs": "docs/superpowers/specs",
    "artifacts": "docs/iso/logs"
  },
  "tracker":  { "kind": "multica", "ledger": "~/.claude/multica" },
  "terminal": { "kind": "herdr" },
  "identity": { "org": "IsaiaScope", "marketplace": "marketonfire" },
  "agents": {
    "codex":  { "sessions": "~/.codex/sessions",  "full_access": "--dangerously-bypass-approvals-and-sandbox" },
    "claude": { "sessions": "~/.claude/projects", "full_access": "--dangerously-skip-permissions" }
  },
  "checked": { "at": null, "version": 0 }
}
```

This repository's overlay, in full — it is meant to be this small:

```json
{ "branches": { "default": "prod", "pr_base": "dev" } }
```

`default` is `prod` because the GitHub default branch decides what
`/plugin marketplace add IsaiaScope/ai` clones, and consumers must get released
work. `pr_base` stays `dev` because the branch gate rejects a PR into `prod`
that did not come from `test`.

## File structure

| File | Responsibility |
|---|---|
| `skills/iso-config/SKILL.md` | The `/iso-config init \| show \| doctor` surface. No logic. |
| `skills/iso-config/scripts/lib/config.sh` | Merge two scopes, validate the overlay, expose `iso_config_get`. Sourced by every other skill. |
| `skills/iso-config/scripts/lib/config.test.sh` | Assertions for merge, validation, defaults. |
| `skills/iso-config/scripts/lib/sibling.sh` | Resolve a sibling skill's path from `${BASH_SOURCE[0]}`. |
| `skills/iso-config/scripts/lib/sibling.test.sh` | Assertions for all four topologies. |
| `skills/iso-config/scripts/prereq.sh` | The prerequisite table and the classified sweep. |
| `skills/iso-config/scripts/prereq.test.sh` | Assertions for each classification branch. |
| `skills/iso-config/scripts/config.sh` | CLI entry: `init`, `show`, `doctor`. |
| `skills/iso-tracking/scripts/tracking.sh` | Tracking orchestration: ledger, redaction, plan resolution, transition gates. Renamed from `iso-tracking/scripts/tracking.sh`. |
| `skills/iso-tracking/scripts/adapters/multica.sh` | The thirteen Multica CLI verbs. The only file naming the vendor. |
| `skills/iso-tracking/scripts/adapters/none.sh` | Every verb a successful no-op, so an unconfigured install is inert. |
| `skills/iso-tracking/scripts/adapters/contract.test.sh` | The contract any future adapter is held to. |
| `skills/iso-write/scripts/write.sh` | Workspace resolution: branch derivation, stash carry, mode dispatch. |
| `skills/iso-write/scripts/write.test.sh` | Assertions for every workspace mode. |
| `skills/iso-plan/scripts/plan.sh` | Gate check, plan snapshot/diff, card payload assembly. |
| `skills/iso-plan/scripts/plan.test.sh` | Assertions for the gate and the sub-issue gate arithmetic. |
| `skills/iso-init-repo/scripts/init-repo.sh` | Branch creation, protection rules, hook install. |
| `skills/iso-init-repo/scripts/init-repo.test.sh` | Assertions for rule construction, no network. |
| `docs/iso/config.json` | This repository's overlay. |
| `docs/iso/logs/` | Run artifacts, relocated from `.iso/logs/`. |

---

## Phase 1 — The config library

### Task 1: Merge two scopes per key

**Files:**
- Create: `skills/iso-config/scripts/lib/config.sh`
- Test: `skills/iso-config/scripts/lib/config.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `iso_config` (merged JSON on stdout), `iso_config_get <dotted.key>` (string, empty when unset), `iso_defaults` (the built-in document), `iso_repo_overlay_path` (absolute path or non-zero).

- [x] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Self-check for config.sh. Run: bash config.test.sh
# ponytail: asserts only on the merge and on defaults — the two places a wrong
# answer silently redirects work to the wrong branch or the wrong board.
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/config.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

# shellcheck source=/dev/null
. "$LIB"
type iso_config_get >/dev/null 2>&1 || { echo "FATAL: sourcing did not define iso_config_get"; exit 1; }

tmp=$(mktemp -d)
export ISO_GLOBAL_CONFIG="$tmp/absent.json"

echo "defaults"
cd "$tmp" || exit 1
check "integration default"  "$(iso_config_get branches.development)" "dev"
check "plans path default"   "$(iso_config_get paths.plans)"          "docs/superpowers/plans"
check "tracker default"      "$(iso_config_get tracker.kind)"         "multica"
check "array joins on space" "$(iso_config_get branches.protected)"   "dev develop test prod main master"
check "unknown key is empty" "$(iso_config_get branches.nope)"        ""

echo "global scope"
ISO_GLOBAL_CONFIG="$tmp/global.json"
printf '%s\n' '{"terminal":{"kind":"tmux"}}' > "$ISO_GLOBAL_CONFIG"
check "global overrides default"    "$(iso_config_get terminal.kind)"     "tmux"
check "unmentioned key survives"    "$(iso_config_get branches.development)" "dev"

echo "repo overlay"
repo="$tmp/repo"; mkdir -p "$repo/docs/iso"
( cd "$repo" && git init -q -b main . )
printf '%s\n' '{"branches":{"default":"prod"}}' > "$repo/docs/iso/config.json"
cd "$repo" || exit 1
check "overlay overrides global"    "$(iso_config_get branches.default)"     "prod"
check "sibling key survives merge"  "$(iso_config_get branches.pr_base)"     "dev"
check "other sections survive"      "$(iso_config_get tracker.kind)"         "multica"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: FAIL — `config.sh: No such file or directory`

- [x] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# Iso config: the merged view of the global and repo scopes.
# Sourced, never executed — so it sets no shell options of its own.
# ponytail: jq does the merge. `*` is a deep object merge, which is exactly
# per-key semantics; arrays replace wholesale, which is right for `protected`.

ISO_GLOBAL_CONFIG="${ISO_GLOBAL_CONFIG:-$HOME/.config/iso/iso.json}"

# Every read below goes through jq, and this library is the first thing any
# skill sources. Check here so a missing jq is one sentence, not
# `jq: command not found` surfacing from the middle of an unrelated skill.
command -v jq >/dev/null 2>&1 || {
  printf 'iso-config: jq is required -- brew install jq\n' >&2
  return 1 2>/dev/null || exit 1
}

# Today's hardcoded values, so a machine with no config behaves as it does now.
iso_defaults() {
  cat <<'JSON'
{
  "branches": {
    "development": "dev",
    "test": "test",
    "production": "prod",
    "default": "dev",
    "pr_base": "dev",
    "protected": ["dev", "develop", "test", "prod", "main", "master"]
  },
  "paths": {
    "plans": "docs/superpowers/plans",
    "specs": "docs/superpowers/specs",
    "artifacts": "docs/iso/logs"
  },
  "tracker":  { "kind": "multica", "ledger": "~/.claude/multica" },
  "terminal": { "kind": "herdr" },
  "identity": { "org": "IsaiaScope", "marketplace": "marketonfire" },
  "agents": {
    "codex":  { "sessions": "~/.codex/sessions",  "full_access": "--dangerously-bypass-approvals-and-sandbox" },
    "claude": { "sessions": "~/.claude/projects", "full_access": "--dangerously-skip-permissions" }
  },
  "checked": { "at": null, "version": 0 }
}
JSON
}

iso_repo_overlay_path() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  printf '%s/docs/iso/config.json' "$root"
}

_iso_json_or_empty() { [ -f "$1" ] && cat "$1" || printf '{}'; }

iso_config() {
  local overlay=""
  overlay=$(iso_repo_overlay_path 2>/dev/null) || overlay="/nonexistent"
  jq -s '.[0] * .[1] * .[2]' \
    <(iso_defaults) \
    <(_iso_json_or_empty "$ISO_GLOBAL_CONFIG") \
    <(_iso_json_or_empty "$overlay")
}

# Dotted key -> string. Arrays join on a space so callers can `for x in $(...)`.
# Unset reads as empty, never as the literal "null".
iso_config_get() {
  iso_config | jq -r --arg k "$1" '
    reduce ($k | split(".")[]) as $p (.;
      if type == "object" then .[$p] else null end)
    | if   type == "array"  then join(" ")
      elif . == null        then ""
      else tostring end'
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: `14 passed, 0 failed`

---

### Task 2: Reject an unknown overlay key

A typo in a five-line overlay must never behave like a correct file that changed nothing. This is the same failure shape as the vacuously-true `merge-base --is-ancestor` this repository already shipped once.

**Files:**
- Modify: `skills/iso-config/scripts/lib/config.sh`
- Modify: `skills/iso-config/scripts/lib/config.test.sh`

**Interfaces:**
- Consumes: `iso_repo_overlay_path` from Task 1.
- Produces: `iso_config_validate_overlay <file>` — returns 0 when valid, prints `iso-config: unknown key <k> in <file>` to stderr and returns 1 otherwise. `iso_config` calls it and dies on failure.

- [x] **Step 1: Write the failing test**

Append to `config.test.sh` before the summary lines:

```bash
echo "overlay validation"
printf '%s\n' '{"branches":{"defualt":"prod"}}' > "$repo/docs/iso/config.json"
err=$(iso_config_validate_overlay "$repo/docs/iso/config.json" 2>&1); rc=$?
check "typo rejected"        "$rc" "1"
case "$err" in *defualt*) ok "names the bad key";; *) bad "names the bad key";; esac

printf '%s\n' '{"tracker":{"kind":"github"}}' > "$repo/docs/iso/config.json"
iso_config_validate_overlay "$repo/docs/iso/config.json" >/dev/null 2>&1
check "forbidden section rejected" "$?" "1"

printf '%s\n' '{"branches":{"default":"prod"},"paths":{"plans":"p"}}' > "$repo/docs/iso/config.json"
iso_config_validate_overlay "$repo/docs/iso/config.json" >/dev/null 2>&1
check "valid overlay accepted" "$?" "0"

rm -f "$repo/docs/iso/config.json"
iso_config_validate_overlay "$repo/docs/iso/config.json" >/dev/null 2>&1
check "absent overlay is valid" "$?" "0"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: FAIL — `iso_config_validate_overlay: command not found`

- [x] **Step 3: Write minimal implementation**

Insert into `config.sh` above `iso_config`:

```bash
# The overlay describes a repository, so it may name only what is a property of
# one. Letting it set `tracker` or `identity` would mean cloning somebody's
# repository silently redirects where your work gets filed.
ISO_OVERLAY_KEYS='branches.development branches.test branches.production
branches.default branches.pr_base branches.protected
paths.plans paths.specs paths.artifacts'

iso_config_validate_overlay() {
  local f="$1" found bad
  [ -f "$f" ] || return 0
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
    || { printf 'iso-config: %s is not a JSON object\n' "$f" >&2; return 1; }
  found=$(jq -r '
    to_entries[]
    | .key as $s
    | if (.value | type) == "object" then (.value | keys[] | "\($s).\(.)")
      else $s end' "$f" 2>/dev/null)
  bad=$(comm -23 <(printf '%s\n' "$found" | sort -u) \
                 <(printf '%s\n' $ISO_OVERLAY_KEYS | sort -u))
  [ -z "$bad" ] && return 0
  printf 'iso-config: unknown key %s in %s\n' $bad "$f" >&2
  return 1
}
```

And make `iso_config` refuse to merge an invalid overlay — insert after the `overlay=` assignment:

```bash
  iso_config_validate_overlay "$overlay" || return 1
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: `20 passed, 0 failed`

---

### Task 3: Classify and sweep prerequisites

**Files:**
- Create: `skills/iso-config/scripts/prereq.sh`
- Test: `skills/iso-config/scripts/prereq.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `ISO_PREREQ_VERSION` (integer), `iso_prereq_class <bin>` → `auto|manual|hardcut|unknown`, `iso_prereq_hint <bin>` → one line, `iso_prereq_sweep` → prints one `<state> <bin> <hint>` line per prerequisite and returns 1 if any hard-cut binary is missing.

- [x] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Self-check for prereq.sh. Run: bash prereq.test.sh
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/prereq.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

# shellcheck source=/dev/null
. "$SH"

echo "classification"
check "jq is auto"        "$(iso_prereq_class jq)"     "auto"
check "gh is auto"        "$(iso_prereq_class gh)"     "auto"
check "codex is manual"   "$(iso_prereq_class codex)"  "manual"
check "claude is manual"  "$(iso_prereq_class claude)" "manual"
check "herdr is hardcut"  "$(iso_prereq_class herdr)"  "hardcut"
check "unlisted"          "$(iso_prereq_class nope)"   "unknown"

echo "hints"
contains "brew install jq" "$(iso_prereq_hint jq)" && ok "jq hint is runnable" || bad "jq hint is runnable"
contains "login"           "$(iso_prereq_hint codex)" && ok "codex hint mentions auth" || bad "codex hint mentions auth"

echo "sweep"
bin=$(mktemp -d)
for b in jq gh multica codex claude herdr git; do printf '#!/bin/sh\n' > "$bin/$b"; chmod +x "$bin/$b"; done
out=$(PATH="$bin" iso_prereq_sweep); rc=$?
check "all present -> rc 0" "$rc" "0"
contains "ok jq" "$out" && ok "reports jq ok" || bad "reports jq ok"

rm -f "$bin/herdr"
out=$(PATH="$bin" iso_prereq_sweep); rc=$?
check "missing hardcut -> rc 1" "$rc" "1"
contains "hardcut herdr" "$out" && ok "reports herdr hardcut" || bad "reports herdr hardcut"

rm -f "$bin/codex"
out=$(PATH="$bin" iso_prereq_sweep 2>/dev/null)
contains "manual codex" "$out" && ok "reports codex manual" || bad "reports codex manual"

rm -f "$bin/jq"
out=$(PATH="$bin" iso_prereq_sweep 2>/dev/null)
contains "auto jq" "$out" && ok "reports jq auto" || bad "reports jq auto"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-config/scripts/prereq.test.sh`
Expected: FAIL — `prereq.sh: No such file or directory`

- [x] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# Prerequisite classification. Absence is not one condition: what a skill can
# do about a missing binary is what the code branches on, never the binary.
# Sourced by config.sh's CLI; sets no shell options of its own.

# Bump when the list below changes. A bump invalidates every readiness stamp in
# the field, so adding a prerequisite re-triggers the sweep without anyone
# remembering to.
ISO_PREREQ_VERSION=1

# bin:class — auto (installable unattended), manual (auth-gated, print steps),
# hardcut (no install path exists, the skill stops).
ISO_PREREQS='git:auto jq:auto gh:auto multica:auto codex:manual claude:manual herdr:hardcut'

iso_prereq_class() {
  local e
  for e in $ISO_PREREQS; do
    [ "${e%%:*}" = "$1" ] && { printf '%s' "${e##*:}"; return 0; }
  done
  printf 'unknown'
}

iso_prereq_hint() {
  case "$1" in
    git|jq|gh|multica) printf 'brew install %s' "$1" ;;
    codex)  printf 'npm install -g @openai/codex, then: codex login' ;;
    claude) printf 'npm install -g @anthropic-ai/claude-code, then run: claude' ;;
    herdr)  printf 'no package exists — build it and put it on PATH' ;;
    *)      printf 'unknown prerequisite' ;;
  esac
}

# One line per prerequisite: "<state> <bin> <hint>", where state is `ok` for a
# binary that resolves and its class otherwise. Returns 1 if any hardcut is
# missing — that is the only absence a skill cannot work around.
iso_prereq_sweep() {
  local e b cls rc=0
  for e in $ISO_PREREQS; do
    b="${e%%:*}"; cls="${e##*:}"
    if command -v "$b" >/dev/null 2>&1; then
      printf 'ok %s\n' "$b"
    else
      printf '%s %s %s\n' "$cls" "$b" "$(iso_prereq_hint "$b")"
      [ "$cls" = "hardcut" ] && rc=1
    fi
  done
  return "$rc"
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-config/scripts/prereq.test.sh`
Expected: `14 passed, 0 failed`

---

### Task 4: Record and read the readiness stamp

**Files:**
- Modify: `skills/iso-config/scripts/lib/config.sh`
- Modify: `skills/iso-config/scripts/lib/config.test.sh`

**Interfaces:**
- Consumes: `ISO_PREREQ_VERSION` from Task 3, `iso_config_get` from Task 1.
- Produces: `iso_stamp_write` (writes `checked.at` and `checked.version` into the global config, creating it), `iso_stamp_ok` — returns 0 when the stamp's version equals `ISO_PREREQ_VERSION`, 1 otherwise.

- [x] **Step 1: Write the failing test**

Append to `config.test.sh` before the summary lines:

```bash
echo "readiness stamp"
cd "$tmp" || exit 1
ISO_GLOBAL_CONFIG="$tmp/stamp.json"; rm -f "$ISO_GLOBAL_CONFIG"
ISO_PREREQ_VERSION=1
iso_stamp_ok; check "no config -> not ok" "$?" "1"

iso_stamp_write
iso_stamp_ok; check "after write -> ok" "$?" "0"
[ -n "$(iso_config_get checked.at)" ] && ok "stamp records a time" || bad "stamp records a time"
check "stamp records version" "$(iso_config_get checked.version)" "1"

ISO_PREREQ_VERSION=2
iso_stamp_ok; check "version bump invalidates" "$?" "1"
ISO_PREREQ_VERSION=1
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: FAIL — `iso_stamp_ok: command not found`

- [x] **Step 3: Write minimal implementation**

Append to `config.sh`:

```bash
# The stamp says the sweep passed, and against which prerequisite list. Skills
# trust it rather than re-probing the filesystem on every invocation.
# ponytail: no per-binary path recording — a version bump is the invalidation
# lever, and it is the one that survives the skills being edited.
iso_stamp_write() {
  local now dir
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dir=$(dirname "$ISO_GLOBAL_CONFIG"); mkdir -p "$dir"
  [ -f "$ISO_GLOBAL_CONFIG" ] || printf '{}\n' > "$ISO_GLOBAL_CONFIG"
  jq --arg at "$now" --argjson v "${ISO_PREREQ_VERSION:-0}" \
     '.checked = {at: $at, version: $v}' \
     "$ISO_GLOBAL_CONFIG" > "$ISO_GLOBAL_CONFIG.tmp" \
    && mv "$ISO_GLOBAL_CONFIG.tmp" "$ISO_GLOBAL_CONFIG"
}

iso_stamp_ok() {
  [ -f "$ISO_GLOBAL_CONFIG" ] || return 1
  [ "$(iso_config_get checked.version)" = "${ISO_PREREQ_VERSION:-0}" ]
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-config/scripts/lib/config.test.sh`
Expected: `26 passed, 0 failed`

---

### Task 5: The `/iso-config` surface

**Files:**
- Create: `skills/iso-config/scripts/config.sh`
- Create: `skills/iso-config/SKILL.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: `config.sh init | show | doctor`. `doctor` exits 1 when a hard-cut prerequisite is missing or the overlay is invalid; exits 0 otherwise, writing the stamp.

- [x] **Step 1: Write the CLI**

```bash
#!/usr/bin/env bash
# iso-config CLI. All logic lives in lib/; this file only dispatches.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib/config.sh"
# shellcheck source=/dev/null
. "$HERE/prereq.sh"

die() { printf 'iso-config: %s\n' "$1" >&2; exit 1; }

cmd_init() {
  local dir; dir=$(dirname "$ISO_GLOBAL_CONFIG")
  mkdir -p "$dir"
  [ -f "$ISO_GLOBAL_CONFIG" ] && die "$ISO_GLOBAL_CONFIG already exists"
  iso_defaults | jq 'del(.checked)' > "$ISO_GLOBAL_CONFIG"
  printf 'wrote %s\n' "$ISO_GLOBAL_CONFIG"
  printf 'edit it, then run: iso-config doctor\n'
}

# Where each value came from is the question worth answering, so show prints
# the scope alongside the merged value rather than just dumping JSON.
cmd_show() {
  local overlay; overlay=$(iso_repo_overlay_path 2>/dev/null) || overlay="/nonexistent"
  printf 'global   %s%s\n' "$ISO_GLOBAL_CONFIG" \
    "$([ -f "$ISO_GLOBAL_CONFIG" ] || printf '   (absent)')"
  printf 'overlay  %s%s\n\n' "$overlay" \
    "$([ -f "$overlay" ] || printf '   (absent)')"
  iso_config
}

# ADR-0004 records ~/.codex/skills/ sitting empty while CLAUDE.md documented
# both agents as linked. Catching a claim and a filesystem disagreeing is what
# doctor is for.
# ponytail: reports, never repairs — install.js owns the linking.
cmd_doctor_topology() {
  local d n
  for d in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    [ -d "$d" ] || { printf '  absent   %s\n' "$d"; continue; }
    n=$(find "$d" -maxdepth 1 -name 'iso-*' | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then
      printf '  EMPTY    %s   -> run: node scripts/install.js\n' "$d"
    else
      printf '  ok       %s   (%s iso-* skills)\n' "$d" "$n"
    fi
  done
}

cmd_doctor() {
  local overlay out rc=0
  overlay=$(iso_repo_overlay_path 2>/dev/null) || overlay="/nonexistent"
  if ! iso_config_validate_overlay "$overlay"; then rc=1; fi
  out=$(iso_prereq_sweep) || rc=1
  printf '%s\n' "$out" | while read -r state bin hint; do
    case "$state" in
      ok)      printf '  ok       %s\n' "$bin" ;;
      auto)    printf '  install  %s   -> %s\n' "$bin" "$hint" ;;
      manual)  printf '  manual   %s   -> %s\n' "$bin" "$hint" ;;
      hardcut) printf '  BLOCKED  %s   -> %s\n' "$bin" "$hint" ;;
    esac
  done
  cmd_doctor_topology
  [ "$rc" -eq 0 ] || die "not ready — resolve the lines above"
  iso_stamp_write
  printf '\nready (prerequisite list v%s)\n' "$ISO_PREREQ_VERSION"
}

case "${1:-}" in
  init)   cmd_init ;;
  show)   cmd_show ;;
  doctor) cmd_doctor ;;
  *)      die "usage: config.sh init | show | doctor" ;;
esac
```

- [x] **Step 2: Run it against a temp home**

Run:
```bash
t=$(mktemp -d); ISO_GLOBAL_CONFIG="$t/iso.json" bash skills/iso-config/scripts/config.sh init
ISO_GLOBAL_CONFIG="$t/iso.json" bash skills/iso-config/scripts/config.sh show
ISO_GLOBAL_CONFIG="$t/iso.json" bash skills/iso-config/scripts/config.sh doctor
```
Expected: `init` writes the file; `show` prints both scope paths then the merged JSON; `doctor` prints one line per prerequisite and ends `ready (prerequisite list v1)`.

- [x] **Step 3: Write SKILL.md**

```markdown
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
| `doctor` | Validates the overlay, sweeps prerequisites, records the readiness stamp. |

All three run `scripts/config.sh`. This file describes the surface; it holds no logic.

## Scopes

`~/.config/iso/iso.json` describes **you** — tracker, terminal, identity, agent
data. `docs/iso/config.json` in a repository describes **that repository**, and
may carry `branches` and `paths` only. Repo wins per key, not per file.

An overlay is meant to be tiny. This repository's is two lines, because two
values differ from the global ones.

## Reading config from another skill

Resolve the library relative to your own script, never through `$HOME/.claude` —
that path is correct under one of the four install topologies and silently
wrong under the rest.

    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    . "$HERE/../../iso-config/scripts/lib/config.sh"
    integration=$(iso_config_get branches.development)

## Prerequisites

Classified by what can be done when one is absent, in `scripts/prereq.sh`:
`auto` installs unattended, `manual` prints steps for a human, `hardcut` stops
the skill. Bump `ISO_PREREQ_VERSION` when the list changes — it invalidates
every readiness stamp, so the sweep re-runs without anyone remembering to.
```

- [x] **Step 4: Confirm packaging picks it up**

Run: `node scripts/install.js`
Expected: `iso-config` appears in the link list and in `plugins/isaiascope-eng/.claude-plugin/plugin.json`. The `iso-` prefix routes it with no edit to any manifest.

---

## Phase 2 — Sibling resolution

### Task 6: Resolve sibling skills from the caller, not from `$HOME`

`iso-plan:90`, `iso-write:48` and `iso-push:305` all hardcode
`$HOME/.claude/skills/iso-tracking/scripts/tracking.sh`. That
resolves under the development symlink and under nothing else — not the
marketplace clone, not `~/.agents/skills/`, not the repository itself.

**Files:**
- Create: `skills/iso-config/scripts/lib/sibling.sh`
- Test: `skills/iso-config/scripts/lib/sibling.test.sh`
- Modify: `skills/iso-plan/SKILL.md:90`, `skills/iso-write/SKILL.md:48`, `skills/iso-push/SKILL.md:305`

**Interfaces:**
- Consumes: nothing.
- Produces: `iso_sibling <skill> <relpath>` — absolute path to a file inside a sibling skill, resolved from `${BASH_SOURCE[1]}`. Returns 1 and prints nothing when the target does not exist.

- [x] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Self-check for sibling.sh. Run: bash sibling.test.sh
# Builds each of the four real install topologies in a temp dir and resolves
# across them. The bug this guards is silent: a wrong path just means tracking
# quietly stops happening.
set -uo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)/sibling.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

tmp=$(mktemp -d)

# A skills root with two skills: one that calls, one that is called.
mkskills() {
  local root="$1"
  mkdir -p "$root/iso-caller/scripts" "$root/iso-target/scripts"
  cp "$LIB" "$root/iso-caller/scripts/sibling.sh"
  printf '#!/bin/sh\necho reached\n' > "$root/iso-target/scripts/run.sh"
  chmod +x "$root/iso-target/scripts/run.sh"
  cat > "$root/iso-caller/scripts/call.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/sibling.sh"
iso_sibling iso-target scripts/run.sh
SH
  chmod +x "$root/iso-caller/scripts/call.sh"
}

echo "topology: repository"
mkskills "$tmp/repo/skills"
check "resolves in repo" \
  "$(bash "$tmp/repo/skills/iso-caller/scripts/call.sh")" \
  "$tmp/repo/skills/iso-target/scripts/run.sh"

echo "topology: development symlink"
mkdir -p "$tmp/home/.claude/skills"
ln -sfn "$tmp/repo/skills/iso-caller" "$tmp/home/.claude/skills/iso-caller"
ln -sfn "$tmp/repo/skills/iso-target" "$tmp/home/.claude/skills/iso-target"
out=$(bash "$tmp/home/.claude/skills/iso-caller/scripts/call.sh")
[ -f "$out" ] && ok "resolves through symlink" || { bad "resolves through symlink"; printf '       got=%q\n' "$out"; }

echo "topology: marketplace clone"
mkskills "$tmp/marketplaces/marketonfire/skills"
check "resolves in clone" \
  "$(bash "$tmp/marketplaces/marketonfire/skills/iso-caller/scripts/call.sh")" \
  "$tmp/marketplaces/marketonfire/skills/iso-target/scripts/run.sh"

echo "topology: .agents indirection"
mkskills "$tmp/agents/skills"
check "resolves in .agents" \
  "$(bash "$tmp/agents/skills/iso-caller/scripts/call.sh")" \
  "$tmp/agents/skills/iso-target/scripts/run.sh"

echo "missing target"
bash -c ". $LIB; iso_sibling iso-nope scripts/run.sh" >/dev/null 2>&1
check "absent sibling -> rc 1" "$?" "1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-config/scripts/lib/sibling.test.sh`
Expected: FAIL — `sibling.sh: No such file or directory`

- [x] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# Resolve a file inside a sibling skill, from wherever this skill is installed.
# Sourced, never executed.
#
# Every topology puts a skill's siblings directly beside it:
#   <repo>/skills/<skill>/                    the repository
#   ~/.claude/skills/<skill>                  development symlink
#   ~/.claude/plugins/marketplaces/*/skills/  marketplace clone
#   ~/.agents/skills/<skill>                  upstream-pack indirection
# So "one directory up, then across" is correct in all four. `$HOME/.claude` is
# correct in exactly one, which is the bug this replaces.

iso_sibling() {
  local skill="$1" rel="$2" here candidate
  # BASH_SOURCE[1] is the file that called us, not this library.
  here=$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)
  # Walk up from the caller until a directory holding sibling skills appears.
  while [ "$here" != "/" ]; do
    candidate="$here/../$skill/$rel"
    if [ -e "$candidate" ]; then
      ( cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$(basename "$candidate")" )
      return 0
    fi
    here=$(dirname "$here")
  done
  return 1
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-config/scripts/lib/sibling.test.sh`
Expected: `6 passed, 0 failed`

- [x] **Step 5: Replace all three hardcoded paths**

In `skills/iso-plan/SKILL.md:90`, `skills/iso-write/SKILL.md:48` and `skills/iso-push/SKILL.md:305`, replace

```bash
S="$HOME/.claude/skills/iso-tracking/scripts/tracking.sh"
```

with

```bash
. "$(dirname "${BASH_SOURCE[0]}")/../../iso-config/scripts/lib/sibling.sh"
S=$(iso_sibling iso-tracking scripts/tracking.sh) || S=""
```

The existing `[ -x "$S" ]` guard in each of the three already makes an empty `S` a silent no-op, which is the behaviour tracking is supposed to have when it cannot run.

Use the current name `iso-tracking` here, not the name it gets in Task
9. Each task has to work when it is finished, and the directory does not get
renamed until then; Task 9 rewrites these three lines again as part of its own
rename step.

- [x] **Step 6: Verify no hardcode survives**

Run: `grep -rn 'HOME/.claude/skills' skills/`
Expected: no output.

---

## Phase 3 — Relocate run artifacts

### Task 7: `.iso/` becomes `docs/iso/`, tracked

34 occurrences across 16 files, 7 of them test files. Tracked deliberately: see ADR-0004's consequences section, including the 13 MB measurement and the home-path leak, both accepted.

**Files:**
- Modify: all 16 files listing `.iso/` (`grep -rl '\.iso/' skills/`)
- Modify: `.gitignore`
- Move: `.iso/` → `docs/iso/`

- [x] **Step 1: Confirm the surface before touching it**

Run: `grep -rc '\.iso/' $(grep -rl '\.iso/' skills/) | sort`
Expected: 16 files, 34 total occurrences. Record the number — Step 4 checks it reached zero.

- [x] **Step 2: Rewrite every reference**

```bash
git mv .iso docs/iso 2>/dev/null || { mkdir -p docs && mv .iso docs/iso; }
grep -rl '\.iso/' skills/ | while read -r f; do
  perl -pi -e 's{(?<![\w/.])\.iso/}{docs/iso/}g' "$f"
done
```

`perl` rather than `sed`: the pattern needs a look-behind so `docs/.iso/` and
`x.iso/` are not rewritten, and BSD `sed` has no look-behind.

- [x] **Step 3: Point `.gitignore` at the new location**

Replace the `.iso/` line in `.gitignore` with:

```gitignore
# iso-* run artifacts now live at docs/iso/logs/ and ARE tracked — see
# docs/adr/0004-iso-config-two-scope-overlay.md. Only the transient scratch
# files stay out.
docs/iso/logs/**/*.stderr
docs/iso/logs/review/.spawned-terms
```

- [x] **Step 4: Run the full suite**

Run:
```bash
for t in $(find skills -name '*.test.sh'); do echo "== $t"; bash "$t" || echo "FAILED $t"; done
bash skills/iso-spawn/tests/run.sh
grep -rn '(?<![\w/.])\.iso/' skills/ || echo "no stale references"
```
Expected: every suite passes; no stale `.iso/` reference remains.

- [x] **Step 5: Confirm the artifacts are now tracked**

Run: `git status --porcelain docs/iso | head`
Expected: `docs/iso/logs/...` files appear as additions, not ignored.

---

## Phase 4 — Thread config through the skills that already have scripts

Each task in this phase is the same shape: source the library, replace a
literal with a lookup, keep the literal as the default so behaviour is
unchanged when no config exists. The preamble is identical everywhere:

```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"
```

### Task 8: Branch vocabulary in `iso-push`

**Files:**
- Modify: `skills/iso-push/scripts/push.sh`
- Modify: `skills/iso-push/scripts/push.test.sh`

**Interfaces:**
- Consumes: `iso_config_get` (Task 1), `iso_sibling` (Task 6).
- Produces: nothing new — `push.sh`'s CLI is unchanged.

- [x] **Step 1: Write the failing test**

Append to `push.test.sh`:

```bash
echo "branch vocabulary from config"
cfgrepo=$(mktemp -d); mkdir -p "$cfgrepo/docs/iso"
( cd "$cfgrepo" && git init -q -b main . )
printf '%s\n' '{"branches":{"development":"trunk"}}' > "$cfgrepo/docs/iso/config.json"
out=$( cd "$cfgrepo" && ISO_GLOBAL_CONFIG=/nonexistent bash "$SH" development-branch )
check "overlay renames development" "$out" "trunk"

out=$( cd "$cfgrepo" && rm -f docs/iso/config.json && ISO_GLOBAL_CONFIG=/nonexistent bash "$SH" development-branch )
check "default when no overlay" "$out" "dev"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-push/scripts/push.test.sh`
Expected: FAIL — `development-branch` is not a known subcommand.

- [x] **Step 3: Replace the literals**

Add the preamble above to the top of `push.sh`, then replace every hardcoded
branch literal with a lookup. Add the subcommand the test calls:

```bash
DEVELOPMENT=$(iso_config_get branches.development)
PROTECTED=$(iso_config_get branches.protected)
PR_BASE=$(iso_config_get branches.pr_base)

cmd_development_branch() { printf '%s\n' "$DEVELOPMENT"; }
```

The refusal that currently names `dev|test|prod|main|master` inline becomes a
membership test against `$PROTECTED`:

```bash
is_protected() {
  local b
  for b in $PROTECTED; do [ "$b" = "$1" ] && return 0; done
  return 1
}
```

- [x] **Step 4: Run the suite**

Run: `bash skills/iso-push/scripts/push.test.sh`
Expected: every prior assertion still passes, plus the two new ones.

---

### Task 9: Split the tracker behind an adapter

The largest task in the plan. `iso-tracking` names one board in the
skill name, the script name, and every call site that reaches it — and the
coupling is only thirteen CLI verbs. This task renames the skill, moves those
thirteen behind an adapter, and adds the contract a future adapter is held to.

Rename and split are one task, not two: a rename without the split is churn,
so no reviewer would accept one and reject the other.

**Files:**
- Rename: `skills/iso-tracking/` → `skills/iso-tracking/`
- Rename: `scripts/tracking.sh` → `scripts/tracking.sh`, `scripts/multica-session.test.sh` → `scripts/tracking.test.sh`
- Create: `skills/iso-tracking/scripts/adapters/multica.sh`
- Create: `skills/iso-tracking/scripts/adapters/none.sh`
- Test: `skills/iso-tracking/scripts/adapters/contract.test.sh`
- Modify: `skills/iso-plan/SKILL.md`, `skills/iso-write/SKILL.md`, `skills/iso-push/SKILL.md` — the `iso_sibling` target from Task 6
- Modify: `skills/iso-tracking/SKILL.md`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: the adapter contract — thirteen functions every `adapters/<kind>.sh`
  must define. `tk_auth_ok`; `tk_project_list`; `tk_issue_create <project>
  <status> <title> [parent] [stage]` (body on stdin, key on stdout);
  `tk_issue_get <key>`; `tk_issue_status <key> <status>`; `tk_issue_children
  <key>` (one key per line); `tk_issue_comment <key>` (body on stdin);
  `tk_issue_label <key> <label>`; `tk_issue_property <key> <name> <value>`;
  `tk_label_list`; `tk_label_create <name>`; `tk_property_list`;
  `tk_property_create <name>`. JSON-returning verbs print JSON on stdout.

- [x] **Step 1: Write the failing contract test**

```bash
#!/usr/bin/env bash
# The contract every adapter must satisfy. Run: bash contract.test.sh
# ponytail: shape and inertness only. Whether multica's API answers correctly is
# multica's problem; whether an adapter is complete and safe is ours.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

VERBS='tk_auth_ok tk_project_list tk_issue_create tk_issue_get tk_issue_status
tk_issue_children tk_issue_comment tk_issue_label tk_issue_property
tk_label_list tk_label_create tk_property_list tk_property_create'

for a in "$DIR"/*.sh; do
  case "$a" in *contract.test.sh) continue;; esac
  name=$(basename "$a" .sh)
  echo "adapter: $name"
  for v in $VERBS; do
    if bash -c ". '$a' >/dev/null 2>&1; type $v" >/dev/null 2>&1; then
      ok "$name defines $v"
    else
      bad "$name defines $v"
    fi
  done
done

echo "none adapter is inert"
N="$DIR/none.sh"
check "auth_ok succeeds"      "$(bash -c ". $N; tk_auth_ok; echo \$?")"                 "0"
check "issue_create succeeds" "$(bash -c ". $N; printf body | tk_issue_create p todo t >/dev/null; echo \$?")" "0"
check "issue_create is silent" "$(bash -c ". $N; printf body | tk_issue_create p todo t")" ""
check "children is empty"     "$(bash -c ". $N; tk_issue_children KEY-1")"              ""
check "project_list is json"  "$(bash -c ". $N; tk_project_list" | jq -r 'type')"       "array"

echo "multica adapter never starts work"
# The outbound-only invariant: nothing written to the board may cause execution
# locally. --no-start is how multica expresses that, and it must be on every
# status write.
M="$DIR/multica.sh"
writes=$(grep -c 'issue status' "$M")
guarded=$(grep -c 'issue status.*--no-start' "$M")
check "every status write carries --no-start" "$guarded" "$writes"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-tracking/scripts/adapters/contract.test.sh`
Expected: FAIL — the directory does not exist.

- [x] **Step 3: Rename the skill, keeping the 142 assertions green**

```bash
git mv skills/iso-tracking skills/iso-tracking
git mv skills/iso-tracking/scripts/tracking.sh      skills/iso-tracking/scripts/tracking.sh
git mv skills/iso-tracking/scripts/multica-session.test.sh skills/iso-tracking/scripts/tracking.test.sh
perl -pi -e 's/multica-session\.sh/tracking.sh/g; s/iso-tracking/iso-tracking/g' \
  skills/iso-tracking/scripts/tracking.test.sh \
  skills/iso-tracking/SKILL.md \
  skills/iso-plan/SKILL.md skills/iso-write/SKILL.md skills/iso-push/SKILL.md
```

Update the skill's `name:` frontmatter to `iso-tracking` and rewrite its
`description:` so it names the role, not the vendor — "the work tracker every
iso-* skill files against", with Multica as the adapter that ships.

- [x] **Step 4: Run the existing suite to prove the rename changed nothing**

Run: `bash skills/iso-tracking/scripts/tracking.test.sh`
Expected: `142 passed, 0 failed` — the same numbers as before the rename. Any
change here is a rename bug, not new behaviour.

- [x] **Step 5: Extract the thirteen verbs**

```bash
#!/usr/bin/env bash
# Multica adapter. Every multica CLI call in the codebase lives here and
# nowhere else. Sourced by tracking.sh; sets no shell options.
#
# Redaction is NOT done here — tracking.sh redacts before calling any verb that
# takes a body, so an adapter written in a hurry cannot skip it.

tk_auth_ok() { multica auth status >/dev/null 2>&1; }

tk_project_list() { multica project list --output json 2>/dev/null; }

# stdin = description. stdout = the created issue key.
tk_issue_create() {
  local project="$1" status="$2" title="$3" parent="${4:-}" stage="${5:-}"
  local args=(issue create --title "$title" --project "$project" --status "$status" --description-stdin)
  [ -n "$parent" ] && args+=(--parent "$parent")
  [ -n "$stage" ]  && args+=(--stage "$stage")
  multica "${args[@]}" 2>/dev/null | grep -oE '[A-Z]+-[0-9]+' | head -1
}

tk_issue_get()      { multica issue get "$1" --output json 2>/dev/null; }

# --no-start is the outbound-only invariant: a status written to the board must
# never cause an agent to start running locally.
tk_issue_status()   { multica issue status "$1" "$2" --no-start >/dev/null 2>&1; }

tk_issue_children() {
  multica issue children "$1" --output json 2>/dev/null \
    | jq -r '(.issues? // .)[]? | (.identifier // .key // empty)' 2>/dev/null
}

tk_issue_comment()  { multica issue comment add "$1" --content-stdin >/dev/null 2>&1; }
tk_issue_label()    { multica issue label add "$1" "$2" >/dev/null 2>&1; }
tk_issue_property() { multica issue property set "$1" "$2" "$3" >/dev/null 2>&1; }

tk_label_list()     { multica label list --output json 2>/dev/null; }
tk_label_create()   { multica label create --name "$1" >/dev/null 2>&1; }
tk_property_list()  { multica property list --output json 2>/dev/null; }
tk_property_create(){ multica property create --name "$1" >/dev/null 2>&1; }
```

Then replace every inline `multica ...` call in `tracking.sh` with the matching
`tk_*` call. When done, `grep -c '\bmultica\b' tracking.sh` must be 0 — the
name appears only in `adapters/multica.sh`.

- [x] **Step 6: Write the inert adapter**

```bash
#!/usr/bin/env bash
# The adapter for "no tracker configured". Every verb succeeds and does
# nothing, so a fresh install runs the whole tracking path inertly rather than
# erroring at a board it has never heard of.
# ponytail: no logging. A user who configured no tracker does not want a log
# of the tracking that did not happen.

tk_auth_ok()        { return 0; }
tk_project_list()   { printf '[]'; }
tk_issue_create()   { cat >/dev/null; return 0; }
tk_issue_get()      { printf '{}'; }
tk_issue_status()   { return 0; }
tk_issue_children() { return 0; }
tk_issue_comment()  { cat >/dev/null; return 0; }
tk_issue_label()    { return 0; }
tk_issue_property() { return 0; }
tk_label_list()     { printf '[]'; }
tk_label_create()   { return 0; }
tk_property_list()  { printf '[]'; }
tk_property_create(){ return 0; }
```

- [x] **Step 7: Select the adapter from config**

Near the top of `tracking.sh`, after the config preamble:

```bash
_kind=$(iso_config_get tracker.kind)
_adapter="$HERE/adapters/${_kind}.sh"
if [ ! -f "$_adapter" ]; then
  logf "unknown tracker.kind '$_kind' — falling back to none"
  _adapter="$HERE/adapters/none.sh"
fi
# shellcheck source=/dev/null
. "$_adapter"

# The ledger belongs to the tracker that wrote it, so it is keyed by kind. A
# swap must not leave rows pointing at issue keys the new board never issued.
_ledger=$(iso_config_get tracker.ledger)
MULTICA_STATE_DIR="${MULTICA_STATE_DIR:-${_ledger/#\~/$HOME}/$_kind}"
```

An unknown kind falls back to `none` rather than dying: tracking must never be
able to fail the run that invoked it, which is the rule every call site already
relies on.

- [x] **Step 8: Run both suites**

Run:
```bash
bash skills/iso-tracking/scripts/adapters/contract.test.sh
bash skills/iso-tracking/scripts/tracking.test.sh
grep -n '\bmultica\b' skills/iso-tracking/scripts/tracking.sh || echo "vendor name confined to the adapter"
```
Expected: contract test `31 passed, 0 failed`; tracking suite `142 passed, 0
failed`; the vendor name appears nowhere in `tracking.sh`.

- [x] **Step 9: Confirm a fresh install is inert**

Run:
```bash
t=$(mktemp -d); g="$t/iso.json"; printf '%s\n' '{"tracker":{"kind":"none"}}' > "$g"
ISO_GLOBAL_CONFIG="$g" bash skills/iso-tracking/scripts/tracking.sh reconcile; echo "rc=$?"
```
Expected: `rc=0`, no output, no network call.

---

### Task 10: Terminal and agent-kind data in `iso-spawn`

`agentkind.sh:12-13` already reads `ISO_CLAUDE_PROJ` and `ISO_CODEX_SESS`, so
the override seam exists — config becomes its source. `agentkind.sh:39-40`
hardcodes the two full-access flags.

**Files:**
- Modify: `skills/iso-spawn/scripts/lib/agentkind.sh`
- Modify: `skills/iso-spawn/scripts/lib/herdr.sh`
- Modify: `skills/iso-spawn/tests/run.sh`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: nothing new. The kind set stays closed — see ADR-0004's deferred section.

- [x] **Step 1: Write the failing test**

Append to `skills/iso-spawn/tests/run.sh`:

```bash
echo "agent data from config"
g=$(mktemp -d)/iso.json; mkdir -p "$(dirname "$g")"
printf '%s\n' '{"agents":{"codex":{"sessions":"/tmp/sess"}}}' > "$g"
out=$( ISO_GLOBAL_CONFIG="$g" bash -c ". $AGENTKIND; agent_sessions_dir codex" )
check "config sets codex sessions dir" "$out" "/tmp/sess"

out=$( ISO_GLOBAL_CONFIG=/nonexistent bash -c ". $AGENTKIND; agent_full_access_flag claude" )
check "claude flag default" "$out" "--dangerously-skip-permissions"

out=$( ISO_GLOBAL_CONFIG=/nonexistent bash -c ". $AGENTKIND; agent_sessions_dir codex" )
check "codex sessions default" "$out" "$HOME/.codex/sessions"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — config values are not consulted.

- [x] **Step 3: Replace the literals**

In `agentkind.sh`, the two functions read config with the existing env var
still winning, so nothing that already sets it breaks:

```bash
agent_sessions_dir() {
  local d
  case "$1" in
    claude) d="${ISO_CLAUDE_PROJ:-$(iso_config_get agents.claude.sessions)}" ;;
    *)      d="${ISO_CODEX_SESS:-$(iso_config_get agents.codex.sessions)}" ;;
  esac
  printf '%s' "${d/#\~/$HOME}"
}

agent_full_access_flag() {
  case "$1" in
    claude) iso_config_get agents.claude.full_access ;;
    *)      iso_config_get agents.codex.full_access ;;
  esac
}
```

In `herdr.sh`, replace the hardcoded binary name:

```bash
# hint lives in prereq.sh, which config.sh does not pull in
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/prereq.sh)"

TERMINAL=$(iso_config_get terminal.kind)
command -v "$TERMINAL" >/dev/null 2>&1 \
  || { printf 'iso-spawn: %s not found — %s\n' "$TERMINAL" "$(iso_prereq_hint "$TERMINAL")" >&2; exit 1; }
```

- [x] **Step 4: Run the suite**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all existing assertions pass, plus the three new ones.

---

### Task 11: Paths in `iso-review` and `iso-todo`

`drive.sh:33` hardcodes `RV_OUTDIR="${RV_OUTDIR:-.iso/logs/review}"`, already
rewritten to `docs/iso/logs/review` by Task 7. It now derives from config.

**Files:**
- Modify: `skills/iso-review/scripts/lib/drive.sh`
- Modify: `skills/iso-todo/scripts/todo.sh`, `skills/iso-todo/scripts/classify-impl.sh`
- Modify: `skills/iso-review/scripts/lib/drive.test.sh`, `skills/iso-todo/scripts/todo.test.sh`, `skills/iso-todo/scripts/classify-impl.test.sh`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: nothing new.

- [x] **Step 1: Write the failing test**

Append to `drive.test.sh`:

```bash
echo "artifact root from config"
g=$(mktemp -d)/iso.json; mkdir -p "$(dirname "$g")"
printf '%s\n' '{"paths":{"artifacts":"build/iso"}}' > "$g"
out=$( ISO_GLOBAL_CONFIG="$g" bash -c ". $DRIVE; printf '%s' \"\$RV_OUTDIR\"" )
check "config moves review outdir" "$out" "build/iso/review"

out=$( ISO_GLOBAL_CONFIG=/nonexistent bash -c ". $DRIVE; printf '%s' \"\$RV_OUTDIR\"" )
check "default review outdir" "$out" "docs/iso/logs/review"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-review/scripts/lib/drive.test.sh`
Expected: FAIL — `RV_OUTDIR` is still the literal.

- [x] **Step 3: Replace the literals**

In `drive.sh`:

```bash
ISO_ARTIFACTS=$(iso_config_get paths.artifacts)
RV_OUTDIR="${RV_OUTDIR:-$ISO_ARTIFACTS/review}"
```

In `todo.sh` and `classify-impl.sh`, the blocked-marker location becomes:

```bash
ISO_ARTIFACTS=$(iso_config_get paths.artifacts)
BLOCKED_DIR="$ISO_ARTIFACTS/write"
```

In `spawn.sh:267`, the sidecar directory becomes `$ISO_ARTIFACTS/spawn`.

- [x] **Step 4: Run the suite**

Run:
```bash
bash skills/iso-review/scripts/lib/drive.test.sh
bash skills/iso-todo/scripts/todo.test.sh
bash skills/iso-todo/scripts/classify-impl.test.sh
```
Expected: all pass, including the two new assertions.

---

## Phase 5 — Extract deterministic logic from prose

Roughly 270 lines of bash currently live inside SKILL.md fenced blocks, where a
model re-reads and re-interprets them on every run. Each task here moves one
skill's share into a script and leaves the SKILL.md describing *what* happens,
with the script as the single definition of *how*.

### Task 12: `iso-write` workspace resolution

`skills/iso-write/SKILL.md` holds 53 lines of bash across five blocks: the
pre-flight (31–35), `iso_track` (46–53), `stash_carry`/`stash_pop` (78–93), the
default-mode branch gate (99–118) and the named-branch mode (132–141).

**Files:**
- Create: `skills/iso-write/scripts/write.sh`
- Test: `skills/iso-write/scripts/write.test.sh`
- Modify: `skills/iso-write/SKILL.md`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: `write.sh branch-for <plan-path>` → derived `<type>/<slug>`; `write.sh resolve <plan-path> [--no-branch|--branch=<n>|--worktree]` → prints `mode=<m>` and `branch=<b>`, performing the checkout and stash carry; `write.sh track <progress|review|blocked> <plan-path>` → the guarded tracking call.

- [x] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Self-check for write.sh. Run: bash write.test.sh
# ponytail: asserts branch derivation and the base-branch gate — the two places
# a wrong answer creates a branch nobody wanted or strands work on the wrong one.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/write.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

export ISO_GLOBAL_CONFIG=/nonexistent

echo "branch derivation"
check "known type"     "$(bash "$SH" branch-for 2026-05-26-feat-health-check.md)"  "feat/health-check"
check "refactor type"  "$(bash "$SH" branch-for 2026-08-21-refactor-iso-config.md)" "refactor/iso-config"
check "unknown type defaults to feat" \
                       "$(bash "$SH" branch-for 2026-05-26-make-it-faster.md)"      "feat/make-it-faster"
check "path is stripped" \
                       "$(bash "$SH" branch-for docs/superpowers/plans/2026-01-01-fix-a.md)" "fix/a"
bash "$SH" branch-for 2026-05-26-feat-.md >/dev/null 2>&1
check "empty slug rejected" "$?" "1"

newrepo() {
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q -b "$1" . && git commit -q --allow-empty -m init )
  printf '%s' "$d"
}

echo "workspace resolution"
r=$(newrepo dev); touch "$r/plan.md"
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md )
check "base branch cuts a branch"  "$(printf '%s' "$out" | grep '^mode=')"   "mode=fresh-branch"
check "and names it"               "$(printf '%s' "$out" | grep '^branch=')" "branch=feat/thing"

r=$(newrepo dev); ( cd "$r" && git checkout -q -b feat/existing )
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md )
check "feature branch is reused"   "$(printf '%s' "$out" | grep '^mode=')"   "mode=current-branch"
check "and keeps its name"         "$(printf '%s' "$out" | grep '^branch=')" "branch=feat/existing"

r=$(newrepo dev); ( cd "$r" && git branch feat/thing )
( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md ) >/dev/null 2>&1
check "existing target branch halts" "$?" "1"

echo "protected list comes from config"
r=$(newrepo trunk); mkdir -p "$r/docs/iso"
printf '%s\n' '{"branches":{"protected":["trunk"]}}' > "$r/docs/iso/config.json"
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md )
check "config-named base cuts a branch" "$(printf '%s' "$out" | grep '^mode=')" "mode=fresh-branch"

echo "stash carry"
r=$(newrepo dev); printf 'dirty\n' > "$r/file.txt"
( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md ) >/dev/null 2>&1
check "uncommitted work rides along" "$( cd "$r" && cat file.txt )" "dirty"
check "and lands on the new branch"  "$( cd "$r" && git branch --show-current )" "feat/thing"

echo "no-branch mode"
r=$(newrepo dev)
out=$( cd "$r" && bash "$SH" resolve 2026-05-26-feat-thing.md --no-branch )
check "no checkout happens" "$(printf '%s' "$out" | grep '^branch=')" "branch=dev"

echo "conflicting flags"
r=$(newrepo dev)
( cd "$r" && bash "$SH" resolve p.md --no-branch --worktree ) >/dev/null 2>&1
check "two modes rejected" "$?" "1"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-write/scripts/write.test.sh`
Expected: FAIL — `write.sh: No such file or directory`

- [x] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# iso-write mechanics: derive the branch, resolve the workspace, carry the
# stash, call tracking. Plan execution stays in SKILL.md — this file makes no
# decisions a model should be making.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

die() { printf 'iso-write: %s\n' "$1" >&2; exit 1; }

KNOWN_TYPES='feat fix chore refactor docs test perf'

# YYYY-MM-DD-<type>-<slug>.md -> <type>/<slug>. An unrecognised second token is
# part of the slug, and the type defaults to feat.
cmd_branch_for() {
  local base rest type slug t
  base=${1##*/}; base=${base%.md}
  rest=${base#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}
  [ "$rest" = "$base" ] && die "plan filename lacks a YYYY-MM-DD- prefix: $1"
  type=feat; slug="$rest"
  for t in $KNOWN_TYPES; do
    if [ "${rest%%-*}" = "$t" ]; then type="$t"; slug="${rest#*-}"; break; fi
  done
  [ -n "$slug" ] || die "empty slug after type prefix"
  printf '%s/%s\n' "$type" "$slug"
}

is_base_branch() {
  local b
  [ -z "$1" ] && return 0          # detached HEAD gets a branch to live on
  for b in $(iso_config_get branches.protected); do
    [ "$b" = "$1" ] && return 0
  done
  return 1
}

# Carry uncommitted work across a checkout. Echoes the stash label, and only
# the label, so the caller can pop exactly that stash.
stash_carry() {
  local name="iso-write/$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git stash push -u -m "$name" >&2 || die "stash failed"
  printf '%s' "$name"
}

stash_pop() {
  local ref
  [ -n "$1" ] || return 0
  ref=$(git stash list --format='%gd %s' | grep -F "$1" | head -1 | cut -d' ' -f1)
  git stash pop "${ref:-stash@{0}}" || die "stash pop conflict — resolve, then re-run"
}

cmd_resolve() {
  local plan="$1"; shift
  local flag="" arg branch current mode label
  for arg in "$@"; do
    case "$arg" in
      --no-branch|--worktree|--branch=*)
        [ -n "$flag" ] && die "pick one workspace mode"
        flag="$arg" ;;
      *) die "unknown flag: $arg" ;;
    esac
  done

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo"
  current=$(git branch --show-current)

  case "$flag" in
    --no-branch)
      mode=no-branch; branch="$current" ;;
    --branch=*)
      branch="${flag#--branch=}"
      label=$(stash_carry "$branch")
      git rev-parse --verify "$branch" >/dev/null 2>&1 \
        && git checkout -q "$branch" || git checkout -q -b "$branch"
      stash_pop "$label"
      mode=named-branch ;;
    --worktree)
      branch=$(cmd_branch_for "$plan")
      mode=worktree ;;   # SKILL.md hands off to superpowers:using-git-worktrees
    "")
      if is_base_branch "$current"; then
        branch=$(cmd_branch_for "$plan")
        git rev-parse --verify "$branch" >/dev/null 2>&1 \
          && die "branch $branch already exists — delete it, rename the plan, or pass --branch=$branch"
        label=$(stash_carry "$branch")
        git checkout -q -b "$branch"
        stash_pop "$label"
        mode=fresh-branch
      else
        # A branch with no commits isolates nothing: same worktree, same index.
        # Cutting another one buys bookkeeping and no separation.
        branch="$current"; mode=current-branch
      fi ;;
  esac
  printf 'mode=%s\nbranch=%s\n' "$mode" "$branch"
}

# Tracking must never be able to fail a write run.
cmd_track() {
  local s
  s=$(iso_sibling iso-tracking scripts/tracking.sh) || return 0
  [ -x "$s" ] && git rev-parse --show-toplevel >/dev/null 2>&1 \
    && "$s" "$1" "$2" >/dev/null 2>&1
  return 0
}

case "${1:-}" in
  branch-for) shift; cmd_branch_for "$@" ;;
  resolve)    shift; cmd_resolve "$@" ;;
  track)      shift; cmd_track "$@" ;;
  *)          die "usage: write.sh branch-for <plan> | resolve <plan> [flag] | track <state> <plan>" ;;
esac
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-write/scripts/write.test.sh`
Expected: `15 passed, 0 failed`

- [x] **Step 5: Replace the prose with calls**

In `skills/iso-write/SKILL.md`, delete the five bash blocks at 31–35, 46–53,
78–93, 99–118 and 132–141, and replace the Step 2 body with:

```bash
eval "$(scripts/write.sh resolve "$plan_path" $workspace_flag)"
# now: $mode and $branch are set
```

and each tracking point with `scripts/write.sh track progress "$plan_path"`
(likewise `review`, `blocked`). Keep every paragraph explaining *why* a mode
behaves as it does — the branch-cut rationale, the stash-carry semantics, the
worktree isolation note. Prose keeps the reasoning; the script keeps the rules.

- [x] **Step 6: Confirm the prose shrank**

Run: `awk '/^```bash/{f=1;next} /^```$/{f=0} f' skills/iso-write/SKILL.md | wc -l`
Expected: 2 or fewer (only the `eval` line and the track call remain).

---

### Task 13: `iso-plan` gate and card arithmetic

22 lines of bash across the grill gate, the plan snapshot, and the two `open`
invocations.

**Files:**
- Create: `skills/iso-plan/scripts/plan.sh`
- Test: `skills/iso-plan/scripts/plan.test.sh`
- Modify: `skills/iso-plan/SKILL.md`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: `plan.sh gate` → `no-repo|setup-done|setup-missing`; `plan.sh newest` → newest plan path or empty; `plan.sh sub-gate <tasks> <scopes>` → exits 0 when sub-issues are warranted.

- [x] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/plan.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }
export ISO_GLOBAL_CONFIG=/nonexistent

echo "grill gate"
t=$(mktemp -d)
check "no repo"        "$( cd "$t" && bash "$SH" gate )" "no-repo"
( cd "$t" && git init -q -b main . )
check "setup missing"  "$( cd "$t" && bash "$SH" gate )" "setup-missing"
mkdir -p "$t/docs/agents" && touch "$t/docs/agents/domain.md"
check "setup done"     "$( cd "$t" && bash "$SH" gate )" "setup-done"

echo "newest plan"
mkdir -p "$t/docs/superpowers/plans"
check "no plans -> empty" "$( cd "$t" && bash "$SH" newest )" ""
touch "$t/docs/superpowers/plans/2026-01-01-feat-a.md"
sleep 1
touch "$t/docs/superpowers/plans/2026-01-02-feat-b.md"
check "newest wins" "$( cd "$t" && bash "$SH" newest )" "docs/superpowers/plans/2026-01-02-feat-b.md"

echo "sub-issue gate: >=8 tasks AND >=3 scopes"
bash "$SH" sub-gate 8 3; check "8 tasks 3 scopes opens"  "$?" "0"
bash "$SH" sub-gate 7 3; check "7 tasks stays shut"      "$?" "1"
bash "$SH" sub-gate 8 2; check "2 scopes stays shut"     "$?" "1"
bash "$SH" sub-gate 12 3; check "12 tasks 3 scopes opens" "$?" "0"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-plan/scripts/plan.test.sh`
Expected: FAIL — `plan.sh: No such file or directory`

- [x] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# iso-plan mechanics. The pipeline order and the summary card stay in SKILL.md;
# only the checks with one right answer live here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

die() { printf 'iso-plan: %s\n' "$1" >&2; exit 1; }

cmd_gate() {
  git rev-parse --git-dir >/dev/null 2>&1 || { printf 'no-repo\n'; return 0; }
  [ -f docs/agents/domain.md ] && printf 'setup-done\n' || printf 'setup-missing\n'
}

cmd_newest() {
  local dir; dir=$(iso_config_get paths.plans)
  ls -t "$dir"/*.md 2>/dev/null | head -1 || true
}

# Sub-issues show which parts of the app a plan touches. One per scope, never
# one per task — a 12-task plan across 3 scopes is 1 card and 3 sub-issues.
cmd_sub_gate() {
  [ "${1:-0}" -ge 8 ] && [ "${2:-0}" -ge 3 ]
}

case "${1:-}" in
  gate)     cmd_gate ;;
  newest)   cmd_newest ;;
  sub-gate) shift; cmd_sub_gate "$@" ;;
  *)        die "usage: plan.sh gate | newest | sub-gate <tasks> <scopes>" ;;
esac
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-plan/scripts/plan.test.sh`
Expected: `10 passed, 0 failed`

- [x] **Step 5: Replace the prose with calls**

In `skills/iso-plan/SKILL.md`, the gate block becomes `scripts/plan.sh gate`,
the two `ls -t` snapshots become `scripts/plan.sh newest`, and the sub-issue
gate paragraph cites `scripts/plan.sh sub-gate <tasks> <scopes>` as the rule.
The two `printf | "$S" open` examples stay — they are examples of a payload a
model composes, not a deterministic step.

---

### Task 14: `iso-init-repo` governance mechanics

The worst ratio in the repository: 137 of 491 SKILL.md lines are bash, against
44 lines of script.

**Files:**
- Create: `skills/iso-init-repo/scripts/init-repo.sh`
- Test: `skills/iso-init-repo/scripts/init-repo.test.sh`
- Modify: `skills/iso-init-repo/SKILL.md`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: `init-repo.sh branches` → the three branch names in integration/staging/production order; `init-repo.sh protection-json <branch>` → the `gh api` request body; `init-repo.sh default-branch` → the branch GitHub should serve as default.

- [x] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# ponytail: no network. Asserts the request bodies and the branch order, which
# is where a wrong value silently protects the wrong branch.
set -uo pipefail
SH="$(cd "$(dirname "$0")" && pwd)/init-repo.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       want=%q got=%q\n' "$3" "$2"; }; }

t=$(mktemp -d); ( cd "$t" && git init -q -b main . ); cd "$t" || exit 1
export ISO_GLOBAL_CONFIG=/nonexistent

echo "branch names"
check "default order" "$(bash "$SH" branches | tr '\n' ' ')" "dev test prod "
check "default branch defaults to integration" "$(bash "$SH" default-branch)" "dev"

echo "overlay wins"
mkdir -p docs/iso
printf '%s\n' '{"branches":{"default":"prod"}}' > docs/iso/config.json
check "overlay sets default branch" "$(bash "$SH" default-branch)" "prod"
check "branch list unaffected" "$(bash "$SH" branches | tr '\n' ' ')" "dev test prod "

echo "protection body"
out=$(bash "$SH" protection-json dev)
check "is valid json"       "$(printf '%s' "$out" | jq -r 'type')" "object"
check "requires a PR"       "$(printf '%s' "$out" | jq -r '.required_pull_request_reviews != null')" "true"
check "blocks force push"   "$(printf '%s' "$out" | jq -r '.allow_force_pushes')" "false"
check "blocks deletion"     "$(printf '%s' "$out" | jq -r '.allow_deletions')" "false"

out=$(bash "$SH" protection-json test)
check "staging requires the gate" \
  "$(printf '%s' "$out" | jq -r '.required_status_checks.contexts[0]')" "Verify Source Branch"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-init-repo/scripts/init-repo.test.sh`
Expected: FAIL — `init-repo.sh: No such file or directory`

- [x] **Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# iso-init-repo mechanics: branch names and protection request bodies.
# The narrative — why dev<-test<-prod, what the gate is for — stays in SKILL.md.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../../iso-config/scripts/lib/sibling.sh"
# shellcheck source=/dev/null
. "$(iso_sibling iso-config scripts/lib/config.sh)"

die() { printf 'iso-init-repo: %s\n' "$1" >&2; exit 1; }

cmd_branches() {
  iso_config_get branches.development
  iso_config_get branches.test
  iso_config_get branches.production
}

# What GitHub serves as the repository default. Distinct from the integration
# branch: a marketplace repository wants consumers cloning released work, so
# this repository sets it to `prod` in its overlay. Re-running init must read
# that, not overwrite it.
cmd_default_branch() {
  local d; d=$(iso_config_get branches.default)
  [ -n "$d" ] && printf '%s\n' "$d" || iso_config_get branches.development
}

cmd_protection_json() {
  local branch="$1" staging production contexts
  staging=$(iso_config_get branches.test)
  production=$(iso_config_get branches.production)
  case "$branch" in
    "$test_branch"|"$production") contexts='["Verify Source Branch"]' ;;
    *)                        contexts='[]' ;;
  esac
  jq -n --argjson c "$contexts" '{
    required_status_checks: { strict: true, contexts: $c },
    enforce_admins: false,
    required_pull_request_reviews: { required_approving_review_count: 0 },
    restrictions: null,
    allow_force_pushes: false,
    allow_deletions: false
  }'
}

case "${1:-}" in
  branches)        cmd_branches ;;
  default-branch)  cmd_default_branch ;;
  protection-json) shift; cmd_protection_json "$@" ;;
  *)               die "usage: init-repo.sh branches | default-branch | protection-json <branch>" ;;
esac
```

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-init-repo/scripts/init-repo.test.sh`
Expected: `9 passed, 0 failed`

- [x] **Step 5: Replace the prose with calls, and fix the default-branch bug**

In `skills/iso-init-repo/SKILL.md`, every hardcoded `dev`/`test`/`prod` becomes
a read from `scripts/init-repo.sh branches`, and each `gh api ... --input -`
call takes its body from `scripts/init-repo.sh protection-json <branch>`.

The step that sets the GitHub default branch becomes:

```bash
gh repo edit --default-branch "$(scripts/init-repo.sh default-branch)"
```

This is the fix for the recurring annoyance: re-running the skill used to reset
the default to `dev`, silently making `/plugin marketplace add IsaiaScope/ai`
serve unreleased daily work to every consumer. The value now comes from the
repository's own overlay, so re-running preserves it.

Add a short paragraph to SKILL.md recording that, because it is surprising:

> A repository whose default branch is not its integration branch is unusual
> but deliberate for a marketplace: `/plugin marketplace add` clones whatever
> GitHub reports as default, so consumers must land on released work. Set
> `branches.default` in the repository's overlay; this skill reads it rather
> than assuming.

- [x] **Step 6: Confirm the prose shrank**

Run: `awk '/^```bash/{f=1;next} /^```$/{f=0} f' skills/iso-init-repo/SKILL.md | wc -l`
Expected: fewer than 40 lines, down from 137.

---

### Task 15: `iso-ai-init` and `iso-readme`

The two remaining skills with prose bash: 7 lines and 3 lines respectively.

**Files:**
- Modify: `skills/iso-ai-init/SKILL.md`, `skills/iso-ai-init/templates/*.sh`
- Modify: `skills/iso-readme/SKILL.md`

**Interfaces:**
- Consumes: `iso_config_get`, `iso_sibling`.
- Produces: nothing new.

- [x] **Step 1: Identify what is actually deterministic**

Run: `awk '/^```bash/{f=1;print FILENAME":"NR;next} /^```$/{f=0} f' skills/iso-ai-init/SKILL.md skills/iso-readme/SKILL.md`
Expected: the fenced blocks, with line numbers.

- [x] **Step 2: Move what qualifies, leave what does not**

`iso-ai-init` already has `steps.json` and 517 lines of template scripts — its
few prose lines are invocation examples, which belong in prose. Leave them.

The templates hardcode `$HOME/.claude` and `$HOME/.codex` in seven places.
Replace each with an `iso_config_get agents.<kind>.sessions`-derived value where
the path refers to an agent's own directory, and leave the rest — a template
that writes `~/.claude/settings.json` is naming Claude Code's own file, not a
preference.

`iso-readme`'s three lines are a `git log` example. Leave them.

- [x] **Step 3: Verify nothing regressed**

Run: `node scripts/install.js && bash skills/iso-spawn/tests/run.sh`
Expected: install succeeds, spawn suite passes.

---

## Phase 6 — Cutover

### Task 16: Sidecars record `~`, not the expanded home path

Task 7 made run artifacts tracked in a public repository. A spawn sidecar
currently records eight absolute `/Users/<name>/.codex/sessions/...` lines plus
the working directory. The information is worth keeping; the home path is not.

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh`
- Modify: `skills/iso-spawn/scripts/lib/transcript.sh`
- Modify: `skills/iso-spawn/tests/run.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `iso_tildify <path>` in `transcript.sh` — replaces a leading `$HOME` with `~`.

- [x] **Step 1: Write the failing test**

Append to `skills/iso-spawn/tests/run.sh`:

```bash
echo "sidecar home redaction"
check "home becomes tilde" "$(HOME=/Users/x bash -c ". $TRANSCRIPT; iso_tildify /Users/x/.codex/sessions/a.jsonl")" \
  "~/.codex/sessions/a.jsonl"
check "other paths untouched" "$(HOME=/Users/x bash -c ". $TRANSCRIPT; iso_tildify /tmp/a.jsonl")" "/tmp/a.jsonl"
check "home as substring untouched" "$(HOME=/Users/x bash -c ". $TRANSCRIPT; iso_tildify /Users/xyz/a")" "/Users/xyz/a"
```

- [x] **Step 2: Run test to verify it fails**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: FAIL — `iso_tildify: command not found`

- [x] **Step 3: Write minimal implementation**

Add to `transcript.sh`:

```bash
# Sidecars are tracked in git, so they must not carry the author's home path.
# ponytail: leading-$HOME only. A path with $HOME in the middle is not a case
# that occurs here, and matching it would risk mangling ordinary strings.
iso_tildify() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    "$HOME")   printf '~' ;;
    *)         printf '%s' "$1" ;;
  esac
}
```

Then wrap every `pre=`, `post=` and `cwd=` value written into the sidecar in
`spawn.sh` with `iso_tildify`. Readers that consume those values expand `~`
back with `${v/#\~/$HOME}`.

- [x] **Step 4: Run test to verify it passes**

Run: `bash skills/iso-spawn/tests/run.sh`
Expected: all assertions pass, including the three new ones.

- [x] **Step 5: Confirm no home path survives in tracked artifacts**

Run: `grep -rn "$HOME" docs/iso/ 2>/dev/null || echo "clean"`
Expected: `clean`. Any pre-existing sidecar that still carries an absolute path was written before this change — rewrite it with the same substitution or delete it.

---

### Task 17: Write the live configs and prove the sweep passes

A config-reading sweep that leaves no config behind is untestable by
definition. This task is what makes the previous sixteen real.

**Files:**
- Create: `~/.config/iso/iso.json` (outside the repository)
- Create: `docs/iso/config.json`

- [x] **Step 1: Write the global scope**

Run: `bash skills/iso-config/scripts/config.sh init`
Expected: `wrote /Users/<you>/.config/iso/iso.json`.

The seeded defaults already match this machine — `multica`, `herdr`,
`IsaiaScope`, `marketonfire` — so no edit should be needed. Confirm with
`bash skills/iso-config/scripts/config.sh show`.

- [x] **Step 2: Write this repository's overlay**

```bash
mkdir -p docs/iso
cat > docs/iso/config.json <<'JSON'
{
  "branches": {
    "default": "prod",
    "pr_base": "dev"
  }
}
JSON
```

Two keys, because two values differ from global. `default` is `prod` so
`/plugin marketplace add IsaiaScope/ai` serves released work; `pr_base` stays
`dev` because the branch gate rejects a PR into `prod` that did not come from
`test`.

- [x] **Step 3: Verify the merge resolves as intended**

Run:
```bash
bash skills/iso-config/scripts/config.sh show
bash skills/iso-config/scripts/plan.sh gate 2>/dev/null || true
```
Expected: `show` lists both scope files as present, and the merged document has
`branches.default = "prod"` while `branches.development` is still `"dev"`.

- [x] **Step 4: Run doctor**

Run: `bash skills/iso-config/scripts/config.sh doctor`
Expected: one `ok` line per prerequisite and `ready (prerequisite list v1)`.

If `herdr` reports `BLOCKED`, that is the design working — it is the one
prerequisite with no install path.

- [x] **Step 5: Run every suite**

Run:
```bash
for t in $(find skills -name '*.test.sh' | sort); do
  printf '== %s\n' "$t"; bash "$t" >/dev/null || printf 'FAILED %s\n' "$t"
done
bash skills/iso-spawn/tests/run.sh >/dev/null || echo "FAILED spawn"
```
Expected: no `FAILED` line.

- [x] **Step 6: Prove the Codex install claim**

Run: `node scripts/install.js && ls ~/.codex/skills/ | grep -c '^iso-'`
Expected: 12 (the eleven existing skills plus `iso-config`). ADR-0004 records
that this directory was empty while `CLAUDE.md` claimed both agents were
linked; this is where that gets confirmed fixed or filed as still broken.

---

### Task 18: Record what stays prose

Two pieces of repeated guidance do not belong in config, and one document is
now out of date.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `config/CLAUDE.md`

- [x] **Step 1: Update the architecture map**

`CLAUDE.md`'s `## Architecture` tree lists nine skills and no `iso-config`. Add:

```
  iso-config/SKILL.md              — the Iso config every iso-* skill reads
```

and add a line to the `## Adding a Skill` section noting that a skill needing
config sources `iso-config/scripts/lib/config.sh` through `iso_sibling`, never
through an absolute `$HOME` path.

- [x] **Step 2: Record the push rule where rules live**

Add to `config/CLAUDE.md`:

```markdown
## Pushing

Every push in a repository under `/iso-init-repo` governance goes through
`/iso-push`, adapting the invocation to the situation. Never fall back to a raw
`git push`: the integration, staging and production branches are PR-only, so a
direct push is either rejected or lands work that skipped CI and the branch
gate. The skill also owns the `<branch>:refs/heads/<branch>` refspec that stops
an upstream of `origin/dev` from landing a feature branch on the wrong branch,
and the rebase and force-push gating.

When the situation does not fit the documented flow, change the invocation —
not the tool.
```

This is a habit, not data: there is no value to encode and nothing for a script
to read. It belongs in prose, unlike the default-branch fact, which moved into
the overlay in Task 14.

- [x] **Step 3: Deploy and confirm**

Run: `node scripts/install.js && diff ~/CLAUDE.md config/CLAUDE.md && echo "deployed"`
Expected: `deployed`.

- [x] **Step 4: Refresh the knowledge graph**

Run: `graphify update .`
Expected: completes without error. The structural graph now includes
`iso-config` and the new script files.

---

## Done when

- `bash skills/iso-config/scripts/config.sh doctor` prints `ready (prerequisite list v1)`.
- `grep -rn 'HOME/.claude/skills' skills/` returns nothing.
- No `.iso/` reference survives outside `docs/iso/`.
- Every `*.test.sh` and `skills/iso-spawn/tests/run.sh` passes, including
  `skills/iso-tracking/scripts/adapters/contract.test.sh`.
- `grep -c '\bmultica\b' skills/iso-tracking/scripts/tracking.sh` is 0 — the
  vendor's name survives only in `adapters/multica.sh`.
- `skills/iso-tracking/scripts/tracking.test.sh` still reports 142 passed: the
  rename and the split changed structure, not behaviour.
- With `tracker.kind` set to `none`, every tracking subcommand exits 0 silently.
- `awk '/^```bash/{f=1;next} /^```$/{f=0} f' skills/iso-*/SKILL.md | wc -l` is under 60, down from roughly 270.
- `ls ~/.codex/skills | grep -c '^iso-'` is 12, or the discrepancy is filed as an issue.

## Implementation Log
- Implemented: 2026-08-21T11:06:57Z
- Workspace: current-branch — refactor/multica-tracking-shape
- Committed: no — awaiting user review

### Departures from the plan as written

**Post-implementation change (same working tree).** Sub-issues were removed
after the plan ran: `tk_issue_children` left the 14-verb contract (now 13),
`--sub`/`--parent`/`--stage` left `open`, and the `---8<---` stdin splitter is
gone. One plan is one card. Two defects surfaced doing it — `STATE` had gained
a `/$TRACKER_KIND` suffix that orphaned the live ledger (so every transition
logged "no card for plan" against an empty file it had just created), and a
missed transition was silent; it now warns on stderr.

A third fell out later: the `SessionStart`/`SessionEnd` hooks in
`~/.claude/settings.json` still named `iso-multica-tracking/scripts/multica-session.sh`,
so `reconcile` and `end` had been silent no-ops since the rename. `install.js`
manages skill symlinks but not hook commands, and nothing else checks them.
Closed by making `install.js` own them: `scripts/agent-hooks.js` writes both
entries into `~/.claude/settings.json`, keyed by a `# iso-hook:<name>` marker
rather than by path — matching on the path is what made the renamed hook
invisible instead of stale. `doctor` now warns (never fails, matching the
topology check) when a marked hook is missing or its target is not executable.

An architecture pass afterwards closed the prose-extraction shortfall this plan
records below: `iso-init-repo`'s SKILL.md went 128 -> 68 bash lines (total across
skills 238 -> 181) by growing `init-repo.sh` from 3 verbs to 9 —
`create-branches`, `retire-main`, `gate-status`, `gate-context`, `install-hook`,
`verify-hook`. Suite 15 -> 34. What stays in prose is what a test genuinely
cannot reach: `gh repo create`, `gh auth status`, `brew install`, and the
protection PUTs. The same pass added `scripts/dispatch-integrity.test.sh`, which
immediately found `push.sh` dispatching `method)` to a `cmd_method` that was
never defined — dead interface a 125-assertion suite could not see.

Also added: `card-for-branch` and `replan`, so a second plan for work already
carded lands on the same card and sends it back to `todo`. Needed one new
adapter verb, `tk_issue_describe` (contract now 15).
- **Task 9 contract is fourteen verbs, not thirteen.** `tk_project_create` was
  missing (built via a bash array, so a verb-surface grep skipped it),
  `tk_label_create` also needs a colour, `tk_property_create` also needs a type,
  and `tk_auth_ok` was replaced by `tk_current_user` — the verb the code
  actually calls. List verbs return normalised `<id>\t<name>` lines rather than
  raw vendor JSON, so a second adapter never has to imitate multica's shape.
- **Task 7's rewrite regex missed seven sites.** The look-behind `(?<![\w/.])`
  was meant to protect `docs/.iso/`, but it also skipped `\n.iso/`, `$CWD/.iso/`
  and `./.iso/` — including live code in `spawn.sh` and a `drive.sh` line left
  checking one path while writing another. Step 4's verification shared the same
  look-behind, so it reported clean. Fixed and re-verified with a plain grep.
- **`branches.default` now defaults to null.** Shipped as `"dev"` it made the
  plan's own fallback dead code, so renaming the development branch left GitHub's
  default pointing at a branch that no longer existed.
- **`protection-json` emits `required_status_checks: null`** for the development
  branch and `strict:false` for the gated ones, matching the body the skill has
  always PUT. The plan's `{strict:true, contexts:[]}` was not equivalent.
- **The no-start invariant was retargeted.** After the split it grepped a file
  that no longer contains the string and passed vacuously; it now greps the
  adapter and asserts non-emptiness first. Verified by mutation. Suite is 143,
  not 142.
- **A pre-existing flake was fixed.** `setversion` in `push.test.sh` relied on
  two commits hashing identically, which only holds when both land inside one
  wall-clock second. Dates are now pinned.
- **`install.js` prunes dangling agent-side links.** The rename left
  `iso-multica-tracking` behind in both agent dirs, making `doctor` miscount.
- **Perf:** `iso_config` is memoized per scope pair; without it a script reading
  five keys spawned twenty jq processes.

### Not delivered
- **Prose extraction fell well short.** Target was under 60 lines of bash across
  `skills/iso-*/SKILL.md`; the result is 238, down from ~270. `iso-init-repo`
  alone holds 128 of them, and they are `gh`/`git`/`brew` orchestration with
  network side effects — the plan's own test constraint for that task was "no
  network", so extracting them would produce a large untested script. The
  decidable parts (branch names, protection bodies, default-branch) did move.

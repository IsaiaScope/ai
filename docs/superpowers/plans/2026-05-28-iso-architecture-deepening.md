# iso Architecture Deepening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **NO COMMITS.** The user reviews all changes manually at the end. Every "Checkpoint" step runs the tests only — do **not** `git add`/`git commit`/`git push` at any point.

**Goal:** Deepen three shallow spots in the IsaiaScope/ai skills repo: (B) give the `.spawn` sidecar a reader so its `key=value` encoding stops leaking, (A) give the codex/claude **Agent kind** distinction one home, and (C) make the filesystem the single source of truth for the skill set.

**Architecture:** Three independent deepenings sharing the iso-spawn module set. **B** adds two accessors to `transcript.sh` and routes all 8 ad-hoc `grep '^k='` sites through them. **A** adds `lib/agentkind.sh` holding every per-kind fact (transcript root/glob/slug, full-perm argv, tab label, normalize) as fact-major bash functions; `transcript.sh`/`spawn.sh`/`deliver.sh` consume it; `recover.py`'s parser dispatch stays. **C** extracts the skill registry into a pure `scripts/skills-manifest.js` module that scans `skills/*/SKILL.md`; `install.js` requires it to drive symlinks and regenerate `plugin.json`.

**Tech Stack:** Bash 3.2-compatible shell (no associative arrays), Python 3 (recover.py only, unchanged), Node 24 (`node --test` for the manifest module). Tests: `skills/iso-spawn/tests/run.sh` (pure bash) and a new `scripts/skills-manifest.test.js`.

**Sequence:** B → A → C. A builds on B (both touch `transcript.sh`/`deliver.sh`/`spawn.sh`); C is independent.

---

## Phase B — Sidecar reader

The `.spawn` sidecar is written by `transcript_write_meta` but read by 8 inline `grep '^k=' | head -1 | cut -d= -f2-` snippets across `spawn.sh`, `deliver.sh`, `cleanup.sh`. Add two accessors so the `key=value` format lives only in `transcript.sh`.

### Task B1: Add the meta accessors

**Files:**
- Modify: `skills/iso-spawn/scripts/lib/transcript.sh` (add after `transcript_write_meta`, around line 66)
- Test: `skills/iso-spawn/tests/run.sh` (new block before `exit $fail`)

- [ ] **Step 1: Write the failing test**

Add this block in `skills/iso-spawn/tests/run.sh` immediately before the final `exit $fail` line:

```bash
# --- Sidecar meta accessors: first value, all values, missing key ---
. "$HERE/../scripts/lib/agentkind.sh" 2>/dev/null || true
. "$HERE/../scripts/lib/transcript.sh"
TMP=$(mktemp -d)
SF="$TMP/x.spawn"
{ echo "[meta]"; echo "term=term_ABC"; echo "agent=claude"; echo "cwd=/repo/app"; \
  echo "pre=/a/one.jsonl"; echo "pre=/a/two.jsonl"; } > "$SF"
assert_eq "meta_get returns the value"            "$(transcript_meta_get "$SF" term)"   "term_ABC"
assert_eq "meta_get returns first when repeated"  "$(transcript_meta_get "$SF" pre)"    "/a/one.jsonl"
assert_eq "meta_get_all returns every value"      "$(transcript_meta_get_all "$SF" pre | tr '\n' ',')" "/a/one.jsonl,/a/two.jsonl,"
assert_eq "meta_get missing key is empty"         "$(transcript_meta_get "$SF" nope)"   ""
mg_rc=0; transcript_meta_get "$TMP/missing.spawn" term >/dev/null 2>&1 || mg_rc=$?
assert_eq "meta_get missing file exits 0"         "$mg_rc"                               "0"
rm -rf "$TMP"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/iso-spawn/tests/run.sh 2>&1 | grep -E 'meta_get|FAIL'`
Expected: FAIL lines for the `meta_get`/`meta_get_all` assertions (functions not defined yet → empty output, mismatches).

- [ ] **Step 3: Add the accessors**

In `skills/iso-spawn/scripts/lib/transcript.sh`, add immediately after the closing `}` of `transcript_write_meta` (currently line 66):

```bash
# Read the FIRST value for KEY from a .spawn meta block. Empty + rc 0 when the key or
# file is absent (never aborts a `set -e` caller — matches the guarded herdr.sh style).
transcript_meta_get() { # $1=spawnfile $2=key
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d= -f2- || true
}

# Read EVERY value for KEY, newline-joined. For multi-value keys like `pre`.
transcript_meta_get_all() { # $1=spawnfile $2=key
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-spawn/tests/run.sh 2>&1 | grep -E 'meta_get'`
Expected: all 5 `ok:` lines.

- [ ] **Step 5: Checkpoint (no commit)**

Run: `bash skills/iso-spawn/tests/run.sh >/dev/null 2>&1; echo "exit=$?"`
Expected: `exit=0` (whole suite still green). Do not commit.

### Task B2: Route the 8 read sites through the accessors

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh:126-130`
- Modify: `skills/iso-spawn/scripts/lib/deliver.sh:41-43`
- Modify: `skills/iso-spawn/scripts/lib/cleanup.sh:31`

- [ ] **Step 1: Replace the spawn.sh recover-path greps**

In `skills/iso-spawn/scripts/spawn.sh`, replace lines 126-130:

```bash
      RAGENT=$(grep '^agent=' "$SF" | head -1 | cut -d= -f2-)
      case "$RAGENT" in claude*) RAGENT=claude;; *) RAGENT=codex;; esac
      RSESS=$(grep '^session_file=' "$SF" | head -1 | cut -d= -f2- || true)
      M_CWD=$(grep '^cwd=' "$SF" | head -1 | cut -d= -f2- || true)
      M_PRE=$(grep '^pre=' "$SF" | cut -d= -f2- || true)
```

with:

```bash
      RAGENT=$(transcript_meta_get "$SF" agent)
      case "$RAGENT" in claude*) RAGENT=claude;; *) RAGENT=codex;; esac
      RSESS=$(transcript_meta_get "$SF" session_file)
      M_CWD=$(transcript_meta_get "$SF" cwd)
      M_PRE=$(transcript_meta_get_all "$SF" pre)
```

(The `case` normalization stays for now — Task A2 replaces it with `agentkind_normalize`.)

- [ ] **Step 2: Replace the deliver.sh greps**

In `skills/iso-spawn/scripts/lib/deliver.sh`, replace lines 41-43:

```bash
    m_agent=$(grep '^agent=' "$SPAWNFILE" | head -1 | cut -d= -f2- || true)
    m_cwd=$(grep '^cwd=' "$SPAWNFILE" | head -1 | cut -d= -f2- || true)
    m_pre=$(grep '^pre=' "$SPAWNFILE" | cut -d= -f2- || true)
```

with:

```bash
    m_agent=$(transcript_meta_get "$SPAWNFILE" agent)
    m_cwd=$(transcript_meta_get "$SPAWNFILE" cwd)
    m_pre=$(transcript_meta_get_all "$SPAWNFILE" pre)
```

- [ ] **Step 3: Replace the cleanup.sh grep (keep the filename fallback)**

In `skills/iso-spawn/scripts/lib/cleanup.sh`, replace line 31:

```bash
      term=$(grep '^term=' "$f" | head -1 | cut -d= -f2- || true)
```

with:

```bash
      term=$(transcript_meta_get "$f" term)
```

The next line (`[ -n "$term" ] || term="${f##*__}"; term="${term%.spawn}"`) is unchanged — that filename fallback is orphan-recovery logic, not format-reading.

- [ ] **Step 4: Run the full suite**

Run: `bash skills/iso-spawn/tests/run.sh >/dev/null 2>&1; echo "exit=$?"`
Expected: `exit=0`. The existing recover/sidecar/orphan tests cover these call sites.

- [ ] **Step 5: Checkpoint (no commit)**

Confirm `grep -rn "grep '\^" skills/iso-spawn/scripts` returns **no** sidecar-meta greps (only non-meta greps, if any). Do not commit.

---

## Phase A — Agent kind has a home

Add `lib/agentkind.sh` holding every fact that differs by **Agent kind** (codex | claude). Fact-major bash functions, 3.2-safe. `transcript.sh`/`spawn.sh`/`deliver.sh` consume it; `recover.py` keeps its own `codex_turns`/`claude_turns` dispatch.

### Task A1: Create lib/agentkind.sh

**Files:**
- Create: `skills/iso-spawn/scripts/lib/agentkind.sh`
- Test: `skills/iso-spawn/tests/run.sh` (new block before `exit $fail`)

- [ ] **Step 1: Write the failing test**

Add this block in `skills/iso-spawn/tests/run.sh` immediately before the final `exit $fail`:

```bash
# --- Agent kind profile: one home for the codex|claude differences ---
. "$HERE/../scripts/lib/agentkind.sh"
assert_eq "normalize codex"        "$(agentkind_normalize codex)"        "codex"
assert_eq "normalize claude"       "$(agentkind_normalize claude)"       "claude"
assert_eq "normalize claude-code"  "$(agentkind_normalize claude-code)"  "claude"
assert_eq "normalize unknown->codex" "$(agentkind_normalize whatever)"   "codex"
assert_eq "label codex"            "$(agentkind_label codex)"            "codex"
assert_eq "label claude"           "$(agentkind_label claude)"           "claude-code"
assert_eq "perm_argv codex"        "$(agentkind_perm_argv codex)"        "--dangerously-bypass-approvals-and-sandbox"
assert_eq "perm_argv claude"       "$(agentkind_perm_argv claude)"       "--dangerously-skip-permissions"
assert_eq "glob codex"             "$(agentkind_glob codex)"             "rollout-*.jsonl"
assert_eq "glob claude"            "$(agentkind_glob claude)"            "*.jsonl"
assert_eq "slug_needed claude"     "$(agentkind_slug_needed claude)"     "1"
assert_eq "slug_needed codex"      "$(agentkind_slug_needed codex)"      ""
assert_eq "root codex honors env"  "$(ISO_CODEX_SESS=/tmp/cx agentkind_root codex)"   "/tmp/cx"
assert_eq "root claude honors env" "$(ISO_CLAUDE_PROJ=/tmp/cl agentkind_root claude)" "/tmp/cl"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/iso-spawn/tests/run.sh 2>&1 | grep -E 'normalize|label|perm_argv|glob|slug_needed|root '`
Expected: FAILs (file/functions not defined).

- [ ] **Step 3: Create the module**

Create `skills/iso-spawn/scripts/lib/agentkind.sh`:

```bash
#!/usr/bin/env bash
# agentkind.sh — the facts that differ by Agent kind (codex | claude): transcript layout,
# full-permission flag, tab label. One home so callers ask instead of re-branching on type.
# Pure constants + normalize; bash 3.2-safe (no associative arrays). Assumes pipefail.

# Normalize a raw type/agent string to the canonical kind.
agentkind_normalize() { case "$1" in claude*) echo claude;; *) echo codex;; esac; }

# Root dir holding this kind's native JSONL transcripts (env-overridable for tests).
agentkind_root() { # $1=kind
  case "$(agentkind_normalize "$1")" in
    claude) printf '%s' "${ISO_CLAUDE_PROJ:-$HOME/.claude/projects}";;
    *)      printf '%s' "${ISO_CODEX_SESS:-$HOME/.codex/sessions}";;
  esac
}

# Glob matching this kind's transcript files within its (sub)dir.
agentkind_glob() { # $1=kind
  case "$(agentkind_normalize "$1")" in
    claude) printf '%s' '*.jsonl';;
    *)      printf '%s' 'rollout-*.jsonl';;
  esac
}

# "1" when this kind keys its transcript dir by a cwd slug (claude, flat dir); "" otherwise
# (codex, date-nested dir searched recursively).
agentkind_slug_needed() { # $1=kind
  case "$(agentkind_normalize "$1")" in claude) printf '%s' 1;; *) printf '%s' '';; esac
}

# herdr tab label / sidecar agent label for this kind.
agentkind_label() { # $1=kind
  case "$(agentkind_normalize "$1")" in claude) printf '%s' 'claude-code';; *) printf '%s' 'codex';; esac
}

# argv fragment enabling full permissions for this kind. Single token (caller word-splits safely).
agentkind_perm_argv() { # $1=kind
  case "$(agentkind_normalize "$1")" in
    claude) printf '%s' '--dangerously-skip-permissions';;
    *)      printf '%s' '--dangerously-bypass-approvals-and-sandbox';;
  esac
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/iso-spawn/tests/run.sh 2>&1 | grep -E 'normalize|label|perm_argv|glob|slug_needed|root '`
Expected: all `ok:`.

- [ ] **Step 5: Checkpoint (no commit)**

Run: `bash -n skills/iso-spawn/scripts/lib/agentkind.sh && echo "syntax ok"`
Expected: `syntax ok`. Do not commit.

### Task A2: Source agentkind first; route spawn.sh + deliver.sh through it

**Files:**
- Modify: `skills/iso-spawn/scripts/spawn.sh:10-14` (source order), `:127`, `:197-200`, `:237`
- Modify: `skills/iso-spawn/scripts/lib/deliver.sh:44`
- Modify: `skills/iso-spawn/tests/run.sh:120,148,166` (source agentkind before transcript)

- [ ] **Step 1: Source agentkind.sh first in spawn.sh**

In `skills/iso-spawn/scripts/spawn.sh`, replace lines 10-14:

```bash
LIBDIR="$SELFDIR/lib"
. "$LIBDIR/transcript.sh"
. "$LIBDIR/herdr.sh"
. "$LIBDIR/deliver.sh"
. "$LIBDIR/cleanup.sh"
```

with:

```bash
LIBDIR="$SELFDIR/lib"
. "$LIBDIR/agentkind.sh"
. "$LIBDIR/transcript.sh"
. "$LIBDIR/herdr.sh"
. "$LIBDIR/deliver.sh"
. "$LIBDIR/cleanup.sh"
```

- [ ] **Step 2: Replace spawn.sh recover-path normalization (line 127)**

Replace:

```bash
      case "$RAGENT" in claude*) RAGENT=claude;; *) RAGENT=codex;; esac
```

with:

```bash
      RAGENT=$(agentkind_normalize "$RAGENT")
```

- [ ] **Step 3: Replace spawn.sh full-perm argv (lines 197-200)**

Replace:

```bash
ARGV=("$TYPE")
if [ "$FULL" = 1 ]; then
  [ "$TYPE" = codex ]  && ARGV+=(--dangerously-bypass-approvals-and-sandbox)
  [ "$TYPE" = claude ] && ARGV+=(--dangerously-skip-permissions)
fi
```

with:

```bash
ARGV=("$TYPE")
[ "$FULL" = 1 ] && ARGV+=("$(agentkind_perm_argv "$TYPE")")
```

- [ ] **Step 4: Replace spawn.sh tab label (line 237)**

Replace:

```bash
[ "$TYPE" = claude ] && AGENTLABEL=claude-code || AGENTLABEL=codex
```

with:

```bash
AGENTLABEL=$(agentkind_label "$TYPE")
```

- [ ] **Step 5: Replace deliver.sh normalization (line 44)**

In `skills/iso-spawn/scripts/lib/deliver.sh`, replace:

```bash
    case "$m_agent" in claude*) a=claude;; *) a=codex;; esac
```

with:

```bash
    a=$(agentkind_normalize "$m_agent")
```

- [ ] **Step 6: Make the test runner source agentkind before transcript**

In `skills/iso-spawn/tests/run.sh`, the three lines that source `transcript.sh` (120, 148, 166) must source `agentkind.sh` first, because `transcript.sh` will call `agentkind_*` after Task A3.

Line 120 — replace:

```bash
. "$HERE/../scripts/lib/transcript.sh"; . "$HERE/../scripts/lib/herdr.sh"; . "$HERE/../scripts/lib/cleanup.sh"
```

with:

```bash
. "$HERE/../scripts/lib/agentkind.sh"; . "$HERE/../scripts/lib/transcript.sh"; . "$HERE/../scripts/lib/herdr.sh"; . "$HERE/../scripts/lib/cleanup.sh"
```

Line 148 — replace:

```bash
. "$HERE/../scripts/lib/transcript.sh"
```

with:

```bash
. "$HERE/../scripts/lib/agentkind.sh"; . "$HERE/../scripts/lib/transcript.sh"
```

Line 166 — replace:

```bash
  . "$HERE/../scripts/lib/transcript.sh"
```

with:

```bash
  . "$HERE/../scripts/lib/agentkind.sh"; . "$HERE/../scripts/lib/transcript.sh"
```

(The B1/A1 test blocks already source `agentkind.sh` explicitly, so they are unaffected.)

- [ ] **Step 7: Run the full suite**

Run: `bash skills/iso-spawn/tests/run.sh >/dev/null 2>&1; echo "exit=$?"`
Expected: `exit=0`. The existing env-test ("spawn preserves exported TERM") and the `--wait --recover` tests exercise the argv/label/normalize paths.

- [ ] **Step 8: Checkpoint (no commit)**

Run: `grep -rnE '= codex|= claude|claude\*\)|dangerously' skills/iso-spawn/scripts/spawn.sh skills/iso-spawn/scripts/lib/deliver.sh`
Expected: only the argument-validation line (`case "$TYPE" in codex|claude)`) and the bare-alias line remain — no per-kind fact branching. Do not commit.

### Task A3: Route transcript.sh through agentkind

**Files:**
- Modify: `skills/iso-spawn/scripts/lib/transcript.sh:35-43` (`transcript_candidate_set`), `:61` (slug gate in `transcript_write_meta`)

- [ ] **Step 1: Rewrite transcript_candidate_set to consult agentkind**

In `skills/iso-spawn/scripts/lib/transcript.sh`, replace `transcript_candidate_set` (lines 34-43):

```bash
# Print the current candidate transcript files for an agent+cwd, one per line, sorted.
transcript_candidate_set() { # $1=codex|claude  $2=cwd
  case "$1" in
    codex)
      find "${ISO_CODEX_SESS:-$HOME/.codex/sessions}" -name 'rollout-*.jsonl' 2>/dev/null | sort ;;
    claude*)
      local d="${ISO_CLAUDE_PROJ:-$HOME/.claude/projects}/$(transcript_slug "$2")"
      find "$d" -maxdepth 1 -name '*.jsonl' 2>/dev/null | sort ;;
  esac
}
```

with:

```bash
# Print the current candidate transcript files for an agent+cwd, one per line, sorted.
# Layout differs by Agent kind: claude keys a flat per-cwd slug dir (maxdepth 1); codex
# searches its date-nested sessions root recursively.
transcript_candidate_set() { # $1=codex|claude  $2=cwd
  local kind root glob d
  kind=$(agentkind_normalize "$1")
  root=$(agentkind_root "$kind")
  glob=$(agentkind_glob "$kind")
  if [ -n "$(agentkind_slug_needed "$kind")" ]; then
    d="$root/$(transcript_slug "$2")"
    find "$d" -maxdepth 1 -name "$glob" 2>/dev/null | sort
  else
    find "$root" -name "$glob" 2>/dev/null | sort
  fi
}
```

- [ ] **Step 2: Replace the slug gate in transcript_write_meta (line 61)**

Replace:

```bash
    [ "$3" = claude ] && echo "slug=$(transcript_slug "$4")"
```

with:

```bash
    [ -n "$(agentkind_slug_needed "$3")" ] && echo "slug=$(transcript_slug "$4")"
```

- [ ] **Step 3: Run the full suite**

Run: `bash skills/iso-spawn/tests/run.sh >/dev/null 2>&1; echo "exit=$?"`
Expected: `exit=0`. The candidate-set / diff-new / fingerprint tests (codex and claude) and the `meta has term`/slug tests cover both branches.

- [ ] **Step 4: Confirm no per-kind facts remain in transcript.sh**

Run: `grep -nE 'codex|claude|rollout-|\.codex/sessions|\.claude/projects' skills/iso-spawn/scripts/lib/transcript.sh`
Expected: only the comment lines — no literal roots/globs/kind branches in code.

- [ ] **Step 5: Checkpoint (no commit)**

Run: `bash skills/iso-spawn/tests/run.sh 2>&1 | grep -c '^FAIL'`
Expected: `0`. Do not commit.

---

## Phase C — Filesystem is the single source of truth for the skill set

The skill list is duplicated across `plugin.json.skills`, `install.js`'s `localSkills`, and a CLAUDE.md ritual. Extract a pure `scripts/skills-manifest.js` that scans `skills/*/SKILL.md`; `install.js` requires it to drive symlinks and regenerate `plugin.json`.

### Task C1: Create the pure skills-manifest module

**Files:**
- Create: `scripts/skills-manifest.js`
- Test: `scripts/skills-manifest.test.js`

- [ ] **Step 1: Write the failing test**

Create `scripts/skills-manifest.test.js`:

```js
const assert = require("node:assert");
const { test } = require("node:test");
const { mkdtempSync, mkdirSync, writeFileSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { tmpdir } = require("node:os");
const { scanSkills, syncManifest } = require("./skills-manifest");

function fixtureRepo() {
  const root = mkdtempSync(join(tmpdir(), "iso-manifest-"));
  const skills = join(root, "skills");
  for (const name of ["beta", "alpha"]) {
    mkdirSync(join(skills, name), { recursive: true });
    writeFileSync(join(skills, name, "SKILL.md"), `# ${name}\n`);
  }
  // a directory WITHOUT SKILL.md must be ignored
  mkdirSync(join(skills, "draft"), { recursive: true });
  return root;
}

test("scanSkills returns sorted dirs that contain SKILL.md", () => {
  const root = fixtureRepo();
  assert.deepStrictEqual(scanSkills(join(root, "skills")), ["alpha", "beta"]);
});

test("syncManifest writes sorted ./skills paths and preserves other keys", () => {
  const root = fixtureRepo();
  const pluginPath = join(root, "plugin.json");
  writeFileSync(pluginPath, JSON.stringify({ name: "x", skills: [] }, null, 2) + "\n");
  const first = syncManifest(pluginPath, ["alpha", "beta"]);
  assert.strictEqual(first.changed, true);
  const written = JSON.parse(readFileSync(pluginPath, "utf8"));
  assert.strictEqual(written.name, "x");
  assert.deepStrictEqual(written.skills, ["./skills/alpha", "./skills/beta"]);
});

test("syncManifest is idempotent: no change on a synced manifest", () => {
  const root = fixtureRepo();
  const pluginPath = join(root, "plugin.json");
  writeFileSync(pluginPath, JSON.stringify({ name: "x", skills: [] }, null, 2) + "\n");
  syncManifest(pluginPath, ["alpha", "beta"]);
  const second = syncManifest(pluginPath, ["alpha", "beta"]);
  assert.strictEqual(second.changed, false);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test scripts/skills-manifest.test.js`
Expected: FAIL — `Cannot find module './skills-manifest'`.

- [ ] **Step 3: Create the module**

Create `scripts/skills-manifest.js`:

```js
"use strict";
const { readdirSync, existsSync, readFileSync, writeFileSync } = require("fs");
const { join } = require("path");

// The skill set is the filesystem: every skills/<name>/ that contains a SKILL.md.
// Returns the sorted directory names.
function scanSkills(skillsRoot) {
  return readdirSync(skillsRoot, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(skillsRoot, e.name, "SKILL.md")))
    .map((e) => e.name)
    .sort();
}

// Rewrite ONLY plugin.json's `skills` array from the scanned names (as ./skills/<name>),
// preserving every other key. Writes only when the array actually changed.
// Returns { changed, skills }.
function syncManifest(pluginPath, skillNames) {
  const plugin = JSON.parse(readFileSync(pluginPath, "utf8"));
  const next = skillNames.map((n) => `./skills/${n}`);
  const changed = JSON.stringify(plugin.skills) !== JSON.stringify(next);
  if (changed) {
    plugin.skills = next;
    writeFileSync(pluginPath, JSON.stringify(plugin, null, 2) + "\n");
  }
  return { changed, skills: next };
}

module.exports = { scanSkills, syncManifest };
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test scripts/skills-manifest.test.js`
Expected: `pass 3`.

- [ ] **Step 5: Checkpoint (no commit)**

Run: `node --test scripts/skills-manifest.test.js 2>&1 | tail -3`
Expected: `pass 3`, `fail 0`. Do not commit.

### Task C2: Wire install.js to the scan; delete localSkills

**Files:**
- Modify: `scripts/install.js:4` (requires), `:44-53` (delete `localSkills` literal, derive it), add a plugin.json regen call after the symlink loop (~`:89`)
- Modify: `.claude-plugin/plugin.json` (regenerated by running install — content is identical to today, so no manual edit)
- Modify: `CLAUDE.md` ("Adding a Skill" + Architecture/install text)

- [ ] **Step 1: Add the imports and require the module**

In `scripts/install.js`, replace line 4:

```js
const { copyFileSync, mkdirSync, readdirSync, lstatSync, unlinkSync, symlinkSync, rmSync } = require("fs");
```

with:

```js
const { copyFileSync, mkdirSync, readdirSync, lstatSync, unlinkSync, symlinkSync, rmSync } = require("fs");
const { scanSkills, syncManifest } = require("./skills-manifest");
```

- [ ] **Step 2: Derive localSkills from the scan**

Replace the hand-maintained array (lines 44-53):

```js
// Local skills are installed for every supported agent; each gets a direct symlink.
const localSkills = [
  { dir: "iso-ai-init",   agents: ["claude-code", "codex"] },
  { dir: "iso-init-repo", agents: ["claude-code", "codex"] },
  { dir: "iso-plan",      agents: ["claude-code", "codex"] },
  { dir: "iso-write",     agents: ["claude-code", "codex"] },
  { dir: "iso-spawn",     agents: ["claude-code", "codex"] },
  { dir: "iso-review",    agents: ["claude-code", "codex"] },
  { dir: "iso-readme",    agents: ["claude-code", "codex"] },
];
```

with:

```js
// Single source of truth: the filesystem. Every skills/<name>/ with a SKILL.md is a skill,
// installed for every supported agent. No hand-maintained list to drift.
const localSkills = scanSkills(join(repoRoot, "skills")).map((dir) => ({
  dir,
  agents: ["claude-code", "codex"],
}));
```

- [ ] **Step 3: Regenerate plugin.json from the same scan**

In `scripts/install.js`, immediately after the symlink-creation loop ends (the `for (const { dir, agents } of localSkills)` block, before the "Also clean up any old ... ~/.agents/skills/" comment at line 91), insert:

```js
// Regenerate the marketplace manifest from the same scan (filesystem = source of truth).
const pluginPath = join(repoRoot, ".claude-plugin", "plugin.json");
const { changed } = syncManifest(pluginPath, localSkills.map((s) => s.dir));
console.log(changed
  ? `  ✓ plugin.json skills regenerated (${localSkills.length})`
  : `  ✓ plugin.json skills already in sync (${localSkills.length})`);
```

- [ ] **Step 4: Verify the scan reproduces today's plugin.json exactly**

Run:

```bash
node -e 'const {scanSkills}=require("./scripts/skills-manifest");const a=scanSkills("./skills").map(n=>"./skills/"+n);const b=require("./.claude-plugin/plugin.json").skills;console.log(JSON.stringify(a)===JSON.stringify([...b].sort())?"MATCH":"DRIFT\n"+JSON.stringify(a)+"\n"+JSON.stringify(b))'
```

Expected: `MATCH` (the 7 current skills, sorted, equal the committed manifest — so a real install run produces a no-op `changed:false`).

- [ ] **Step 5: Run the manifest tests + a syntax check on install.js**

Run: `node --test scripts/skills-manifest.test.js >/dev/null 2>&1 && node --check scripts/install.js && echo "ok"`
Expected: `ok` (tests pass, install.js parses). Do **not** run `node scripts/install.js` itself — it performs network `npx` installs and mutates `~`.

- [ ] **Step 6: Update CLAUDE.md**

In `/Volumes/Crucial-4T/repo/ai/CLAUDE.md`, update the "Adding a Skill" section. Replace:

```markdown
## Adding a Skill

1. Create `skills/<name>/SKILL.md`
2. Register in `.claude-plugin/plugin.json` under `"skills"` (for marketplace discovery)
3. Add an entry to the `localSkills` array in `scripts/install.js`
4. Re-run `node scripts/install.js`
```

with:

```markdown
## Adding a Skill

1. Create `skills/<name>/SKILL.md`
2. Re-run `node scripts/install.js`

The skill set is derived from the filesystem: `scripts/install.js` scans `skills/*/SKILL.md`, symlinks each into both agents, and regenerates `.claude-plugin/plugin.json`. There is no list to maintain — a directory with a `SKILL.md` is a skill. Commit the regenerated `plugin.json` diff.
```

Then update the Architecture-section note that currently reads:

```markdown
The local `IsaiaScope/ai` skills are NOT installed via the marketplace pack. They are listed inline in `scripts/install.js` and symlinked into both supported agents. Update that list when adding a new skill.
```

to:

```markdown
The local `IsaiaScope/ai` skills are NOT installed via the marketplace pack. `scripts/install.js` scans `skills/*/SKILL.md` (via `scripts/skills-manifest.js`) and symlinks each into both supported agents — adding a new skill needs no edit here.
```

- [ ] **Step 7: Checkpoint (no commit)**

Run: `grep -n localSkills scripts/install.js` and confirm the literal array is gone (only the derived `const localSkills = scanSkills(...)` remains). Do not commit.

---

## Self-Review

**1. Spec coverage:**
- B (sidecar reader): Task B1 adds `transcript_meta_get`/`transcript_meta_get_all`; Task B2 routes all 8 sites (spawn ×4, deliver ×3, cleanup ×1). ✓
- A (agentkind): Task A1 creates the module with all 6 facts; A2 routes spawn.sh (source/normalize/argv/label) + deliver.sh (normalize) + run.sh sourcing; A3 routes transcript.sh (candidate_set + slug gate). recover.py intentionally untouched (clean 2-adapter dispatch). ✓
- C (registry SoT): C1 creates pure `skills-manifest.js` + tests; C2 wires install.js (delete `localSkills`, regen plugin.json) + CLAUDE.md. ✓
- CONTEXT.md "Agent kind" term: already added during grilling. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to" — every code step shows the full replacement. ✓

**3. Type/name consistency:** Function names used identically across tasks: `transcript_meta_get`, `transcript_meta_get_all`, `agentkind_normalize|root|glob|slug_needed|label|perm_argv`, `scanSkills`, `syncManifest`. `agentkind.sh` sourced before `transcript.sh` everywhere it is used (spawn.sh Step A2.1; run.sh Step A2.6; A1/B1 test blocks source it explicitly). ✓

**4. No-commit policy:** Every checkpoint runs tests only; no `git` mutating commands anywhere in the plan. ✓

# iso-readme Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the global, stack-agnostic `iso-readme` skill that writes/refines READMEs in the house style (curated badges, context-aware layout), commits README-only, and pushes.

**Architecture:** Approach C — `SKILL.md` holds the procedure (detect context+stack → write/refine → stage README-only → commit → push); `STYLE.md` holds the look canon (badge convention + hex table, per-context layouts, voice, writing rules, skeletons). Wired global via `scripts/install.js` `localSkills` + `.claude-plugin/plugin.json`, dogfooded in root README + CLAUDE.md.

**Tech Stack:** Markdown skill files; Node `scripts/install.js` (symlink wiring); shields.io badge URLs; git for commit/push.

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `skills/iso-readme/STYLE.md` | Look canon: badges, hex table, layouts, voice, writing rules, skeletons |
| `skills/iso-readme/SKILL.md` | Procedure flow + context/stack detection + README-only commit/push |
| `skills/iso-readme/README.md` | Human doc for the skill (dogfoods STYLE.md skill layout) |
| `scripts/install.js` | Add `iso-readme` to `localSkills` (modify) |
| `.claude-plugin/plugin.json` | Register `iso-readme` under `skills` (modify) |
| `README.md` | Root: add skills-table row + skill card (modify) |
| `CLAUDE.md` | Architecture skill list: add iso-readme line (modify) |

Build order: STYLE.md (canon other files reference) → SKILL.md → skill README → wiring (install.js, plugin.json) → dogfood docs (root README, CLAUDE.md) → verify.

---

## Task 1: STYLE.md — the look canon

**Files:**
- Create: `skills/iso-readme/STYLE.md`

- [ ] **Step 1: Write the file**

````markdown
# iso-readme — Style Canon

The house look for every README. `SKILL.md` references this file; humans can read it directly to tweak colors or sections.

## Badges

- Source: **shields.io**, flat (default — never `&style=for-the-badge`).
- Format: `https://img.shields.io/badge/<label>-<message>-<hex>?logo=<slug>&logoColor=white`
- **Curated 3–6, identity-only:** primary language/runtime · 1–2 defining frameworks · license. Add a version or CI badge only when meaningful.
- **Skip:** minor/transitive deps, vanity counters, anything that doesn't define what the project *is*.
- Placement: centered `<p align="center">` row directly under the title (root/app); single row under the `#` heading (lib/pkg); usually none for skills.

### Brand hex table (extendable — add a row per new tech)

| Tech | logo slug | hex |
|------|-----------|-----|
| Node | node.js | 339933 |
| TypeScript | typescript | 3178C6 |
| JavaScript | javascript | F7DF1E |
| Python | python | 3776AB |
| Rust | rust | DEA584 |
| Go | go | 00ADD8 |
| React | react | 61DAFB |
| Next.js | next.js | black |
| Tailwind | tailwindcss | 06B6D4 |
| Prisma | prisma | 2D3748 |
| PHP | php | 777BB4 |
| Ruby | ruby | CC342D |
| License (MIT/any) | — | green |

Tech not listed → pick a sensible shields color and **add the row here**.

## Layouts by context

```
ROOT / APP                  SKILL                       LIB / PKG
──────────                  ─────                       ─────────
<center logo?>              # <emoji> name              # name
# <center title>            > one-line tagline          badges (version·license·CI)
badges (center)             ---                         > tagline
> tagline                   ## 🧩 What It Does          ---
---                         ## ▶️ Trigger               ## Install
## 🚀 Quickstart            ## ✅ Output                ## Usage
## ✨ Features              ## 🔧 Dependencies          ## API
## 🛠️ <domain sections>     ## 🔗 Related               ## License
## 🔗 / 🙏 Credits
```

## Voice

- Confident, terse. Light emoji section headers. No marketing fluff, no hedging.
- Tagline = one line: what it *is* + why it matters.

## Writing best-practices

- **Tables for decision logic** (X → result, flag → meaning), not prose paragraphs.
- **Chunk walls of text** into bullets / sub-headings. No paragraph longer than ~4 lines.
- **Quickstart before deep docs** — a runnable command appears early.
- Code fences for every command and sample output. A real example beats a description.
- Cross-link siblings; link up to root (`→ Full documentation`, `## 🔗 Related`).
- Fix broken relative links; point deps that aren't local dirs to their upstream source.

## Skeletons

### Root / app
```markdown
<h1 align="center">EMOJI Project</h1>
<p align="center">One-line tagline.</p>
<p align="center">
  BADGES
</p>

---

## 🚀 Quickstart
\`\`\`bash
INSTALL/RUN
\`\`\`

## ✨ Features
- ...

## 🔗 Credits
```

### Skill
```markdown
# EMOJI skill-name

> One-line tagline — what it is + why it matters.

---

## 🧩 What It Does
...

## ▶️ Trigger
\`\`\`
/skill-name
\`\`\`

## ✅ Output
...

## 🔧 Dependencies
| Tool | Role | Source |
|------|------|--------|

## 🔗 Related
- [`sibling`](../sibling/)
```

### Lib / pkg
```markdown
# package-name

BADGES (version · license · CI)

> One-line tagline.

---

## Install
\`\`\`bash
npm i package-name
\`\`\`

## Usage
## API
## License
```
````

- [ ] **Step 2: Verify it renders + matches the spec**

Run: `head -40 skills/iso-readme/STYLE.md && grep -c '|' skills/iso-readme/STYLE.md`
Expected: file prints; hex table present (multiple `|` lines). No `TBD`/`TODO`.

- [ ] **Step 3: Commit**

```bash
git add skills/iso-readme/STYLE.md
git commit -m "feat(iso-readme): add STYLE.md look canon"
```

---

## Task 2: SKILL.md — procedure

**Files:**
- Create: `skills/iso-readme/SKILL.md`

- [ ] **Step 1: Write the file**

````markdown
---
name: iso-readme
description: Write or refine README files in the IsaiaScope house style — curated shields.io badges, context-aware layout (repo root/app · skill · lib/pkg), scannable prose — then commit only the README changes and push. Global, stack-agnostic (node, python, rust, go, docs-only, monorepo). Use when invoked as /iso-readme [path], or asked to write/refine/beautify a README in my style.
---

# iso-readme

Write a fresh README or refine an existing one to the house look defined in [STYLE.md](STYLE.md), then commit **only** the README file(s) and push. Runs in any repo, under Claude Code or Codex.

Read [STYLE.md](STYLE.md) before writing — it is the single source of truth for badges, layout, voice, and writing rules.

## Input

`/iso-readme [path]`

- **path given** — a README file or a directory (use its `README.md`).
- **no arg** — target the repo-root `README.md`. If the repo is a monorepo, offer to also scan subdirs that carry their own manifest (`apps/*`, `packages/*`); do not scan them unprompted.

## Step 1: Detect context

Pick the layout (see STYLE.md "Layouts by context"):

| Signal | Context | Layout |
|--------|---------|--------|
| A `SKILL.md` sits in the same dir, or path is `skills/<name>/README.md` | **skill** | skill layout |
| Repo-root README, or an application dir | **root / app** | centered + badges |
| Manifest declares a published package (name+version, library not app) | **lib / pkg** | lib layout |

Ambiguous → top-level defaults to root/app; a dir with `SKILL.md` is a skill; ask only if still unclear.

## Step 2: Detect stack (stack-agnostic)

Parse whatever manifest exists to derive badge signals:

| Manifest | Stack |
|----------|-------|
| `package.json` | node/TS/JS; frameworks from `dependencies` (next, react, express…) |
| `pyproject.toml` / `setup.py` / `requirements.txt` | python; framework from deps (django, fastapi…) |
| `Cargo.toml` | rust |
| `go.mod` | go |
| `composer.json` | php |
| `Gemfile` | ruby |
| none | docs-only → license badge only (if LICENSE exists), or no badges |

## Step 3: Write or refine

- **README missing → generate fresh** from the matching STYLE.md skeleton.
- **README exists → refine:** preserve all real content (install steps, env vars, credits, commands) — restyle layout + badges only. **Never invent** features or commands.
- Derive badges from Step 2, curate to **3–6 identity badges** (primary lang/runtime · 1–2 defining frameworks · license) using the STYLE.md hex table. Add a missing tech as a new row in STYLE.md.

## Step 4: Commit README-only + push

Stage **only** the README path(s) written this run — never `git add -A`. Unrelated working-tree changes stay untouched.

```bash
git add <each README path written>
git commit -m "docs(readme): <concise summary>"
git push
```

If not a git repo → write the file, skip stage/commit/push, tell the user. If push is denied or there is no remote → report it, leave the commit in place, do not force.

## Stop / edge rules

- Existing README with real content → preserve facts, restyle only.
- Monorepo with no arg → refine root; offer (don't force) subdir scan.
- Badge tech not in hex table → sensible color + add the row.
- Not a git repo → write only, no git.
````

- [ ] **Step 2: Verify frontmatter + links**

Run: `head -5 skills/iso-readme/SKILL.md && grep -o 'STYLE.md' skills/iso-readme/SKILL.md | head -1`
Expected: valid `name:`/`description:` frontmatter; `STYLE.md` link present.

- [ ] **Step 3: Commit**

```bash
git add skills/iso-readme/SKILL.md
git commit -m "feat(iso-readme): add SKILL.md procedure"
```

---

## Task 3: Skill README (dogfood)

**Files:**
- Create: `skills/iso-readme/README.md`

- [ ] **Step 1: Write the file** (skill layout, per STYLE.md)

````markdown
# 📝 iso-readme

> Write or refine any README in the house style — curated badges, context-aware layout, scannable prose — then commit just the README and push. Global, stack-agnostic.

---

## 🧩 What It Does

Detects what kind of README it's looking at and what stack the project uses, then writes a fresh one or refines the existing one to the look defined in [STYLE.md](STYLE.md) — finishing by committing **only** the README file(s) and pushing.

| Step | Action |
|------|--------|
| 1 | Locate target README (arg, or repo root) |
| 2 | Detect context → root/app · skill · lib/pkg |
| 3 | Detect stack from any manifest (package.json, pyproject.toml, Cargo.toml, go.mod…) |
| 4 | Write fresh, or refine in place (preserve real content) |
| 5 | Curate 3–6 identity badges + write per layout |
| 6 | Stage README-only → `docs(readme):` commit → push |

## ▶️ Trigger

```
/iso-readme
/iso-readme path/to/dir
```

Or ask: *"beautify this README"*, *"write a README in my style"*

## 🎨 The Look

- **Badges:** shields.io flat + logo + brand hex, curated to 3–6 (primary lang · defining frameworks · license). No badge spam.
- **Layout by context:** centered + badges for repo root/app; `# emoji + tagline` for skills; version/install/API for libs.
- **Scannable:** tables for decision logic, chunked prose, quickstart first.

→ Full canon: [STYLE.md](STYLE.md)

## 🔧 Dependencies

| Tool | Role | Source |
|------|------|--------|
| `git` | Stage README-only, commit, push | [git-scm.com](https://git-scm.com) |

> No external CLI — the skill is the interface. Reads project manifests to derive badges.

## 🔗 Related

- [`iso-ai-init`](../iso-ai-init/) — broader AI-tooling setup for a repo.
- [`iso-init-repo`](../iso-init-repo/) — repo governance (branches, CI).
````

- [ ] **Step 2: Verify sibling links resolve**

Run: `ls skills/iso-ai-init skills/iso-init-repo skills/iso-readme/STYLE.md`
Expected: all exist (no "No such file").

- [ ] **Step 3: Commit**

```bash
git add skills/iso-readme/README.md
git commit -m "docs(iso-readme): add skill README"
```

---

## Task 4: Wire global install

**Files:**
- Modify: `scripts/install.js` (localSkills array)
- Modify: `.claude-plugin/plugin.json` (skills list)

- [ ] **Step 1: Inspect current wiring**

Run: `grep -n "iso-spawn\|iso-write" scripts/install.js .claude-plugin/plugin.json`
Expected: shows where existing iso-* skills are listed in both files.

- [ ] **Step 2: Add `iso-readme` to `localSkills` in `scripts/install.js`**

Insert `iso-readme` into the `localSkills` array next to the other `iso-*` entries, matching the exact surrounding syntax (quotes/commas) shown by Step 1.

- [ ] **Step 3: Add `iso-readme` to `.claude-plugin/plugin.json`**

Add the skill path under the `skills` array, matching the existing entry format (e.g. `"./skills/iso-readme"` or `"skills/iso-readme/SKILL.md"` — match what iso-spawn uses).

- [ ] **Step 4: Verify both files still parse**

Run: `node -e "require('./scripts/install.js')" 2>/dev/null; node -e "JSON.parse(require('fs').readFileSync('.claude-plugin/plugin.json','utf8')); console.log('plugin.json OK')" && grep -c iso-readme scripts/install.js .claude-plugin/plugin.json`
Expected: `plugin.json OK`; `iso-readme` count ≥1 in each file. (install.js require may no-op/print; the key check is plugin.json parses.)

- [ ] **Step 5: Commit**

```bash
git add scripts/install.js .claude-plugin/plugin.json
git commit -m "feat(iso-readme): wire global install + plugin registration"
```

---

## Task 5: Dogfood in root README + CLAUDE.md

**Files:**
- Modify: `README.md` (skills table + skill card)
- Modify: `CLAUDE.md` (Architecture skill list)

- [ ] **Step 1: Add the skills-table row in `README.md`**

In the "Original skills" table, add after the iso-spawn row:

```markdown
| 📝 [iso-readme](skills/iso-readme/) | Write/refine any README in the house style, commit + push | `/iso-readme` |
```

- [ ] **Step 2: Add a skill card in `README.md`**

After the `iso-spawn` card (before `### 🗿 caveman`), add:

```markdown
### 📝 iso-readme *(original)*

Write or refine any README in the house style — curated badges, context-aware layout, scannable prose — then commit just the README and push. Global, stack-agnostic.

- 🎨 **Curated badges** — shields.io flat, 3–6 identity badges, no spam
- 🧱 **Layout by context** — root/app · skill · lib/pkg
- 🔍 **Stack-agnostic** — reads any manifest to derive badges

```
/iso-readme
```

→ [Full documentation](skills/iso-readme/README.md)

**Dependencies:** `git`
```

- [ ] **Step 3: Add the skill to `CLAUDE.md` Architecture list**

In the `skills/` block of the Architecture section, add:

```
  iso-readme/SKILL.md              — write/refine READMEs in house style, commit + push
```

- [ ] **Step 4: Verify links + table**

Run: `grep -n "iso-readme" README.md CLAUDE.md && ls skills/iso-readme/README.md`
Expected: rows/card/line present; README path exists.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs(iso-readme): list skill in root README + CLAUDE.md"
```

---

## Task 6: Final verification

- [ ] **Step 1: All skill files present + no placeholders**

Run: `ls skills/iso-readme/ && grep -rn "TBD\|TODO\|FIXME" skills/iso-readme/ || echo "no placeholders"`
Expected: `README.md SKILL.md STYLE.md`; `no placeholders`.

- [ ] **Step 2: install.js dry sanity (no global mutation required to pass)**

Run: `grep -n "iso-readme" scripts/install.js .claude-plugin/plugin.json`
Expected: present in both.

- [ ] **Step 3: Push the branch / commits**

```bash
git push
```

Expected: pushed. (On default-branch repo this hits the push-gate prompt — approve.)

---

## Self-Review

- **Spec coverage:** behavior (T2 Step 3) · scope/context (T2 Step 1) · badges 3–6 + hex (T1) · README-only commit+push (T2 Step 4) · global install (T4) · stack-agnostic (T2 Step 2) · approach C two-file split (T1+T2) — all covered.
- **Placeholder scan:** file bodies are complete; the only "fill-in" steps (T4 Step 2/3, T5) are surgical edits whose exact insert text is given.
- **Type consistency:** filenames (`STYLE.md`, `SKILL.md`, `README.md`) and the `iso-readme` slug are consistent across all tasks and the dogfood docs.

---

## Implementation Log

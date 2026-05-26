# iso-readme — Design

**Goal:** A global, stack-agnostic skill that writes or refines README files to match the user's house style — curated badges, context-aware layout, scannable prose — then commits only the README changes and pushes.

**Status:** approved (brainstorm) @ 2026-05-26

---

## Summary

`/iso-readme` detects what kind of README it's looking at (repo root / app, skill, or library / package), detects the project's stack from whatever manifest exists, then generates a fresh README (if none) or refines the existing one (preserving real content, restyling to the house look). It finishes by staging **only** README files, committing with a `docs(readme):` message, and pushing.

The skill is **global** — installed via `scripts/install.js` like the other `iso-*` skills, runnable from any repo under Claude Code or Codex.

---

## Decisions (from brainstorming)

| Topic | Decision |
|-------|----------|
| Behavior | Auto-detect: refine if a README exists, generate fresh if not |
| Scope | Any README; layout chosen by context (root/app · skill · lib/pkg) |
| Badges | Curated core stack + license, ~3–6, shields.io flat + logo + brand hex |
| Finalize | Stage **only** README files → `docs(readme):` commit → push |
| Availability | Global skill; must run on any repo type (node, python, rust, go, docs-only, monorepo) |
| Packaging | Approach C: `SKILL.md` (procedure) + `STYLE.md` (look canon) |

---

## Files

```
skills/iso-readme/
  SKILL.md     # procedure: detect → write/refine → commit READMEs → push
  STYLE.md     # the look canon: badge convention, layouts, voice, skeletons
  README.md    # human doc for the skill itself (dogfoods STYLE.md)
```

### Global install wiring

- Add `iso-readme` to the `localSkills` array in `scripts/install.js` → symlinked into `~/.claude/skills/` and `~/.codex/skills/`.
- Register `iso-readme` in `.claude-plugin/plugin.json` under `skills`.
- After `node scripts/install.js`, `/iso-readme` is runnable from any repo, in Claude Code or Codex.
- Update root `README.md` skills table + add a skill card (dogfooding).
- Update `CLAUDE.md` Architecture skill list.

---

## SKILL.md — procedure flow

```
1. Locate target README(s)
     arg given  → that path / dir
     no arg     → repo root README (+ offer: scan subdirs that have their own manifest)
2. Detect context     → root|app · skill · lib/pkg   (rules in STYLE.md)
3. Detect stack       → parse manifest(s): package.json / pyproject.toml /
                        Cargo.toml / go.mod / composer.json / … (stack-agnostic)
4. Exists? → refine (preserve real content, restyle)   Missing? → generate fresh
5. Derive badges from stack (curated 3–6) + write file per STYLE.md layout
6. Stage ONLY README files (git add of the specific README paths, nothing else)
7. docs(readme): … commit  →  push
```

**Context detection rules:**

- **skill** — file is `skills/<name>/README.md` or a sibling `SKILL.md` exists in the same dir → skill layout.
- **root / app** — the repo-root README, or an app dir under a monorepo (`apps/*`, `packages/*` that is an application) → centered/badge layout.
- **lib / pkg** — a publishable package (manifest declares a published name/version, not an app) → lib layout.
- Ambiguous → default to root/app for top-level, skill if a `SKILL.md` is present, ask only if still unclear.

**Stack detection (stack-agnostic):**

| Manifest | Stack signal |
|----------|--------------|
| `package.json` | node/TS/JS; frameworks from `dependencies` (next, react, express, …) |
| `pyproject.toml` / `setup.py` / `requirements.txt` | python; framework from deps (django, fastapi, …) |
| `Cargo.toml` | rust |
| `go.mod` | go |
| `composer.json` | php |
| `Gemfile` | ruby |
| none | docs-only repo → minimal badges (license only, or none) |

Badges are derived from detected signals, then curated down to 3–6 identity badges.

**Finalize — README-only commit:**

- Collect the exact README path(s) written/refined this run.
- `git add` only those paths. Never `git add -A`. Pre-existing unrelated changes stay untouched and uncommitted.
- Commit: `docs(readme): <concise summary>` with the Co-Authored-By trailer.
- `git push`. (On a default-branch repo this hits the user's push-gate prompt at runtime — expected; the skill still issues the push.)

---

## STYLE.md — the look canon

### Badges

- Source: **shields.io**, flat (default style — no `&style=for-the-badge`).
- Format: `https://img.shields.io/badge/<label>-<message>-<hex>?logo=<slug>&logoColor=white`
- Brand-hex table per tech (Node `339933`, TypeScript `3178C6`, Python `3776AB`, Rust `DEA584`, React `61DAFB`, Next.js `black`, license `green`, …) — extendable; adding a tech = one row.
- **Curated 3–6**, identity-only: primary language/runtime · 1–2 defining frameworks · license. Add a version or CI badge only when meaningful.
- Skip: minor/transitive deps, vanity counters, anything that doesn't define what the project *is*.
- Placement: centered `<p align="center">` row directly under the title.

### Layouts by context

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

Skill layout = the exact pattern the existing `iso-*` skill READMEs use (consistency locked).

### Voice

- Confident, terse. Light emoji section headers. No marketing fluff, no hedging.
- Tagline = one line: what it *is* + why it matters.

### Writing best-practices (baked in)

- **Tables for decision logic** (X → result, flag → meaning), not prose paragraphs.
- **Chunk walls of text** into bullets / sub-headings. No paragraph longer than ~4 lines.
- **Quickstart before deep docs** — a runnable command appears early.
- Code fences for every command and sample output. A real example beats a description.
- Cross-link siblings and link up to root (`→ Full documentation`, `## 🔗 Related`).
- Fix broken relative links; point deps that aren't local dirs to their upstream source.

### Skeletons

STYLE.md carries one fenced skeleton per layout (root/app, skill, lib/pkg) that the agent fills. Skeletons are reference content, not generated config — they live in STYLE.md, not a `templates/` dir.

---

## Edge cases / stop rules

- **Not a git repo** — still write/refine the README; skip stage/commit/push; tell the user.
- **No manifest (docs-only)** — minimal or no badges; license badge only if a LICENSE exists.
- **Monorepo, no arg** — refine root README; offer to scan `apps/*` / `packages/*` that have their own manifest rather than doing it unprompted.
- **Existing README with real content** — preserve facts (install steps, env vars, credits); restyle layout and badges only. Never invent features or commands.
- **Badge tech not in hex table** — use a sensible shields color, add the row to STYLE.md.
- **Push denied / no remote** — report it; leave the commit in place. Do not force.

---

## Out of scope (YAGNI)

- Auto-generating screenshots or logos.
- Translating READMEs / i18n.
- Editing non-README docs (CONTRIBUTING, CHANGELOG).
- A separate CLI — the skill is the interface.

---

## Implementation Log

- Spec approved: 2026-05-26

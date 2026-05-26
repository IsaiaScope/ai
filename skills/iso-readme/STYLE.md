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

````markdown
<h1 align="center">EMOJI Project</h1>
<p align="center">One-line tagline.</p>
<p align="center">
  BADGES
</p>

---

## 🚀 Quickstart
```bash
INSTALL/RUN
```

## ✨ Features
- ...

## 🔗 Credits
````

### Skill

````markdown
# EMOJI skill-name

> One-line tagline — what it is + why it matters.

---

## 🧩 What It Does
...

## ▶️ Trigger
```
/skill-name
```

## ✅ Output
...

## 🔧 Dependencies
| Tool | Role | Source |
|------|------|--------|

## 🔗 Related
- [`sibling`](../sibling/)
````

### Lib / pkg

````markdown
# package-name

BADGES (version · license · CI)

> One-line tagline.

---

## Install
```bash
npm i package-name
```

## Usage
## API
## License
````

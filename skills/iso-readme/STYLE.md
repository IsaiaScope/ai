# iso-readme — Style Canon

The house look for every README. `SKILL.md` references this file; humans can read it directly to tweak colors or sections.

## Badges

- Source: **shieldcn** (`shieldcn.dev`) — shadcn/ui-styled badges. Same `label-message-color` grammar as shields.io.
- Canon variant: **`default`** (solid hex fill, white text — loud). Canon size: **`xs`**.
- Format: `https://shieldcn.dev/badge/<label>-<message>-<hex>.svg?logo=<slug>&logoColor=fff&variant=default&size=xs`
- **`logoColor` must be hex, no `#`** (`fff`, not `white`) — shieldcn blindly prepends `#`, so a named color becomes invalid `#white` and the logo renders black. Same for the `<hex>` color segment.
- **`.svg`, not `.png`** — shieldcn SVG inlines text + logo as vector paths (no `@font-face`/`<style>`/external refs), so GitHub renders it crisp at any DPI and has nothing to sanitize. PNG is 1x-only (no `scale`/`dpr` param) → blurry on retina. Verified self-contained 2026-05-27.
- **Light brand colors need a dark bg.** `default` variant always paints text/logo light, so a light `<hex>` (JS `F7DF1E`, etc.) = unreadable. Use the brand's dark color as `<hex>` and put the bright color on `logoColor` (e.g. JavaScript → `JavaScript-installer-323330.svg?logo=javascript&logoColor=F7DF1E`).
- **Curated 3–6, identity-only:** primary language(s) by real bytes · 1–2 defining frameworks/targets. (Measure: `git ls-files | … wc -c` by extension — don't guess which language dominates.) Add a version or CI badge only when meaningful.
- **Skip:** license-only vanity, minor/transitive deps, counters, anything that doesn't define what the project *is*.
- Placement: centered `<p align="center">` row directly under the title (root/app); single row under the `#` heading (lib/pkg); usually none for skills.
- **Link badges to their source** where one exists (npm/repo/docs): wrap `<a href="…"><img … alt="…" /></a>`. Always set `alt`.

### Variants (shieldcn `variant=`)

`default` (canon — primary bg, bold) · `secondary` (muted) · `outline` (transparent + border, themed text) · `ghost` (transparent, no border) · `destructive` (red) · `branded` (bg = logo's own brand color). Stick to `default` for identity rows unless a README has a reason.

### Dynamic badges (shieldcn native — use only when meaningful)

shieldcn has first-class provider endpoints; prefer these over hand-built shields.io query URLs.

| Want | URL stem (append `.svg?variant=default&size=xs`) |
|------|--------------------------------------------------|
| npm version | `shieldcn.dev/npm/v/<pkg>` |
| PyPI version | `shieldcn.dev/pypi/v/<pkg>` |
| Crates version | `shieldcn.dev/crates/v/<crate>` |
| GitHub release | `shieldcn.dev/github/v/release/<owner>/<repo>` |
| GitHub CI status | `shieldcn.dev/github/actions/workflow/status/<owner>/<repo>/<file>` |
| Codecov | `shieldcn.dev/codecov/c/github/<owner>/<repo>` |

### Icons (40,000+ via shieldcn — but only use ones that exist)

| Source | `logo=` syntax | Covers |
|--------|----------------|--------|
| Simple Icons | bare slug `logo=react`, or `logo=si:react` | brand/tech logos (default lookup) |
| React Icons | `logo=ri:FaReact`, `logo=ri:GoStarFill` | generic + UI glyphs |
| Custom SVG | `logo=data:image/svg+xml;base64,…` | anything else |
| none | `logo=false` | text-only badge |

**Where to look up / verify slugs (official):**
- Simple Icons (brands): browse **simpleicons.org** — use the exact slug shown.
- React Icons (everything else, incl. brands missing from Simple Icons): **react-icons.github.io/react-icons** — pass the component name with its library prefix, e.g. `ri:SiOpenai`, `ri:FaRobot`, `ri:GoStarFill`.
- Preview any badge live at **shieldcn.dev/gen**. Official agent-skill docs: **shieldcn.dev/docs/skill**.

**Realism rule — never invent a slug.** Use only an icon you're confident resolves:
- Tech in the hex table → use its listed slug (already verified).
- New brand tech → check Simple Icons first. **If absent there, try React Icons `ri:Si<Name>`** before giving up (e.g. OpenAI is *not* in shieldcn's Simple Icons set but `ri:SiOpenai` works). Some brands only live in React Icons.
- Still nothing (a concept, not a product) → `logo=false` **and lead the label with a fitting emoji** (e.g. `📦-packaged-green`).
- **Verify by request, not by faith:** a resolved icon adds `<path>`s; a miss returns the no-logo baseline. Quick check — `curl -s "<url>" | grep -oc '<path'` should exceed the `logo=false` count. A missed slug renders blank.

### Brand hex table (extendable — add a row per new tech)

Slugs are canonical Simple Icons (no shorthand dots — `nodedotjs`, not `node.js`). `logoColor` column = recommended logo tint.

| Tech | logo slug | bg hex | logoColor |
|------|-----------|--------|-----------|
| Node | nodedotjs | 339933 | fff |
| TypeScript | typescript | 3178C6 | fff |
| JavaScript | javascript | 323330 | F7DF1E |
| Shell / Bash | gnubash | 4EAA25 | fff |
| Python | python | 3776AB | fff |
| Rust | rust | DEA584 | 000 |
| Go | go | 00ADD8 | fff |
| React | react | 20232A | 61DAFB |
| Next.js | nextdotjs | 000000 | fff |
| Tailwind | tailwindcss | 06B6D4 | fff |
| Prisma | prisma | 2D3748 | fff |
| PHP | php | 777BB4 | fff |
| Ruby | ruby | CC342D | fff |
| Anthropic / Claude | anthropic | CC785C | fff |
| OpenAI / Codex | `ri:SiOpenai` (not in Simple Icons) | 412991 | fff |

Light brands (JS, React) use a dark `bg hex` + bright `logoColor` so the default variant's light text stays readable.

Tech not listed → pick a sensible color (hex or shadcn color token) and **add the row here**. `hex` column feeds the `<color>` URL segment directly.

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

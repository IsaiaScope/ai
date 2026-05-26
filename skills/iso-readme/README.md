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

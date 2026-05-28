# iso-readme — Definition of Done

The gate every README must clear **before** the Step 4 commit. `SKILL.md` turns the applicable rows into TodoWrite items and commits only when all pass. Each gate cites the [STYLE.md](STYLE.md) anchor it enforces — read the anchor for the *why*, this file is the *check*.

**How to run:** detect context (Step 1) → take the **Universal** block **plus** the one matching context block → one TodoWrite item per gate → verify each → commit. Skipping a gate silently is the failure mode this file exists to stop.

---

## Universal — always (every context, every run)

- [ ] **U1 · Badge logos resolve** [B3, I4] — for **every** badge with a `logo=` (skip `logo=false`): `curl -s "<url>" | grep -oc '<path'` returns HTTP 200 **and** a count greater than the `logo=false` baseline. A miss renders blank. Includes hex-table slugs — re-verify, don't trust.
- [ ] **U2 · Colors are bare hex** [B4] — `<hex>` segment and `logoColor` are hex with **no `#`** and no named color (`fff`, never `white`). shieldcn prepends `#`; a name becomes `#white` → black logo.
- [ ] **U3 · `.svg` not `.png`** [B5] — every badge URL ends `.svg`.
- [ ] **U4 · Links resolve** [V8] — every relative link points at a real path; deps that aren't local dirs point to their upstream source. No broken anchors.
- [ ] **U5 · Non-breaking hyphens** [V9] — hyphenated names in narrow table cells use literal `‑` (U+2011) in **visible text only**; real `-` stays in the link target / `code` span.
- [ ] **U6 · Short table cells** [V10] — a trigger/command column shows the **base** command only (`/iso-write`); full arg/flag syntax lives in prose below, never in the cell.
- [ ] **U7 · Voice** [V1, V2] — confident, terse, no marketing fluff/hedging; tagline is one line (what it *is* + why it matters).
- [ ] **U8 · No invented content** [SKILL Step 3] — **refine:** every real fact preserved (install steps, env vars, credits, commands). **fresh:** zero features/commands that aren't in the code.
- [ ] **U9 · Stage README only** [SKILL Step 4] — `git add` lists only the README path(s) written this run. Never `git add -A`; unrelated working-tree changes stay untouched.

---

## Context: ROOT / APP

- [ ] **A1 · Layout** [L1] — section order + headers match the ROOT/APP skeleton; badges in a centered `<p align="center">` row directly under the title.
- [ ] **A2 · Badges curated 3–6, identity-only** [B7, B8] — primary language(s) by **real bytes** (measured, not guessed) + 1–2 defining frameworks. No license-only vanity, counters, or transitive deps.
- [ ] **A3 · Light brands on dark bg** [B6] — any light brand color uses the dark `<hex>` + bright `logoColor` pairing.
- [ ] **A4 · Variant** [B2, B11] — identity badges use `variant=default`, `size=xs`.
- [ ] **A5 · Accent row isolated** [B14, B15] — *if* a lifecycle or AI-accent badge is used, it sits on a **second** centered `<p>` row; the identity row stays pure brand-hex. Max one lifecycle + one accent.

## Context: SKILL

- [ ] **S1 · Layout** [L1] — matches the SKILL skeleton: `# EMOJI name` · one-line tagline · `## 🧩 What It Does` · `## ▶️ Trigger` · `## ✅ Output` · `## 🔧 Dependencies` · `## 🔗 Related`.
- [ ] **S2 · No badges** [B9] — a skill README carries **no** identity badges (badges are for root/app + lib). Adding them is the most common skill-README error. (With no `logo=` badges, U1 passes trivially — confirm there are none rather than adding any.)

## Context: LIB / PKG

- [ ] **P1 · Layout** [L1] — matches the LIB/PKG skeleton: `# name` · badge row · tagline · `## Install` · `## Usage` · `## API` · `## License`.
- [ ] **P2 · Badges** [B9, B12] — version · license · CI, single row under the `#` heading. Prefer shieldcn native provider endpoints (`/npm/v/…`, `/pypi/v/…`, `/github/v/release/…`) over hand-built shields.io URLs.
- [ ] **P3 · Curated + readable** [B6, B7] — 3–6 curated; light brands on dark bg.

---

## Adding a gate

A new rule in STYLE.md gets a new anchor (append-only — see STYLE.md "Rule anchors"); add the matching gate here under Universal or the right context block, citing that anchor. Keep one gate = one anchor where possible so a failure points to a single rule.

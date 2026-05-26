# ⚡ iso-ai-init

> Wire any repo with IsaiaScope AI defaults — token-compressed responses (primary) plus an installed, auto-updated graphify CLI and a deep semantic knowledge graph built on init.

---

## 🧩 What It Does

A **gate** (`templates/preflight-gate.sh`) runs first and decides scope:

- **Global steps** run anywhere — even outside a repo.
- **Repo-scoped steps** run only inside a git repo. Being outside one isn't an error; those steps just skip.

### Global steps (run anywhere)

**1. 🗿 Caveman** — installs the `caveman` CLI, turns on ultra mode (~75% cheaper tokens), registers `caveman-shrink` as a Claude Code MCP, and writes a live statusline:

```
…/repo  main  ctx:75%  $5.82  ULTRA
```

**2. 🗜️ MCP shrink** — wraps token-heavy MCP servers with `caveman-shrink`. Driven by a **name allowlist** (`ALLOWLIST` in `templates/shrink-known-mcps.js`). It assumes nothing about transport — the same MCP can be local for you and hosted for someone else — so it checks at runtime:

| Server is… | Result |
|------------|--------|
| present **and** stdio | ✅ wrapped |
| remote / HTTP | ⏭️ skipped (can't wrap) |
| absent, or already shrunk | ⏭️ skipped |

It never installs an MCP you don't already have.

### Repo-scoped steps (git repo only)

**3. 🕸️ Graphify** — runs in two parts:

**(3a) Wiring** — `templates/graphify-init.sh`, deterministic (no LLM):

- Installs / auto-updates the `graphify` CLI.
- Runs graphify's **officially recommended** setup: `graphify claude install --project` + `graphify codex install --project` write a `## graphify` section into the repo's `CLAUDE.md` / `AGENTS.md` ("prefer `graphify query` over grep") plus a read-only **query-nudge** PreToolUse hook for Claude Code.
- Installs **auto-update git hooks** (`graphify hook install`) — native post-commit / post-checkout, AST-only rebuild, no LLM, no husky — so the graph stays current on every commit.
- Gitignores the generated + machine-specific bits: `graphify-out/`, `/.graphify_*.json` root scratch, the regenerated `.claude/skills/graphify/` + `.agents/skills/graphify/` copies, and `.codex/hooks.json`.
- Sweeps leftover root scratch from any interrupted or older run.

**(3b) Deep build** — the skill then invokes `/graphify . --mode deep` to build (or refresh) the full semantic graph, and re-sweeps scratch afterward in case the build was interrupted.

> Why is the deep build a skill step and not part of the script? There's no CLI build verb — the deep build is LLM-orchestrated by the `/graphify` skill, so it can't live inside a deterministic shell script.

---

## ▶️ Trigger

```
/iso-ai-init
```

Or ask: *"set up AI tooling"*, *"init AI defaults"*, *"add graphify and caveman"*

---

## ✅ Output

```
✓ Caveman ultra + shrink MCP + statusline   [primary]
✓ Graphify CLI installed / updated to latest
✓ /graphify skill wired + AST auto-update git hooks installed
  · graphify-out/ gitignored
  · deep semantic graph built/refreshed via /graphify --mode deep
```

> Restart Claude Code after running to activate the MCP, statusline, and skill wiring.

---

## 🔧 Dependencies

| Tool | Purpose | Source |
|------|---------|--------|
| `caveman` | Token-compressed Claude responses | [GitHub](https://github.com/juliusbrussee/caveman) |
| `caveman-shrink` | Claude Code MCP for browser token savings | Bundled with `caveman --all` |
| `graphify` | Codebase → knowledge graph (installed + auto-updated) | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) · [GitHub](https://github.com/safishamsi/graphify) |

### Install (reference)

```bash
# caveman — global, once per machine
npm install -g caveman --all

# graphify — global, prefer uv; --upgrade keeps it current
uv tool install --upgrade graphifyy
# or: pipx install graphifyy
```

---

## 📁 Templates

All config is generated from `templates/` next to this file:

| Template | Scope | Purpose |
|----------|-------|---------|
| `preflight-gate.sh` | — | detects git repo; decides global vs repo-scoped steps |
| `caveman-init.sh` | global | installs caveman + sets ultra + registers MCP |
| `caveman-config.json` | global | sets ultra mode (`~/.config/caveman/config.json`) |
| `statusline.sh` | global | live token/cost/mode badge (`~/.claude/statusline-command.sh`) |
| `shrink-known-mcps.js` | global | wrap allowlisted, present, stdio MCPs with caveman-shrink |
| `graphify-init.sh` | repo | install/update graphify CLI + native always-on wiring + auto-update git hook |

> Edit any template to change default behavior — no SKILL.md change needed.
> The shrink allowlist lives in `shrink-known-mcps.js` (`ALLOWLIST` array).

---

## 🔗 Related

- [`iso-init-repo`](../iso-init-repo/) — repo *governance* (branches, CI, hooks); pairs with this skill's AI *tooling* setup.
- `setup-matt-pocock-skills` — per-repo config (issue tracker, triage labels, domain docs) for the engineering skills (`to-issues`, `triage`, `tdd`, …). Interactive; iso-ai-init only *points* to it when `docs/agents/` is absent — never runs it.
- [`graphify`](https://github.com/safishamsi/graphify) — the knowledge-graph skill this wires up (manual invocation via `/graphify`).
- [`caveman`](https://github.com/juliusbrussee/caveman) — the caveman-mode skill this activates (toggle via `/caveman`).

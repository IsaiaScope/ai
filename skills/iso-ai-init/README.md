# ⚡ iso-ai-init

> Wire any repo with IsaiaScope AI defaults — token-compressed responses (primary) plus an installed, auto-updated graphify CLI and a deep semantic knowledge graph built on init.

---

## 🧩 What It Does

A **gate** (`templates/preflight-gate.sh`) runs first and decides scope. Global steps run anywhere; repo-scoped steps run only inside a git repo (being outside a repo is not an error — it just skips them).

**Global (run anywhere):**

1. **🗿 Caveman** — installs the `caveman` CLI globally, activates ultra mode (tokens ~75% cheaper), registers `caveman-shrink` as a Claude Code MCP, and writes a live statusline (`…/repo  main  ctx:75%  $5.82  ULTRA`).

2. **🗜️ MCP shrink** — wraps allowlisted, token-heavy MCP servers with `caveman-shrink`. Driven by an **allowlist of names** (`ALLOWLIST` in `templates/shrink-known-mcps.js`). It makes **no assumption about any server's transport** — whether an MCP is stdio (shrinkable) or remote/HTTP (not) is checked at runtime, because the same MCP can be local for one person and hosted for another. Present + stdio → wrapped; remote/HTTP, absent, or already-shrunk → skipped. Never installs an MCP you don't have.

**Repo-scoped (git repo only):**

3. **🕸️ Graphify** — two parts. **(3a) Wiring** via `templates/graphify-init.sh` (deterministic, like `caveman-init.sh`): installs/auto-updates the `graphify` CLI, then does graphify's **officially recommended** repo setup — `graphify claude install --project` + `graphify codex install --project` write a `## graphify` section into repo-local `CLAUDE.md`/`AGENTS.md` (prefer `graphify query` over grep) plus a read-only **query-nudge** PreToolUse hook on Claude Code; installs **auto-update git hooks** (`graphify hook install` — native post-commit/post-checkout, AST rebuild, no LLM, no husky) so the code graph stays current on every commit; gitignores `graphify-out/` (+ `/.graphify_*.json` root scratch); sweeps any leftover root scratch from a prior interrupted/old-version run. **(3b) Deep build:** the skill then invokes `/graphify . --mode deep` to build (or refresh) the full semantic graph, then re-sweeps root scratch (in case the build itself was interrupted). There is no CLI build verb — the deep build is LLM-orchestrated by the `/graphify` skill, so it runs as a skill step, not inside the script.

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

- `setup-matt-pocock-skills` — per-repo config (issue tracker, triage labels, domain docs) for the engineering skills (`to-issues`, `triage`, `tdd`, …). Interactive; iso-ai-init only *points* to it when `docs/agents/` is absent — never runs it.
- [`graphify`](../graphify/) — knowledge graph skill (manual invocation via `/graphify`)
- [`caveman`](../caveman/) — caveman mode skill (toggle via `/caveman`)

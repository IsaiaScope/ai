# ⚡ iso-ai-init

> Wire any repo with IsaiaScope AI defaults — token-compressed responses, context compression, and code-minimalism (primary) plus an installed, auto-updated graphify CLI and a deep semantic knowledge graph built on init.

---

## 🧩 What It Does

The Init run is driven by `scripts/init-runner.js` and `steps.json`. The runner decides scope:

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

**3. 🧠 headroom** — installs **headroom**, a context compressor that crushes everything the agent reads — tool output, logs, files, conversation history — **before it reaches the model** — 60–95% fewer tokens. Python CLI, wired into both agents via `headroom init` (durable hooks + provider routing through a local proxy on `127.0.0.1:8787`):

| Agent | Integration | Written |
|-------|-------------|---------|
| Claude Code | durable hooks + `ANTHROPIC_BASE_URL` proxy routing | `~/.claude/settings.json` |
| Codex | durable hooks + provider routing | `~/.codex/` config |

> Install order: `pipx install "headroom-ai[…]"` → **uv-managed Python 3.13** fallback. The fallback exists because a broken system/brew Python (macOS 26 `platform.mac_ver()` bug) lets `pipx install` "succeed" yet produces a `headroom` that can't run. Extras are the savings set only — `proxy,code,mcp,ml,relevance,memory` (+ `pytorch-mps` on Apple Silicon).

> Different layer from caveman: caveman compresses **your prose**, headroom compresses **everything the agent reads** — they stack, not overlap. Replaces rtk.

**4. 🐴 ponytail** — installs **ponytail**, a code-minimalism plugin that steers the agent to write the minimum necessary code ("does it need to exist? is it stdlib? can it be one line?"). Plugin for both agents; intensity in `~/.config/ponytail/config.json`, pinned to **ultra** to match caveman.

| Agent | Integration | Written |
|-------|-------------|---------|
| Claude Code | plugin (`marketplace add` + `install`) | `~/.claude/settings.json` |
| Codex | plugin install | `~/.codex/` |

### Repo-scoped steps (git repo only)

**5. 🕸️ Graphify** — runs in two parts:

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
✓ Caveman ultra + shrink MCP + statusline      [primary]
✓ headroom installed + Claude + Codex wired (durable hooks + proxy routing)   [primary]
✓ ponytail installed (ultra) + Claude + Codex wired   [primary]
✓ Graphify CLI installed / updated to latest
✓ /graphify skill wired + AST auto-update git hooks installed
  · graphify-out/ gitignored
  · deep semantic graph built/refreshed via /graphify --mode deep
```

> Restart Claude Code after running to activate the MCP, statusline, headroom proxy routing, ponytail plugin, and skill wiring.

---

## 🔧 Dependencies

| Tool | Purpose | Source |
|------|---------|--------|
| `caveman` | Token-compressed Claude responses | [GitHub](https://github.com/juliusbrussee/caveman) |
| `caveman-shrink` | Claude Code MCP for browser token savings | Bundled with `caveman --all` |
| `headroom` | Compresses agent context (60–95% fewer tokens) | [GitHub](https://github.com/chopratejas/headroom) |
| `ponytail` | Steers agents to write minimal code | [GitHub](https://github.com/DietrichGebert/ponytail) |
| `graphify` | Codebase → knowledge graph (installed + auto-updated) | [PyPI: graphifyy](https://pypi.org/project/graphifyy/) · [GitHub](https://github.com/safishamsi/graphify) |

### Install (reference)

```bash
# caveman — global, once per machine
npm install -g caveman --all

# headroom — global (pipx; uv-tool fallback on broken Python); then wire each agent
pipx install "headroom-ai[proxy,code,mcp,ml,relevance,memory]"
headroom init --global --memory claude    # Claude Code
headroom init --global --memory codex     # Codex

# ponytail — global plugin per agent + ultra config
claude plugin marketplace add DietrichGebert/ponytail && claude plugin install ponytail@ponytail --scope user

# graphify — global, prefer uv; --upgrade keeps it current
uv tool install --upgrade graphifyy
# or: pipx install graphifyy
```

---

### Templates

Deterministic orchestration lives in `scripts/init-runner.js` plus `steps.json`. Human-readable setup details and generated config live in `templates/` next to this file:

| Template | Scope | Purpose |
|----------|-------|---------|
| `preflight-gate.sh` | — | legacy human-readable scope plan; runner/manifest is authoritative |
| `caveman-init.sh` | global | installs caveman + sets ultra + registers MCP |
| `caveman-config.json` | global | sets ultra mode (`~/.config/caveman/config.json`) |
| `statusline.sh` | global | live token/cost/mode badge (`~/.claude/statusline-command.sh`) |
| `shrink-known-mcps.js` | global | wrap allowlisted, present, stdio MCPs with caveman-shrink |
| `headroom-init.sh` | global | install headroom (savings extras) + wire Claude + Codex (durable hooks + proxy) |
| `headroom-init.test.js` | global | integration test: install runs + wiring + idempotency (skips if offline) |
| `ponytail-init.sh` | global | write ultra config + install ponytail plugin for Claude + Codex |
| `ponytail-init.test.js` | global | integration test: ultra config + idempotency (skips if offline) |
| `graphify-init.sh` | repo | install/update graphify CLI + native always-on wiring + auto-update git hook |

> Edit any template to change default behavior — no SKILL.md change needed.
> The shrink allowlist lives in `shrink-known-mcps.js` (`ALLOWLIST` array).

---

## 🔗 Related

- [`iso‑init‑repo`](../iso-init-repo/) — repo *governance* (branches, CI, hooks); pairs with this skill's AI *tooling* setup.
- `setup-matt-pocock-skills` — per-repo config (issue tracker, triage labels, domain docs) for the engineering skills (`to-issues`, `triage`, `tdd`, …). Interactive; iso-ai-init only *points* to it when `docs/agents/` is absent — never runs it.
- [`graphify`](https://github.com/safishamsi/graphify) — the knowledge-graph skill this wires up (manual invocation via `/graphify`).
- [`caveman`](https://github.com/juliusbrussee/caveman) — the caveman-mode skill this activates (toggle via `/caveman`).
- [`headroom`](https://github.com/chopratejas/headroom) — the context compressor this installs and wires into both agents.
- [`ponytail`](https://github.com/DietrichGebert/ponytail) — the code-minimalism plugin this installs for both agents.

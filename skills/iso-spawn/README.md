# 🚀 iso-spawn

> Spawn a `codex` or `claude` agent in its own [herdr](https://herdr.dev) tab, in the **same workspace** you're working in — full permissions, optional auto-running task, delivered in the background so you never block.

---

## 🧩 What It Does

Opens a fresh agent beside you and (optionally) hands it a task that auto-runs the moment it boots. The new agent lands in the **current** workspace — resolved from your pane, not from whatever happens to have UI focus — and starts in your current directory, not `~`.

You stay unblocked: the prompt is delivered by a detached worker. Add `--wait` if you'd rather block until the task finishes.

---

## ▶️ Trigger

```
/iso-spawn
```

Or ask: *"spawn codex"*, *"open a claude tab"*, *"dispatch this task to an agent beside me"*

```bash
# codex here, full perms, task auto-runs (returns immediately)
scripts/spawn.sh codex --prompt "Add a health-check endpoint"

# claude, full perms, no prompt
scripts/spawn.sh claude

# dispatch and BLOCK until done, then report status
scripts/spawn.sh codex --prompt "Run tests and fix failures" --wait

# sandboxed, split the current tab, jump focus to it
scripts/spawn.sh codex --safe --split right --focus
```

---

## ⚙️ Defaults (the opinionated part)

| Default | Why | Opt out |
|---------|-----|---------|
| **Full permissions ON** | A dispatched agent should just work | `--safe` |
| **cwd = your pane's cwd** | Starts where you're working | `--cwd PATH` |
| **Background, no focus** | Spawns beside you without stealing focus | `--focus` |
| **One agent per call** | Predictable; fan-out = call again | — |

---

## 🎛️ Options

| flag | meaning |
|------|---------|
| `<codex\|claude>` | required first arg |
| `--prompt TEXT` | inject + auto-run on boot (delivered async) |
| `--cwd PATH` | working dir (default: caller's pane cwd) |
| `--label TEXT` | tab label (default: agent type) |
| `--name TEXT` | name base; auto-suffixed if taken |
| `--safe` | disable full permissions |
| `--split right\|down` | split current tab instead of new tab |
| `--focus` | switch focus to the new tab |
| `--wait` | block until the agent finishes, then print status |

---

## 🔍 Verify / Monitor

```bash
herdr agent list                                    # all agents + status
herdr agent get <term>                              # one agent's status
herdr agent wait <term> --status idle --timeout MS  # block on completion
```

Background spawns log to `<cwd>/.iso/logs/spawn/<date>__<agent>__<name>__<term>.log`.

---

## 🔧 Dependencies

| Tool | Role | Source |
|------|------|--------|
| `herdr` | Terminal workspace manager — panes, tabs, agents | [herdr.dev](https://herdr.dev) |
| `codex` / `claude` | The agent CLIs being spawned | — |

> Requires running **inside a herdr pane** (`$HERDR_PANE_ID` must be set).

---

## 📚 More

- [SKILL.md](SKILL.md) — the agent-facing contract and the *why it's built this way* notes.
- [REFERENCE.md](REFERENCE.md) — herdr object model, status semantics, failure modes.

## 🔗 Related

- [`iso-write`](../iso-write/) — give a spawned agent a plan to implement.
- [`iso-plan`](../iso-plan/) — produce that plan first.

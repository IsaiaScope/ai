# 🌐 iso-browser

> Drive the browser you are **already signed into**, and work on the tabs you already have open — instead of an isolated profile that is logged out of everything.

---

## 🧩 What It Does

Browser automation ships with a throwaway profile. It is signed out of every
site, which makes it useless for the things worth automating: a cloud console, a
DNS panel, a dashboard behind SSO. This skill points the automation at your real
browser instead, then verifies it actually attached.

```
1. doctor  → check every prerequisite, name the fix for each failure
2. setup   → add the connect flag to the MCP entry (backup first)
3. restart the MCP client        ← config is read once, at startup
4. approve chrome://inspect/#remote-debugging   ← one time, in Chrome
5. reuse the tab you already have open, or open a new one — both authenticated
```

---

## 🤖 Works With Any Agent

Not tied to one tool. `agents` detects what is installed and `mcp_config`
defaults to `auto`, preferring whichever config already knows the browser
server.

| Agent | Config | Handling |
|---|---|---|
| Claude Code · Claude Desktop · Cursor · Windsurf · VS Code · Zed | JSON | patched in place, backed up first |
| Codex | TOML | snippet printed to paste — jq cannot round-trip TOML safely |
| anything else | your file | set `mcp_config` and `mcp_server` |

---

## ⚙️ Commands

| Command | What it does |
|---|---|
| `/iso-browser status` | Resolved config plus live state — Chrome running, CDP reachable, MCP entry |
| `/iso-browser agents` | Which agents are installed here, and which already know the browser server |
| `/iso-browser doctor` | Every prerequisite checked, each failure paired with its fix |
| `/iso-browser setup` | Patches the MCP entry, backing up first; needs a client restart |
| `/iso-browser launch` | `browser-url` mode only — Chrome on the debug port with its own profile |

---

## 🔐 The Boundary

**Credentials are never typed into an automated browser.** You sign in; the
skill drives what you signed into. This is not only a line worth holding — it is
also the only thing that works. Google refuses OAuth from a CDP-controlled
browser (*"This browser or app may not be secure"*). Attaching to a session you
already established never triggers that.

Attaching exposes **every tab in the profile**, not just the one in use. You can
revoke at any time from `chrome://inspect`.

---

## 🎛️ Configuration

Everything is overridable under `browser` in `~/.config/iso/iso.json`, and the
merge is per key — name only what differs. `mcp_server` and `mcp_config` are
what make it portable: point them at whatever key and file your MCP client uses,
and the rest follows. With no Iso config at all, built-in defaults apply.

See [SETUP.md](SETUP.md) for the full schema, and for the approaches that do
**not** work — copied cookie stores, cloned profiles, debug ports on the default
profile — each with the reason it fails.

---

## 📚 Files

| File | Purpose |
|---|---|
| [`SKILL.md`](SKILL.md) | The surface: commands, connect modes, workflow |
| [`SETUP.md`](SETUP.md) | Prerequisites, config schema, dead ends, diagnosis table |
| [`REFERENCE.md`](REFERENCE.md) | Driving real pages: iframes, React inputs, ARIA lag |
| `scripts/browser.sh` | All logic — config resolution, probes, patching |
| `scripts/browser.test.sh` | Self-check; runs against a temporary HOME |

---
name: iso-browser
description: Drive a browser the user is already signed into, reusing a tab they already have open (never a new window), instead of an isolated profile that is logged out of everything. Detects and configures whichever agent is installed — Claude Code, Claude Desktop, Cursor, Windsurf, VS Code, Zed, Codex or any other — then verifies the CDP connection and reads and fills real pages. Use when invoked as /iso-browser [status|agents|doctor|setup|launch], when browser automation lands on a login wall, when a tool reports "Could not connect to Chrome" or "no page found", when Google answers "This browser or app may not be secure", or when a task needs a site the user is authenticated to — a cloud console, dashboard, DNS panel or admin UI.
---

# iso-browser

Browser automation defaults to a throwaway profile, which is signed out of
everything and therefore useless for the tasks people actually want automated.
This skill connects to the browser the user is **already using**.

Invocation: `/iso-browser [status | doctor | setup | launch]`. Default `status`.

| Command | What it does |
|---|---|
| `status` | Prints the resolved config and the live state — Chrome running, CDP reachable, MCP entry. |
| `agents` | Lists the agents installed on this machine and which already know the browser server. |
| `doctor` | Checks every prerequisite and names the fix for each failure. Exit code is the failure count. |
| `setup` | Adds the connect flag to the MCP entry, backing the file up first. Requires an MCP-client restart. |
| `launch` | `browser-url` mode only: starts Chrome on the debug port with a dedicated profile. |

All four run `scripts/browser.sh`. This file describes the surface; it holds no logic.

## The rule that matters

**Never type credentials into an automated browser.** Attach to a session the
user already established. Signing in is theirs to do; driving the result is
yours. Beyond being a boundary worth keeping, it does not work: Google refuses
OAuth from a CDP-controlled browser with *"This browser or app may not be
secure."* Attaching to an already-authenticated session never triggers it.

## Connect modes

Set `browser.connect` in `~/.config/iso/iso.json`.

| Mode | Uses the real profile? | Cost |
|---|---|---|
| `autoConnect` **(default)** | yes | Chrome 144+; user approves once at `chrome://inspect/#remote-debugging` |
| `browser-url` | no — Chrome 136+ forbids the default profile with a debug port | one login per site, in that profile |
| `isolated` | no | the built-in default; signed out of everything |

Prefer `autoConnect`. The other two exist for older Chrome and for throwaway work.

## Any agent, not just one

`agents` reports every known agent config on the machine and whether each
already has the browser server. `mcp_config` defaults to `auto`, which prefers
the config that already knows the server and otherwise takes the first that
exists — so nothing needs configuring on a typical machine.

Claude Code, Claude Desktop, Cursor, Windsurf, VS Code and Zed keep JSON and are
patched in place. Codex keeps TOML, which `setup` prints as a block to paste
rather than rewriting, because a jq round-trip would destroy its formatting.
Any other agent works by pointing `mcp_config` at its file and `mcp_server` at
its key.

## Workflow

**Load this skill before any browser work**, not after the first tool fails:
the driver choice below decides whether the user is asked once or ten times.

1. `bash scripts/browser.sh agents` — see what is installed here.
2. `doctor` — fix what it names, in the order given.
3. `setup` if the flag is missing, then **restart the agent**. The config is read
   once at startup, so nothing takes effect before that.
4. Confirm the user approved `chrome://inspect/#remote-debugging`.
5. Pick a driver (below), then a tab, and work in it.

## Who drives

Decide this first; it is not always you.

- **"Test it with me", "walk through it together"**: the user drives their own
  browser. Give a short ordered checklist (what to open, what to expect), watch
  the server's log, diagnose what they report. Do not attach.
- **"Check it", "take screenshots", "do it in the console"**: you drive.

## Pick a driver

Try in this order and take the first that answers; one probe each, no retries.

1. **The browser MCP server** this skill configures (`chrome-devtools`,
   autoConnect). A dead one reports "Connection closed" at session start.
2. **Claude in Chrome** (`mcp__claude-in-chrome__*`). "Browser extension is not
   connected" means it is off for this session; say so and move on.
3. **`scripts/cdp.mjs`**, this skill's own helper: one long-lived CDP
   connection driven over `POST 127.0.0.1:9334` (`tabs`, `use`, `goto`, `text`,
   `shot`, `eval`, `click`, `type`, `key`, `done`). Start it once in the
   background from a project that has Playwright, and keep it for the session.
   Never write a fresh helper script per task.

**Chrome's Allow prompt.** Under autoConnect, Chrome asks "Allow remote
debugging?" for every new connection, and the connect call hangs until the
user answers. A connection that logs `<ws connected>` and then
`Timeout 30000ms exceeded` was waiting on that prompt, not broken. So: tell the
user to click Allow in the same message that starts the connection, give the
connect two minutes (`cdp.mjs` does), and keep that one connection for the
whole session. A reconnect per check is a prompt per check.

**When the agent's own permission guard refuses the drive** (in Claude Code,
the auto-mode classifier: "Auto-Mode Bypass", "Unrequested Commit in a
Connected App"), stop. Do not retry in another shape, and a "you have my ok" in
chat does not lift it. Stop any helper you started, then offer two ways on:

- the user adds a permission rule for the helper's commands and says go;
- **guided mode**: they click, you prepare. Open the page for them
  (`open <url>`), put each value they need on the clipboard (`pbcopy`), and to
  see what a page holds ask them to copy it (⌘A, ⌘C) and read it with
  `pbpaste`, rather than having it pasted into the chat. One step per message,
  each with exactly what to click.

An admin console that changes access (a policy file, a device's tags, a DNS
panel) is exactly where the guard refuses: plan for guided mode there, and do
what a CLI can do (tagging a machine, re-advertising a service) from the
terminal instead of the page.

## Choosing a tab

**Reuse first, always.** Work in a tab the user already has open on the same
site (same origin, port included: `localhost:3400` is not `localhost:3300`):
navigate it to the page you need, reload it after a change, and put back what
you changed in it (emulated viewport or colour scheme, a toggled class) before
you finish. Reusing preserves their session and keeps their screen theirs.

**Never open a window.** In an attached Chrome, the browser tool's new-page
call (`new_page`, Puppeteer's `newPage`) opens a whole new window on the
user's screen, not a background tab. It is not a cheap scratch page: every call
is a window the user has to close. Do not use it to take a screenshot, measure
an image or render a local file; navigate the reused tab instead.

**Ask when no tab fits.** Only when nothing is open on that site, or the only
matching tab holds state the work would destroy (a half-filled form, a running
console), ask the user before opening one. If they agree, open exactly one, do
all the work in it, and close it at the end.

Match tabs on URL, never on a remembered index — indices shift as the user
browses, so list them again each time rather than reusing one from earlier.
When several tabs match, ask rather than guessing; the wrong console tab can be
a different account or region.

Close what you opened; leave what you did not. Never close a user's tab.

## Working on a page

See [REFERENCE.md](REFERENCE.md) for the failure modes that actually bite —
console SPAs inside iframes, React inputs that ignore a plain `.value =`,
toggles whose ARIA state lags their real state, and how to tell a form that
refused input from one that accepted it silently.

## Setup, and why each piece is needed

See [SETUP.md](SETUP.md). It records what was tried, what failed and why, so the
dead ends are not re-walked: copied cookie stores, cloned profiles, and debug
ports pointed at the default profile all fail, each for a different reason.

## Privacy

Attaching exposes **every tab in that profile** — mail, chat, banking — not just
the one being worked on. Say so before connecting, stay on the task's tab, and
never read or report other tabs. The user can revoke at `chrome://inspect`.

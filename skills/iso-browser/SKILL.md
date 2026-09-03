---
name: iso-browser
description: Drive a browser the user is already signed into, reusing a tab they have open or opening a new one, instead of an isolated profile that is logged out of everything. Detects and configures whichever agent is installed — Claude Code, Claude Desktop, Cursor, Windsurf, VS Code, Zed, Codex or any other — then verifies the CDP connection and reads and fills real pages. Use when invoked as /iso-browser [status|agents|doctor|setup|launch], when browser automation lands on a login wall, when a tool reports "Could not connect to Chrome" or "no page found", when Google answers "This browser or app may not be secure", or when a task needs a site the user is authenticated to — a cloud console, dashboard, DNS panel or admin UI.
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

1. `bash scripts/browser.sh agents` — see what is installed here.
2. `doctor` — fix what it names, in the order given.
3. `setup` if the flag is missing, then **restart the agent**. The config is read
   once at startup, so nothing takes effect before that.
4. Confirm the user approved `chrome://inspect/#remote-debugging`.
5. Pick a tab (below) and work in it.

## Choosing a tab

Two cases, and picking wrong is disruptive either way.

**Reuse an open tab** when the user refers to something already on screen —
"the console I have open", "this page", a task about state they have built up
mid-flow. Reusing preserves that state; a new tab throws it away and may land on
a login wall the original tab was already past.

**Open a new tab** for work the user has not staged: a fresh URL, a lookup, a
long automation that would otherwise clobber a page they are using. A new tab in
an attached profile inherits the session, so it is authenticated too.

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

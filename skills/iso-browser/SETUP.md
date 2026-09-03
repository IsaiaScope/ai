# Setup

What to install, what to approve, and — more usefully — which approaches fail
and why, so they are not re-attempted.

## Prerequisites

- **Chrome 144+** for `autoConnect`. Check with `--version`; older Chrome must use `browser-url`.
- **`jq`** and **`curl`**.
- An agent with a browser MCP server configured. Which agent does not matter —
  run `agents` to see what is detected here.

## Happy path

```bash
bash scripts/browser.sh doctor    # name what is missing
bash scripts/browser.sh setup     # add the flag, with a backup
# restart the MCP client
```

Then in Chrome: `chrome://inspect/#remote-debugging` → allow incoming debugging
connections. If no dialog appears, quit Chrome fully (⌘Q — closing the window is
not enough) and reopen.

Verify by listing pages. Seeing the user's real tabs means it worked; a single
`about:blank` means the client is still driving its own profile and the restart
did not happen or the flag did not land.

## Agents

`mcp_config` defaults to `auto`: the config that already names the browser
server wins, otherwise the first that exists. `agents` shows the table.

| Agent | Config | Format |
|---|---|---|
| Claude Code | `~/.claude.json`, or `.mcp.json` in a project | JSON |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | JSON |
| Cursor | `~/.cursor/mcp.json` | JSON |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | JSON |
| VS Code | `~/.vscode/mcp.json` | JSON |
| Zed | `~/.config/zed/settings.json` | JSON |
| Codex | `~/.codex/config.toml` | TOML |

JSON configs are patched in place, with a timestamped backup and a validity
check before the file is replaced. TOML is **printed, never rewritten** — jq
cannot round-trip TOML without destroying comments and layout, so `setup` emits
the block to paste:

```toml
[mcp_servers.chrome-devtools]
command = "npx"
args = ["-y", "chrome-devtools-mcp@latest", "--autoConnect"]
```

An agent not in the table works the same way — set `mcp_config` to its file and
`mcp_server` to its key. The patcher locates the entry wherever it is nested
rather than assuming a shape, so an unusual layout is not a barrier.

## Configuration

Everything is overridable under `browser` in `~/.config/iso/iso.json`. Defaults
live in `scripts/browser.sh`, so the skill works on a machine with no Iso config.

```json
{
  "browser": {
    "mcp_server": "chrome-devtools",
    "mcp_config": "auto",
    "connect": "autoConnect",
    "debug_port": 9222,
    "profile_dir": "~/.cache/chrome-debug-profile",
    "executable": {
      "darwin": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "linux": "/usr/bin/google-chrome",
      "windows": "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"
    }
  }
}
```

The merge is per key, so naming only `connect` keeps every other default.
`mcp_server` and `mcp_config` are what make this portable: point them at
whatever key and file your agent uses, or leave `auto` to detect. `setup` finds the entry wherever
it is nested, rather than assuming a fixed shape.

## Approaches that do not work

Each was tried; each fails for a different reason.

**Copying the cookie database into a second profile.** Chrome 127+ binds cookies
with app-bound encryption tied to the installation and profile path, so a copied
`Cookies` file will not decrypt elsewhere. Copying more files does not help —
the encryption is the obstacle. It is also the kind of operation a permission
classifier will refuse, correctly, since it is indistinguishable from credential
theft. Do not attempt it, and do not work around a refusal.

**A debug port on the default profile.** Chrome 136+ refuses
`--remote-debugging-port` when `--user-data-dir` is the default profile. This is
why `browser-url` mode needs a separate directory, and therefore starts signed
out — the very problem being solved.

**Signing in inside the automated browser.** Google blocks OAuth from a
CDP-controlled browser: *"This browser or app may not be secure."* It is a
deliberate control. Do not try to evade it by spoofing the user agent or
stripping automation flags.

**Editing the MCP config without restarting the client.** The config is read
once at startup. `setup` says this; it is the most common reason a correct
config appears not to work.

## Diagnosing a failed attach

The error text distinguishes the causes:

| Symptom | Meaning |
|---|---|
| `Could not find DevToolsActivePort` | Attaching to the real profile, but Chrome has not allowed incoming connections — do the `chrome://inspect` step. |
| `Could not connect to Chrome` | Chrome is not running, or the port is wrong. |
| Pages list shows only `about:blank` | Still on the client's own isolated profile — the flag or the restart is missing. |
| Pages list shows a sign-in page | Attached to the right browser, wrong profile, or the session expired. |

`pgrep -af 'user-data-dir'` shows which profile each Chrome is using, which
settles "is this even the right browser" faster than guessing.

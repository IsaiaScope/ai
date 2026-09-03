#!/usr/bin/env bash
# iso-browser mechanics: resolve config, check the connection, patch the MCP
# entry. SKILL.md describes the surface; nothing here makes a decision a model
# should be making.
set -euo pipefail

die() { printf 'iso-browser: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- config ----
# Defaults live here rather than in iso-config so this skill works on a machine
# that has no Iso config at all. Anything under `browser` in the Iso global
# config overrides them, key by key.
iso_browser_defaults() {
  cat <<'JSON'
{
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
JSON
}

iso_browser_global() {
  # Same env seam iso-config's lib/config.sh reads, so a relocated global scope
  # moves for this skill too. Not sourcing the library: the defaults above are
  # deliberately local, and this needs one path from it, not its merge.
  local f="${ISO_GLOBAL_CONFIG:-$HOME/.config/iso/iso.json}"
  [ -f "$f" ] && jq -c '.browser // {}' "$f" 2>/dev/null || printf '{}'
}

# Deep merge so a config naming only `connect` keeps every other default.
#
# Memoized: the merge is four processes and there are 16 `cfg` call sites, so
# `doctor` alone paid for it seven times to read seven scalars that cannot
# change mid-run. Same reason, same shape as _ISO_CONFIG_CACHE in
# iso-config/scripts/lib/config.sh.
_BROWSER_CFG=""
iso_browser_config() {
  [ -n "$_BROWSER_CFG" ] \
    || _BROWSER_CFG=$(jq -s '.[0] * .[1]' <(iso_browser_defaults) <(iso_browser_global))
  printf '%s' "$_BROWSER_CFG"
}

cfg() { iso_browser_config | jq -r --arg k "$1" 'getpath($k | split("."))'; }

expand() { printf '%s' "${1/#\~/$HOME}"; }

platform() {
  case "$(uname -s)" in
    Darwin) printf 'darwin' ;;
    Linux)  printf 'linux' ;;
    *)      printf 'windows' ;;
  esac
}

chrome_bin() { cfg "executable.$(platform)"; }

# ---------------------------------------------------------------- agents ----
# Where each agent keeps its MCP server list. Order is preference order when
# `mcp_config` is "auto". Adding an agent means adding a line here and nothing
# else; `json` entries can be patched in place, `toml` ones are printed for the
# user to paste, because rewriting TOML with jq would mangle it.
agent_registry() {
  cat <<REG
claude-code|${CLAUDE_CONFIG_DIR:-$HOME/.claude}.json|json
claude-code-project|$PWD/.mcp.json|json
claude-desktop|$HOME/Library/Application Support/Claude/claude_desktop_config.json|json
cursor|$HOME/.cursor/mcp.json|json
windsurf|$HOME/.codeium/windsurf/mcp_config.json|json
vscode|$HOME/.vscode/mcp.json|json
zed|$HOME/.config/zed/settings.json|json
codex|${CODEX_HOME:-$HOME/.codex}/config.toml|toml
REG
}

# An agent counts as present only if its config file exists AND already names
# the browser server. A config that exists but lacks the server is reported
# separately: it is a real agent the user may want to set up, not a match.
_AGENT_ROWS=""
agent_rows() {
  # Memoized: this stats eight paths and runs a full-tree jq over every JSON
  # config that exists - ~/.claude.json is routinely multi-MB - and `doctor`
  # reached it three times per run through resolve_config, mcp_entry and
  # mcp_has_flag. Nothing it reads changes inside one command.
  [ -z "$_AGENT_ROWS" ] || { printf '%s\n' "$_AGENT_ROWS"; return; }
  _AGENT_ROWS=$(_agent_rows_scan); printf '%s\n' "$_AGENT_ROWS"
}

_agent_rows_scan() {
  local name path fmt server; server=$(cfg mcp_server)
  while IFS='|' read -r name path fmt; do
    [ -f "$path" ] || continue
    local has=no
    if [ "$fmt" = json ]; then
      jq -e --arg s "$server" '[.. | objects | select(has($s))] | length > 0' "$path" >/dev/null 2>&1 && has=yes
    else
      grep -q "\[mcp_servers\.$server\]" "$path" 2>/dev/null && has=yes
    fi
    printf '%s|%s|%s|%s\n' "$name" "$path" "$fmt" "$has"
  done < <(agent_registry)
}

# Resolve the config to act on: an explicit path wins; "auto" prefers an agent
# that already has the server, and falls back to the first config that exists.
resolve_config() {
  local want; want=$(cfg mcp_config)
  if [ "$want" != auto ]; then printf '%s' "$(expand "$want")"; return; fi
  local first="" name path fmt has
  while IFS='|' read -r name path fmt has; do
    [ -n "$first" ] || first="$path"
    [ "$has" = yes ] && { printf '%s' "$path"; return; }
  done < <(agent_rows)
  printf '%s' "$first"
}

config_format() {
  local target="$1" name path fmt
  # agent_registry, not agent_rows: the format is declared in the table, while
  # agent_rows is the derived view that stats each file and greps it for the
  # server. Asking the derived view meant a config `setup` is about to create
  # had no declared format yet and fell through to the guess below.
  while IFS='|' read -r name path fmt; do
    [ "$path" = "$target" ] && { printf '%s' "$fmt"; return; }
  done < <(agent_registry)
  # Still needed: an explicit `mcp_config` path names a config no table row does.
  case "$target" in *.toml) printf 'toml' ;; *) printf 'json' ;; esac
}

# ---------------------------------------------------------------- probes ----
# Chrome writes DevToolsActivePort into the profile it was launched with. Its
# presence is the only reliable signal that a browser is accepting CDP; a
# running Chrome proves nothing on its own.
cdp_url() {
  local port; port=$(cfg debug_port)
  printf 'http://127.0.0.1:%s' "$port"
}

cdp_up() { curl -s -m 3 "$(cdp_url)/json/version" >/dev/null 2>&1; }

chrome_running() { pgrep -f '[Gg]oogle Chrome' >/dev/null 2>&1 || pgrep -f '[c]hrome' >/dev/null 2>&1; }

mcp_entry() {
  local f; f=$(resolve_config)
  [ -f "$f" ] || { printf '{}'; return; }
  jq -c --arg s "$(cfg mcp_server)" '
    [ .. | objects | select(has($s)) | .[$s] ] | first // {}
  ' "$f" 2>/dev/null || printf '{}'
}

mcp_has_flag() {
  mcp_entry | jq -e --arg f "$1" '(.args // []) | any(startswith($f))' >/dev/null 2>&1
}

# ---------------------------------------------------------------- commands --
cmd_status() {
  local target; target=$(resolve_config)
  printf 'platform     %s\n' "$(platform)"
  printf 'mcp server   %s\n' "$(cfg mcp_server)"
  printf 'mcp config   %s%s\n' "$target" \
    "$([ "$(cfg mcp_config)" = auto ] && printf '   (auto-detected)')"
  printf 'connect mode %s\n' "$(cfg connect)"
  printf 'chrome bin   %s\n' "$(chrome_bin)"
  printf '\nmcp entry    %s\n' "$(mcp_entry)"
  printf 'chrome       %s\n' "$(chrome_running && echo running || echo 'not running')"
  printf 'cdp %s  %s\n' "$(cdp_url)" "$(cdp_up && echo reachable || echo unreachable)"
}

# Which agents are installed on this machine, and which already know about the
# browser server. Answers "will this work with my agent" without guessing.
cmd_agents() {
  local name path fmt has any=no
  printf '%-22s %-6s %-9s %s\n' AGENT FORMAT "HAS-SERVER" CONFIG
  while IFS='|' read -r name path fmt has; do
    any=yes
    printf '%-22s %-6s %-9s %s\n' "$name" "$fmt" "$has" "$path"
  done < <(agent_rows)
  [ "$any" = yes ] || printf '(no known agent config found — set browser.mcp_config to an explicit path)\n'
}

# Reports, never repairs — `setup` owns the writing.
# ponytail: exit code is the number of failures, so callers can gate on it.
cmd_doctor() {
  local fails=0
  chk() { # chk <label> <ok?> <hint>
    if [ "$2" = "yes" ]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n        %s\n' "$1" "$3"; fails=$((fails+1)); fi
  }

  printf 'iso-browser doctor\n\n'

  have jq && chk "jq installed" yes "" || chk "jq installed" no "install jq"
  have curl && chk "curl installed" yes "" || chk "curl installed" no "install curl"

  local bin; bin=$(chrome_bin)
  [ -x "$bin" ] \
    && chk "chrome executable" yes "" \
    || chk "chrome executable" no "not executable: $bin — set browser.executable.$(platform) in ~/.config/iso/iso.json"

  local f; f=$(resolve_config)
  [ -n "$f" ] && [ -f "$f" ] \
    && chk "mcp config file ($f)" yes "" \
    || chk "mcp config file" no "none found — run 'agents' to see candidates, or set browser.mcp_config"

  [ "$(mcp_entry)" != "{}" ] \
    && chk "mcp server entry" yes "" \
    || chk "mcp server entry" no "no '$(cfg mcp_server)' entry in $f"

  case "$(cfg connect)" in
    autoConnect)
      mcp_has_flag --autoConnect \
        && chk "--autoConnect flag" yes "" \
        || chk "--autoConnect flag" no "run: browser.sh setup"
      chrome_running \
        && chk "chrome running" yes "" \
        || chk "chrome running" no "start Chrome, then visit chrome://inspect/#remote-debugging and allow incoming connections"
      ;;
    browser-url)
      mcp_has_flag --browser-url \
        && chk "--browser-url flag" yes "" \
        || chk "--browser-url flag" no "run: browser.sh setup"
      cdp_up \
        && chk "cdp reachable" yes "" \
        || chk "cdp reachable" no "run: browser.sh launch"
      ;;
    isolated)
      chk "isolated mode" yes ""
      ;;
    *)
      chk "connect mode" no "unknown mode '$(cfg connect)' — use autoConnect, browser-url or isolated"
      ;;
  esac

  printf '\n%s failure(s)\n' "$fails"
  return "$fails"
}

# Adds the flag for the configured connect mode to the MCP entry, in place.
# The MCP client reads its config once at startup, so this takes effect only
# after the client restarts — the caller is told, rather than the file lying.
cmd_setup() {
  have jq || die "jq required"
  local f flag mode port fmt
  f=$(resolve_config)
  [ -n "$f" ] && [ -f "$f" ] || die "mcp config not found — run 'agents' to see candidates"
  fmt=$(config_format "$f")
  mode=$(cfg connect)
  case "$mode" in
    autoConnect) flag="--autoConnect" ;;
    browser-url) port=$(cfg debug_port); flag="--browser-url=http://127.0.0.1:$port" ;;
    isolated)    printf 'isolated mode needs no flag\n'; return 0 ;;
    *)           die "unknown connect mode: $mode" ;;
  esac

  # TOML is not safely patchable with jq, so the snippet is printed instead of
  # rewriting a file this skill could corrupt.
  if [ "$fmt" = toml ]; then
    printf 'Config is TOML and is not edited automatically: %s\n\n' "$f"
    printf 'Add or amend this block, then restart the agent:\n\n'
    printf '  [mcp_servers.%s]\n' "$(cfg mcp_server)"
    printf '  command = "npx"\n'
    printf '  args = ["-y", "chrome-devtools-mcp@latest", "%s"]\n\n' "$flag"
    return 0
  fi

  local backup="$f.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$f" "$backup" || die "could not back up $f"

  local tmp; tmp=$(mktemp)
  jq --arg s "$(cfg mcp_server)" --arg flag "$flag" '
    def patch:
      if type == "object" then
        if has($s) and (.[$s] | type) == "object" then
          .[$s].args = (
            ((.[$s].args // []) | map(select(startswith("--autoConnect") or startswith("--browser-url") | not)))
            + [$flag]
          )
        else with_entries(.value |= patch) end
      else . end;
    patch
  ' "$f" > "$tmp" || { rm -f "$tmp"; die "jq patch failed"; }

  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "patch produced invalid JSON — $f untouched"; }
  mv "$tmp" "$f"

  printf 'patched %s\n' "$f"
  printf 'backup  %s\n' "$backup"
  printf 'entry   %s\n' "$(mcp_entry)"
  printf '\nRestart the MCP client for this to take effect.\n'
  [ "$mode" = autoConnect ] && printf 'Then, in Chrome: chrome://inspect/#remote-debugging → allow incoming connections.\n'
  return 0
}

# browser-url mode only. A separate user-data-dir is mandatory: Chrome 136+
# refuses --remote-debugging-port against the default profile, so this browser
# starts signed out and each site must be logged into once.
cmd_launch() {
  local bin dir port
  bin=$(chrome_bin); dir=$(expand "$(cfg profile_dir)"); port=$(cfg debug_port)
  [ -x "$bin" ] || die "chrome not executable: $bin"
  cdp_up && { printf 'cdp already reachable on %s\n' "$(cdp_url)"; return 0; }
  mkdir -p "$dir"
  nohup "$bin" --remote-debugging-port="$port" --user-data-dir="$dir" \
    --no-first-run --no-default-browser-check >/dev/null 2>&1 &
  printf 'launched pid %s\n' "$!"
  local end=$((SECONDS+20))
  until cdp_up || [ $SECONDS -ge $end ]; do sleep 1; done
  cdp_up && printf 'cdp reachable on %s\n' "$(cdp_url)" || die "cdp did not come up on port $port"
}

case "${1:-status}" in
  status) cmd_status ;;
  agents) cmd_agents ;;
  doctor) cmd_doctor ;;
  setup)  cmd_setup ;;
  launch) cmd_launch ;;
  *)      die "usage: browser.sh [status|agents|doctor|setup|launch]" ;;
esac

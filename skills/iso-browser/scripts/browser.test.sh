#!/usr/bin/env bash
# Self-check for browser.sh. No framework: every case is an assert against a
# temporary HOME, so nothing here touches the real MCP config.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/browser.sh"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n        %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] lacks [$3]" ;; esac; }

sandbox() {                      # sandbox <iso-json|-> <claude-json|->
  SB=$(mktemp -d)
  mkdir -p "$SB/.config/iso"
  [ "$1" = "-" ] || printf '%s' "$1" > "$SB/.config/iso/iso.json"
  [ "$2" = "-" ] || printf '%s' "$2" > "$SB/.claude.json"
}

# ISO_GLOBAL_CONFIG wins over HOME in browser.sh, so an exported one would point
# the whole suite at the developer's real ~/.config/iso/iso.json and the sandbox
# would report nothing wrong. Pinned per run, the way nine sibling suites do it.
run() { HOME="$SB" ISO_GLOBAL_CONFIG="$SB/.config/iso/iso.json" bash "$SUT" "$@" 2>&1; }

printf 'iso-browser tests\n\n'

# --- defaults apply when no Iso config exists ------------------------------
sandbox - '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@latest"]}}}'
out=$(run status)
has "defaults: server name"  "$out" "chrome-devtools"
has "defaults: connect mode" "$out" "autoConnect"

# --- global config overrides one key, keeps the rest ------------------------
sandbox '{"browser":{"connect":"browser-url","debug_port":9333}}' \
        '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@latest"]}}}'
out=$(run status)
has "override: connect"        "$out" "browser-url"
has "override: keeps server"   "$out" "chrome-devtools"
has "override: port applied"   "$out" "9333"

# --- a differently named MCP server is honoured -----------------------------
sandbox '{"browser":{"mcp_server":"my-browser"}}' \
        '{"mcpServers":{"my-browser":{"command":"npx","args":["-y","x"]}}}'
out=$(run status)
has "agnostic: custom server name" "$out" "my-browser"

# --- setup adds the flag for the configured mode ----------------------------
sandbox - '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@latest"]}}}'
run setup >/dev/null
got=$(jq -r '.mcpServers["chrome-devtools"].args | join(" ")' "$SB/.claude.json")
has "setup: adds --autoConnect" "$got" "--autoConnect"

# --- setup is idempotent, never duplicating the flag ------------------------
run setup >/dev/null
n=$(jq '[.mcpServers["chrome-devtools"].args[] | select(startswith("--autoConnect"))] | length' "$SB/.claude.json")
is "setup: idempotent" "$n" "1"

# --- switching modes replaces the flag rather than stacking -----------------
sandbox '{"browser":{"connect":"browser-url","debug_port":9222}}' \
        "$(cat "$SB/.claude.json")"
run setup >/dev/null
got=$(jq -r '.mcpServers["chrome-devtools"].args | join(" ")' "$SB/.claude.json")
has  "switch: adds --browser-url" "$got" "--browser-url"
case "$got" in *--autoConnect*) bad "switch: drops --autoConnect" "still present: $got" ;;
               *) ok "switch: drops --autoConnect" ;; esac

# --- setup backs up before writing ------------------------------------------
n=$(ls -1 "$SB"/.claude.json.bak-* 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 1 ] && ok "setup: writes a backup" || bad "setup: writes a backup" "none found"

# --- setup refuses a missing config rather than creating one ----------------
sandbox - -
out=$(run setup); rc=$?
is  "missing config: exit 1" "$rc" "1"
has "missing config: message" "$out" "mcp config not found"

# --- doctor fails loudly on an unknown mode ---------------------------------
sandbox '{"browser":{"connect":"nonsense"}}' '{"mcpServers":{"chrome-devtools":{"args":[]}}}'
out=$(run doctor)
has "bad mode: reported" "$out" "unknown mode"

# --- doctor checks for the mode's OWN flag, not merely some long flag -------
# `mcp_has_flag -- --autoConnect` passed `--` as $1, so the jq
# `startswith($f)` matched any argument beginning with a dash and every mode
# reported ok on every entry. A doctor that cannot go red is not a doctor.
sandbox '{"browser":{"connect":"autoConnect"}}' \
  '{"mcpServers":{"chrome-devtools":{"args":["--browser-url=http://127.0.0.1:9222"]}}}'
out=$(run doctor)
case "$out" in
  *"FAIL  --autoConnect flag"*) ok "doctor: a foreign long flag does not satisfy --autoConnect" ;;
  *) bad "doctor: a foreign long flag does not satisfy --autoConnect" "$out" ;;
esac

sandbox '{"browser":{"connect":"autoConnect"}}' \
  '{"mcpServers":{"chrome-devtools":{"args":["--autoConnect"]}}}'
out=$(run doctor)
case "$out" in
  *"ok    --autoConnect flag"*) ok "doctor: the real flag still reads ok" ;;
  *) bad "doctor: the real flag still reads ok" "$out" ;;
esac

# --- auto-detection prefers the config that already has the server ----------
sandbox - -
mkdir -p "$SB/.cursor"
printf '%s' '{"mcpServers":{"other":{}}}' > "$SB/.cursor/mcp.json"
printf '%s' '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","x"]}}}' > "$SB/.claude.json"
out=$(run status)
has "auto: picks config holding the server" "$out" ".claude.json"
has "auto: marked as detected"              "$out" "auto-detected"

# --- auto-detection falls back to any config that exists --------------------
sandbox - -
mkdir -p "$SB/.cursor"
printf '%s' '{"mcpServers":{"other":{}}}' > "$SB/.cursor/mcp.json"
out=$(run status)
has "auto: falls back to an existing config" "$out" "mcp.json"

# --- agents lists what is installed, with server presence -------------------
sandbox - '{"mcpServers":{"chrome-devtools":{"command":"npx","args":[]}}}'
out=$(run agents)
has "agents: names the agent"     "$out" "claude-code"
has "agents: reports has-server"  "$out" "yes"

# --- a non-Claude agent is fully supported ----------------------------------
sandbox - -
mkdir -p "$SB/.cursor"
printf '%s' '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@latest"]}}}' > "$SB/.cursor/mcp.json"
run setup >/dev/null
got=$(jq -r '.mcpServers["chrome-devtools"].args | join(" ")' "$SB/.cursor/mcp.json")
has "cursor: patched like any other agent" "$got" "--autoConnect"

# --- TOML is described, never rewritten -------------------------------------
sandbox - -
mkdir -p "$SB/.codex"
printf '[mcp_servers.chrome-devtools]\ncommand = "npx"\n' > "$SB/.codex/config.toml"
before=$(cat "$SB/.codex/config.toml")
out=$(run setup)
has "toml: prints a snippet"  "$out" "[mcp_servers.chrome-devtools]"
is  "toml: file untouched"    "$(cat "$SB/.codex/config.toml")" "$before"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# herdr.sh — thin wrappers over the herdr CLI. Every call guarded so a non-zero never aborts
# a caller running under `set -euo pipefail`. Assumes the caller set pipefail.

# Extract a value from herdr JSON on stdin by a ["a"]["b"][0] path.
herdr_jget() {
  python3 -c 'import json,sys,re
d=json.load(sys.stdin); cur=d
for k in re.findall(r"\[(?:\"([^\"]+)\"|(\d+))\]", sys.argv[1]): cur=cur[k[0] if k[0] else int(k[1])]
print(cur)' "$1"
}

# Resolve the caller pane -> "WORKSPACE\tCWD". Fails (rc 1) if $HERDR_PANE_ID unset/unresolvable.
herdr_caller_context() {
  [ -n "${HERDR_PANE_ID:-}" ] || return 1
  local info ws cwd
  info=$(herdr pane get "$HERDR_PANE_ID" 2>/dev/null) || return 1
  ws=$(printf '%s' "$info" | herdr_jget '["result"]["pane"]["workspace_id"]') || return 1
  cwd=$(printf '%s' "$info" | herdr_jget '["result"]["pane"]["cwd"]' 2>/dev/null || true)
  printf '%s\t%s' "$ws" "$cwd"
}

herdr_agent_status() { herdr agent get "$1" 2>/dev/null | herdr_jget '["result"]["agent"]["agent_status"]' 2>/dev/null || echo unknown; }
herdr_pane_for()     { herdr agent get "$1" 2>/dev/null | herdr_jget '["result"]["agent"]["pane_id"]'  2>/dev/null || true; }
herdr_tab_for()      { herdr agent get "$1" 2>/dev/null | herdr_jget '["result"]["agent"]["tab_id"]'   2>/dev/null || true; }
herdr_pane_read()    { herdr pane read "$1" --source visible --lines "${2:-40}" 2>/dev/null || true; }
herdr_pane_run()     { herdr pane run "$1" "$2" >/dev/null 2>&1 || true; }
herdr_send_keys()    { local p="$1"; shift; herdr pane send-keys "$p" "$@" >/dev/null 2>&1 || true; }
herdr_tab_close()    { herdr tab close "$1" >/dev/null 2>&1 || true; }

# All live agent terminal_ids, one per line.
herdr_agent_terms() {
  herdr agent list 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join(a.get("terminal_id","") for a in json.load(sys.stdin)["result"]["agents"]))
except Exception: pass' || true
}

# All live agent names, one per line (for name-collision avoidance).
herdr_agent_names() {
  herdr agent list 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join((a.get("name") or a.get("agent") or "") for a in json.load(sys.stdin)["result"]["agents"]))
except Exception: pass' || true
}

# Bounded scrollback text for a (live) agent. Empty after the tab is closed.
herdr_scrollback() {
  herdr agent read "$1" --source recent --lines "${2:-5000}" --format text 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["read"]["text"])
except Exception: pass'
}

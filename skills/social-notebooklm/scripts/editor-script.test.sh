#!/usr/bin/env bash
# editor-script.sh resolves config, names Projects from the Content folder, and
# drives both lengths. Never touches a real Editor.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
S=./editor-script.sh
bash -n "$S" || { echo "FAIL: syntax error"; rc=1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D="$T/2026-08-28 - Titolo di prova"
mkdir -p "$D"
printf '# t\n\n**HOOK**\n* uno\n\n**CTA**\n* due\n' > "$D/scaletta-long.md"
printf '# t\n\n**HOOK**\n* uno\n\n**CTA**\n* due\n' > "$D/scaletta-short.md"

# A stub Editor that logs create_project/update_canvas and answers everything.
cat > "$T/editor" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
log = open(os.environ["STUB_LOG"], "a")
state = {"scenes": []}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    m = json.loads(line)
    if m.get("method") == "notifications/initialized": continue
    n = m.get("params", {}).get("name", m.get("method"))
    a = m.get("params", {}).get("arguments", {})
    log.write(json.dumps([n, a]) + "\n"); log.flush()
    if m.get("method") == "initialize": o = {"protocolVersion": "2024-11-05"}
    elif n == "get_guides": o = {"content": [{"text": "g"}]}
    elif n == "list_recent_projects": o = {"content": [{"text": json.dumps({"projects": []})}]}
    elif n == "create_project": o = {"content": [{"text": json.dumps({"project_id": "p1"})}]}
    elif n == "begin_project_edit":
        o = {"content": [{"text": json.dumps({"tx_id": "t1", "timeline_hash": "h"})}]}
    elif n == "get_scenes":
        o = {"content": [{"text": json.dumps({"scenes": state["scenes"], "timeline_hash": "h"})}]}
    elif n == "create_scenes":
        state["scenes"] = [{"id": str(i), "name": s["name"]} for i, s in enumerate(a["scenes"])]
        o = {"content": [{"text": json.dumps({"ok": 1})}]}
    else: o = {"content": [{"text": json.dumps({"ok": 1})}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": o}) + "\n")
    sys.stdout.flush()
STUB
chmod +x "$T/editor"
export SOCIAL_EDITOR_BIN="$T/editor" STUB_LOG="$T/log"

: > "$STUB_LOG"
out=$("$S" "$D" 2>&1); code=$?
[ "$code" -eq 0 ] || { echo "FAIL: exited $code: $out"; rc=1; }

# Project names are the Content folder verbatim, suffixed. Not the title alone:
# two Contents sharing a title would collide, and delete_recordings is true.
grep -q '2026-08-28 - Titolo di prova - long'  "$STUB_LOG" || { echo "FAIL: long project misnamed"; rc=1; }
grep -q '2026-08-28 - Titolo di prova - short' "$STUB_LOG" || { echo "FAIL: short project misnamed"; rc=1; }
grep -q '"preset": "landscape"' "$STUB_LOG" || { echo "FAIL: long is not landscape"; rc=1; }
grep -q '"preset": "vertical"'  "$STUB_LOG" || { echo "FAIL: short is not vertical"; rc=1; }

# --long/--short restrict to one Project.
: > "$STUB_LOG"; "$S" "$D" --long >/dev/null 2>&1
grep -q ' - short' "$STUB_LOG" && { echo "FAIL: --long still pushed the short"; rc=1; }
: > "$STUB_LOG"; "$S" "$D" --short >/dev/null 2>&1
grep -q ' - long' "$STUB_LOG" && { echo "FAIL: --short still pushed the long"; rc=1; }

# A missing Scaletta for one length is skipped, not fatal for the other.
: > "$STUB_LOG"; rm -f "$D/scaletta-short.md"
out=$("$S" "$D" 2>&1); code=$?
[ "$code" -eq 0 ] || { echo "FAIL: a missing short Scaletta sank the run: $out"; rc=1; }
grep -q ' - long' "$STUB_LOG" || { echo "FAIL: the long Project was skipped too"; rc=1; }

# A wrong editor.kind refuses rather than sending Borumi's tool names elsewhere.
out=$(SOCIAL_EDITOR_KIND=kdenlive "$S" "$D" 2>&1); code=$?
[ "$code" -ne 0 ] || { echo "FAIL: an unknown editor kind was accepted"; rc=1; }
printf '%s' "$out" | grep -qi 'kdenlive' || { echo "FAIL: refusal does not name the kind: $out"; rc=1; }

# A missing Content directory is an error naming the path.
out=$("$S" "$T/nope" 2>&1); code=$?
[ "$code" -ne 0 ] || { echo "FAIL: a missing Content dir was accepted"; rc=1; }

grep -q '/Applications/Borumi' "$S" && { echo "FAIL: the editor path is hardcoded"; rc=1; }

[ "$rc" -eq 0 ] && echo "PASS: editor-script.sh"
exit "$rc"

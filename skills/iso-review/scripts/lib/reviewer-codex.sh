#!/usr/bin/env bash
# Codex Reviewer adapter: owns Codex review dispatch and raw output normalization.

reviewer_codex_dispatch() {  # $1=pane $2=level(ignored)
  local p="$1"
  herdr pane send-text "$p" "/review"; sleep 1; herdr pane send-keys "$p" Enter
  for _ in $(seq 1 15); do
    herdr_pane_read "$p" 30 | grep -q "Select a review preset" && break
    sleep 1
  done
  herdr_pane_read "$p" 30 | grep -q "Select a review preset" \
    || { echo "✗ codex review preset menu never appeared" >&2; return 1; }
  herdr pane send-keys "$p" Down; sleep 1; herdr pane send-keys "$p" Enter
  sleep 2
  if herdr_pane_read "$p" 30 | grep -q "Select a base branch"; then
    echo "✗ unexpected base-branch menu on uncommitted preset" >&2; return 1
  fi
  if herdr_pane_read "$p" 30 | grep -q "Select a review preset"; then
    echo "✗ codex preset menu still open after selection" >&2; return 1
  fi
  return 0
}

reviewer_codex_normalize() {  # $1=raw-file $2=out-json
  local raw="$1" out="$2"
  python3 - "$raw" "$out" <<'PY'
import json, re, sys

raw_path, out_path = sys.argv[1:3]
try:
    text = open(raw_path, encoding="utf-8").read().strip()
except OSError:
    text = ""

def parse_json(s):
    if not s or s.startswith("__"):
        return None
    try:
        return json.loads(s)
    except Exception:
        pass
    fence = re.search(r"```json\s*(.*?)```", s, re.S)
    if fence:
        try:
            return json.loads(fence.group(1))
        except Exception:
            return None
    return None

data = parse_json(text)
findings = []

if isinstance(data, dict):
    for item in data.get("findings", []) or []:
        loc = item.get("code_location") or {}
        line_range = loc.get("line_range") or {}
        title = str(item.get("title") or "").strip()
        body = str(item.get("body") or "").strip()
        problem = "\n".join(p for p in [title, body] if p)
        findings.append({
            "source": "codex",
            "file": str(loc.get("absolute_file_path") or item.get("file") or ""),
            "line": int(line_range.get("start") or item.get("line") or 0),
            "problem": problem,
            "fix": body,
            "severity": str(item.get("priority") or ""),
        })

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(findings, f, indent=2)
    f.write("\n")
PY
}

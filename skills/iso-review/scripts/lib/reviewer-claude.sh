#!/usr/bin/env bash
# Claude Reviewer adapter: owns Claude review dispatch and raw output normalization.

reviewer_claude_dispatch() {  # $1=pane $2=level(high|max)
  local p="$1" level="${2:-high}"
  herdr pane send-text "$p" "/code-review $level"; sleep 1; herdr pane send-keys "$p" Enter
  return 0
}

reviewer_claude_normalize() {  # $1=raw-file $2=out-json
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

if isinstance(data, list):
    for item in data:
        if not isinstance(item, dict):
            continue
        findings.append({
            "source": "claude",
            "file": str(item.get("file") or ""),
            "line": int(item.get("line") or 0),
            "problem": str(item.get("summary") or "").strip(),
            "fix": str(item.get("failure_scenario") or "").strip(),
            "severity": str(item.get("priority") or item.get("severity") or ""),
        })

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(findings, f, indent=2)
    f.write("\n")
PY
}

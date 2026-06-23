#!/usr/bin/env bash
# Reviewer: one module, Agent kind (codex|claude) is the seam. Owns review dispatch
# (per-kind command + any TUI menu nav) and raw-output normalization to Findings.
# The dispatch genuinely differs by kind; normalization shares ONE parse_json +
# file-read + JSON-write — only the source shape-map differs, so it branches on kind.

reviewer_dispatch() {  # $1=kind(codex|claude) $2=pane $3=level(claude: high|max; codex: ignored)
  local kind="$1" p="$2" level="${3:-high}"
  case "$kind" in
    claude)
      herdr pane send-text "$p" "/code-review $level"; sleep 1; herdr pane send-keys "$p" Enter
      return 0
      ;;
    *)  # codex: drive the /review preset menu, falling back to a direct JSON prompt
      local poll_count="${CODEX_REVIEW_PRESET_POLLS:-15}"
      herdr pane send-text "$p" "/review"; sleep 1; herdr pane send-keys "$p" Enter
      for _ in $(seq 1 "$poll_count"); do
        herdr_pane_read "$p" 30 | grep -q "Select a review preset" && break
        sleep 1
      done
      if ! herdr_pane_read "$p" 30 | grep -q "Select a review preset"; then
        herdr_pane_run "$p" 'Review the uncommitted working-tree diff. Focus on bugs, behavioral regressions, missing tests, and risks. Respond only with JSON in this exact shape:
{"findings":[{"title":"...","body":"...","priority":"P1|P2|P3","code_location":{"absolute_file_path":"...","line_range":{"start":1,"end":1}}}]}
Use an empty findings array if there are no issues.'
        sleep 2
        return 0
      fi
      herdr pane send-keys "$p" Down; sleep 1; herdr pane send-keys "$p" Enter
      sleep 2
      if herdr_pane_read "$p" 30 | grep -q "Select a base branch"; then
        echo "✗ unexpected base-branch menu on uncommitted preset" >&2; return 1
      fi
      if herdr_pane_read "$p" 30 | grep -q "Select a review preset"; then
        echo "✗ codex preset menu still open after selection" >&2; return 1
      fi
      return 0
      ;;
  esac
}

reviewer_normalize() {  # $1=kind(codex|claude) $2=raw-file $3=out-json
  local kind="$1" raw="$2" out="$3"
  python3 - "$kind" "$raw" "$out" <<'PY'
import json, re, sys

kind, raw_path, out_path = sys.argv[1:4]
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

if kind == "claude":
    # Claude /code-review emits a list of {file, line, summary, failure_scenario, priority}.
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
else:
    # Codex /review emits {"findings":[{title, body, priority, code_location:{...}}]}.
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

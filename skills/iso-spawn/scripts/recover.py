#!/usr/bin/env python3
"""Parse a spawned agent's JSONL transcript and emit its output or full chat.

Usage: recover.py <codex|claude> <output|chat> <jsonl_path> <text|json>
Prints to stdout. Exits 1 (with a note) when output is requested but no
assistant turn exists.
"""
import json
import sys


def codex_turns(path):
    """Yield (role, text) from a codex rollout, using the clean event_msg stream."""
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        pay = d.get("payload") if isinstance(d.get("payload"), dict) else d
        t = pay.get("type")
        if t == "user_message":
            msg = pay.get("message") or ""
            if msg.strip():
                yield ("user", msg)
        elif t == "agent_message":
            msg = pay.get("message") or ""
            if msg.strip():
                yield ("assistant", msg)


def claude_turns(path):
    """Yield (role, text) from a claude session; only turns with real text."""
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("type") not in ("user", "assistant"):
            continue
        content = (d.get("message") or {}).get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = "".join(
                b.get("text", "")
                for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
        else:
            text = ""
        if text.strip():
            yield (d["type"], text)


def emit(turns, what, fmt):
    if what == "output":
        asst = [t for t in turns if t[0] == "assistant"]
        if not asst:
            sys.stdout.write("# (no assistant output found)\n")
            sys.exit(1)
        selected = [asst[-1]]
    else:  # chat
        selected = turns
    if fmt == "json":
        print(json.dumps([{"role": r, "text": t} for r, t in selected]))
    elif what == "output":
        print(selected[0][1])
    else:
        for r, t in selected:
            print(f"=== {r} ===")
            print(t)
            print()


def main():
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: recover.py <codex|claude> <output|chat> <file> <text|json>\n"
        )
        sys.exit(2)
    agent, what, path, fmt = sys.argv[1:5]
    parser = codex_turns if agent.startswith("codex") else claude_turns
    turns = list(parser(path))
    emit(turns, what, fmt)


if __name__ == "__main__":
    main()

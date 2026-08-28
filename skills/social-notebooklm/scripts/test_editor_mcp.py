#!/usr/bin/env python3
"""Plain-assert tests for the Editor transport. Run: python3 test_editor_mcp.py

The Editor is stubbed by a python script that speaks the same JSON-RPC over
stdio, so none of this needs Borumi installed or running.
"""
import json, os, pathlib, subprocess, sys, tempfile

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from editor_mcp import Session, EditorError, parse_required_guides

STUB = r'''#!/usr/bin/env python3
import json, os, sys
log = open(os.environ["STUB_LOG"], "a")
served = set()
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    msg = json.loads(line)
    if msg.get("method") == "notifications/initialized": continue
    name = msg.get("params", {}).get("name", msg.get("method"))
    log.write(name + "\n"); log.flush()
    if msg.get("method") == "initialize":
        out = {"protocolVersion": "2024-11-05", "serverInfo": {"name": "stub"}}
    elif name == "get_guides":
        ids = msg["params"]["arguments"].get("guide_ids") or ["__gate__"]
        served.update(ids)
        out = {"content": [{"text": "guide text"}]}
    elif "__gate__" not in served:
        out = {"content": [{"text": "guide_required: Call get_guides without "
                                    "arguments before using other Borumi tools, then retry."}]}
    elif name == "needs_canvas" and "editing_canvas" not in served:
        out = {"content": [{"text": 'guide_required: This tool requires the project_edits, '
                                    'editing_canvas guides. Call get_guides with '
                                    '{"guide_ids":["project_edits","editing_canvas"]}, '
                                    'follow the guide, then retry.'}]}
    elif name == "always_refuses":
        out = {"content": [{"text": 'guide_required: This tool requires the nope guide. '
                                    'Call get_guides with {"guide_ids":["nope"]}, '
                                    'follow the guide, then retry.'}]}
    elif name == "hangs":
        while True: pass
    else:
        out = {"content": [{"text": json.dumps({"ok": name})}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": out}) + "\n")
    sys.stdout.flush()
'''

def stub():
    d = pathlib.Path(tempfile.mkdtemp())
    p = d / "stub.py"
    p.write_text(STUB, encoding="utf-8")
    p.chmod(0o755)
    log = d / "log"
    log.write_text("", encoding="utf-8")
    os.environ["STUB_LOG"] = str(log)
    return str(p), log

def test_parse_required_guides_reads_the_named_ids():
    text = ('guide_required: This tool requires the project_edits, editing_canvas guides. '
            'Call get_guides with {"guide_ids":["project_edits","editing_canvas"]}, '
            'follow the guide, then retry.')
    assert parse_required_guides(text) == ["project_edits", "editing_canvas"]

def test_parse_required_guides_returns_empty_for_the_bare_gate():
    text = ("guide_required: Call get_guides without arguments before using other "
            "Borumi tools, then retry.")
    assert parse_required_guides(text) == []

def test_parse_required_guides_ignores_a_normal_result():
    assert parse_required_guides('{"projects": []}') == []

def test_the_gate_is_satisfied_before_the_first_real_call():
    binary, log = stub()
    with Session(binary) as s:
        assert s.call("list_recent_projects", {}) == {"ok": "list_recent_projects"}
    calls = log.read_text(encoding="utf-8").split()
    assert calls[0] == "initialize", calls
    assert calls[1] == "get_guides", calls

def test_a_tool_specific_guide_is_fetched_and_the_call_retried():
    binary, log = stub()
    with Session(binary) as s:
        assert s.call("needs_canvas", {}) == {"ok": "needs_canvas"}
    calls = log.read_text(encoding="utf-8").split()
    # gate, the refused call, the named guide, then the successful retry
    assert calls.count("needs_canvas") == 2, calls
    assert calls.count("get_guides") == 2, calls

def test_a_second_refusal_is_a_hard_failure_not_a_loop():
    binary, _ = stub()
    with Session(binary) as s:
        try:
            s.call("always_refuses", {})
        except EditorError as e:
            assert "always_refuses" in str(e)
        else:
            raise AssertionError("a repeated guide_required should raise")

def test_a_hung_editor_is_bounded_by_the_timeout():
    binary, _ = stub()
    s = Session(binary, timeout=1.0)
    try:
        s.call("hangs", {})
    except EditorError as e:
        assert "timed out" in str(e).lower(), e
    else:
        raise AssertionError("a hung call should raise")
    finally:
        s.close()

if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print("  ok   %s" % name)
            except AssertionError as e:
                print("  FAIL %s: %s" % (name, e)); failed += 1
    print("PASS: editor_mcp" if not failed else "FAILED: %d" % failed)
    sys.exit(1 if failed else 0)

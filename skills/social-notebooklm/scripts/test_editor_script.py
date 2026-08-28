#!/usr/bin/env python3
"""Plain-assert tests for the Scaletta split. Run: python3 test_editor_script.py"""
import pathlib, sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from editor_script import split_scenes, SplitError

SCALETTA = """# L'effetto matrioska dell'IA spiegato semplice — scaletta long
<!-- focal points + contesto · NotebookLM (solo fonti) · 2026-08-28 -->

**HOOK**
* Se il tuo telefono ti corregge le parole
    * Il filtro antispam e la playlist non fanno la stessa cosa.

**La Matrioska Tecnologica**
* Il cerchio esterno dell'IA contiene anche logica pura
    * Pensa a El Ajedrecista del 1914.

**CTA**
* Scrivimi nei commenti
"""

def test_every_bold_line_starts_a_scene():
    scenes = split_scenes(SCALETTA)
    assert [s["name"] for s in scenes] == ["HOOK", "La Matrioska Tecnologica", "CTA"], scenes

def test_the_title_and_the_html_comment_are_dropped():
    body = "\n".join(s["script_markdown"] for s in split_scenes(SCALETTA))
    assert "scaletta long" not in body
    assert "<!--" not in body

def test_the_heading_survives_into_the_script():
    # Borumi's scripting guide: headings "are also valid Script content and
    # must not be removed implicitly".
    first = split_scenes(SCALETTA)[0]["script_markdown"]
    assert first.startswith("**HOOK**"), first

def test_bullets_pass_through_byte_for_byte():
    second = split_scenes(SCALETTA)[1]["script_markdown"]
    assert "    * Pensa a El Ajedrecista del 1914." in second, second

def test_a_scene_stops_at_the_next_heading():
    first = split_scenes(SCALETTA)[0]["script_markdown"]
    assert "Matrioska" not in first, first

def test_trailing_blank_lines_are_trimmed():
    for s in split_scenes(SCALETTA):
        assert s["script_markdown"] == s["script_markdown"].rstrip()

def test_a_file_with_no_headings_is_an_error():
    try:
        split_scenes("# titolo\n\n* solo bullet\n* nessuna sezione\n")
    except SplitError as e:
        assert "no section" in str(e).lower(), e
    else:
        raise AssertionError("a file with no bold heading must not yield one giant Scene")

def test_bold_inside_a_bullet_is_not_a_heading():
    # A Termine's gloss is bold and lives mid-bullet; only a bold line ALONE
    # is a boundary, or every glossed term would open a Scene.
    text = "**HOOK**\n* Questo e' il **Machine Learning (ML), cioe' ...**\n"
    assert [s["name"] for s in split_scenes(text)] == ["HOOK"]

import json, os, subprocess, tempfile
from editor_script import push
from editor_mcp import Session, EditorError

EDITOR_STUB = r'''#!/usr/bin/env python3
import json, os, sys
log = open(os.environ["STUB_LOG"], "a")
state = {"scenes": [], "hash": "h0"}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    msg = json.loads(line)
    if msg.get("method") == "notifications/initialized": continue
    name = msg.get("params", {}).get("name", msg.get("method"))
    args = msg.get("params", {}).get("arguments", {})
    log.write(json.dumps([name, args]) + "\n"); log.flush()
    if msg.get("method") == "initialize":
        out = {"protocolVersion": "2024-11-05"}
    elif name == "get_guides":
        out = {"content": [{"text": "guide"}]}
    elif name == "list_recent_projects":
        out = {"content": [{"text": json.dumps({"projects": [
            {"id": "p1", "name": os.environ.get("STUB_EXISTING", "other"), "path": "/x"}]})}]}
    elif name == "create_project":
        out = {"content": [{"text": json.dumps({"project_id": "p1"})}]}
    elif name == "begin_project_edit":
        # Verified against Borumi 0.29.3: begin_project_edit returns
        # base_commit_id/project_id/tx_id and NO timeline_hash. Only
        # get_scenes carries one.
        out = {"content": [{"text": json.dumps(
            {"tx_id": "t1", "project_id": "p1", "base_commit_id": "c0"})}]}
    elif name == "get_scenes":
        out = {"content": [{"text": json.dumps(
            {"scenes": state["scenes"], "timeline_hash": state["hash"]})}]}
    elif name == "delete_scenes":
        state["scenes"] = []; state["hash"] = "h1"
        out = {"content": [{"text": json.dumps({"ok": True})}]}
    elif name == "create_scenes":
        if os.environ.get("STUB_FAIL_CREATE"):
            out = {"content": [{"text": "error: refused"}]}
        else:
            state["scenes"] = [{"id": "s%d" % i, "name": s["name"]}
                               for i, s in enumerate(args["scenes"])]
            out = {"content": [{"text": json.dumps({"ok": True})}]}
    else:
        out = {"content": [{"text": json.dumps({"ok": True})}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": out}) + "\n")
    sys.stdout.flush()
'''

def editor_stub(existing=None, fail_create=False):
    d = pathlib.Path(tempfile.mkdtemp())
    p = d / "editor.py"; p.write_text(EDITOR_STUB, encoding="utf-8"); p.chmod(0o755)
    log = d / "log"; log.write_text("", encoding="utf-8")
    os.environ["STUB_LOG"] = str(log)
    os.environ.pop("STUB_EXISTING", None); os.environ.pop("STUB_FAIL_CREATE", None)
    if existing: os.environ["STUB_EXISTING"] = existing
    if fail_create: os.environ["STUB_FAIL_CREATE"] = "1"
    return str(p), log

def calls(log):
    return [json.loads(l) for l in log.read_text(encoding="utf-8").splitlines() if l.strip()]

def names(log):
    return [c[0] for c in calls(log)]

def test_a_missing_project_is_created():
    binary, log = editor_stub(existing="something else")
    with Session(binary) as s:
        push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
    n = names(log)
    assert "create_project" in n, n
    assert n.index("list_recent_projects") < n.index("create_project"), n

def test_an_existing_project_is_reused_not_duplicated():
    binary, log = editor_stub(existing="2026-08-28 - Titolo - long")
    with Session(binary) as s:
        push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
    assert "create_project" not in names(log), names(log)

def test_existing_scenes_are_deleted_with_their_recordings():
    binary, log = editor_stub(existing="2026-08-28 - Titolo - long")
    with Session(binary) as s:
        s.call("create_scenes", {"tx_id": "t1", "timeline_hash": "h0",
                                 "scenes": [{"name": "Vecchia", "script_markdown": "x"}]})
        push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
    deletes = [c for c in calls(log) if c[0] == "delete_scenes"]
    assert deletes, "existing scenes were not deleted"
    assert deletes[0][1]["delete_recordings"] is True, deletes[0]

def test_the_timeline_hash_is_reread_before_create_scenes():
    # delete_scenes and update_canvas both invalidate it; a stale hash makes
    # create_scenes fail on a real Editor.
    binary, log = editor_stub(existing="2026-08-28 - Titolo - long")
    with Session(binary) as s:
        s.call("create_scenes", {"tx_id": "t1", "timeline_hash": "h0",
                                 "scenes": [{"name": "Vecchia", "script_markdown": "x"}]})
        push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
    seq = names(log)
    created = len(seq) - 1 - seq[::-1].index("create_scenes")
    deleted = seq.index("delete_scenes")
    assert "get_scenes" in seq[deleted:created], seq
    hashes = [c[1]["timeline_hash"] for c in calls(log) if c[0] == "create_scenes"]
    assert hashes[-1] == "h1", hashes

def test_the_canvas_preset_is_set_inside_the_transaction():
    binary, log = editor_stub()
    with Session(binary) as s:
        push(s, "2026-08-28 - Titolo - short", split_scenes(SCALETTA), "vertical")
    canvas = [c for c in calls(log) if c[0] == "update_canvas"]
    assert canvas, "canvas was never set"
    assert canvas[0][1]["format"] == {"type": "preset", "preset": "vertical"}, canvas[0]
    assert canvas[0][1]["tx_id"] == "t1", canvas[0]

def test_the_commit_is_last_and_names_the_destruction():
    # A re-run, which is the only case that HAS a destruction to name.
    binary, log = editor_stub(existing="2026-08-28 - Titolo - long")
    with Session(binary) as s:
        s.call("create_scenes", {"tx_id": "t1", "timeline_hash": "h0",
                                 "scenes": [{"name": "Vecchia", "script_markdown": "x"}]})
        summary = push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
    assert names(log)[-1] == "commit_project_edit", names(log)
    assert "3" in summary, summary
    assert "recording" in summary.lower(), summary

def test_a_fresh_project_does_not_claim_a_destruction():
    # The summary is the Editor's own change log. Saying recordings were
    # removed when the project was empty would make it lie.
    binary, _ = editor_stub()
    with Session(binary) as s:
        summary = push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
    assert "recording" not in summary.lower(), summary

def test_a_mid_transaction_failure_aborts_and_never_commits():
    binary, log = editor_stub(fail_create=True)
    with Session(binary) as s:
        try:
            push(s, "2026-08-28 - Titolo - long", split_scenes(SCALETTA), "landscape")
        except EditorError:
            pass
        else:
            raise AssertionError("a refused create_scenes should raise")
    n = names(log)
    assert "abort_project_edit" in n, n
    assert "commit_project_edit" not in n, n

if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn(); print("  ok   %s" % name)
            except AssertionError as e:
                print("  FAIL %s: %s" % (name, e)); failed += 1
    print("PASS: editor_script" if not failed else "FAILED: %d" % failed)
    sys.exit(1 if failed else 0)

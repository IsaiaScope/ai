#!/usr/bin/env python3
"""Turn a Scaletta into Editor Scenes and write them into an Editor Project.

Knows nothing about JSON-RPC: `editor_mcp.Session` owns the wire. This file
owns two things -- where a Scene begins, and the order the Editor's tools must
be called in.
"""
import re

from editor_mcp import EditorError, Session

# A bold line ALONE is a section heading. Anchored to the whole line because a
# Gloss is bold and sits mid-bullet ("il **Machine Learning (ML), cioe' ...**");
# an unanchored match would open a Scene at every glossed Termine.
_HEADING = re.compile(r'^\*\*([^*]+)\*\*[ \t]*$')
_COMMENT = re.compile(r'^\s*<!--.*-->\s*$')


class SplitError(Exception):
    """The Scaletta has no sections to become Scenes."""


def split_scenes(text):
    """[{name, script_markdown}] in document order.

    The heading stays inside script_markdown as well as becoming the name:
    the Editor's scripting guide is explicit that headings "are also valid
    Script content and must not be removed implicitly". Everything else is
    passed through byte for byte -- no rewrapping, no re-indenting -- because
    the bullets already passed the Ramp lint in exactly this form.
    """
    scenes = []
    for line in text.splitlines():
        m = _HEADING.match(line)
        if m:
            scenes.append({"name": m.group(1).strip(), "lines": [line]})
        elif scenes:
            scenes[-1]["lines"].append(line)
        # Before the first heading: the "# title" line and the HTML comment.
        # Dropped rather than attached to Scene 1, which they do not belong to.
    if not scenes:
        raise SplitError("no section headings found -- expected a line of the "
                         "form **Sezione** on its own")
    return [{"name": s["name"], "script_markdown": "\n".join(s["lines"]).rstrip()}
            for s in scenes]


def _project_id(session, name):
    """The Editor's alias for the Project called `name`, creating it if absent.

    Listing is not optional even when creating: IDs are per-connection
    aliases and `list_recent_projects` is what populates the table for this
    connection. An ID carried in from anywhere else is `unknown_id_alias`.
    """
    listed = session.call("list_recent_projects", {})
    for p in (listed or {}).get("projects", []):
        if p.get("name") == name:
            return p["id"]
    created = session.call("create_project", {"name": name})
    pid = created.get("project_id") or created.get("id") or \
        (created.get("project") or {}).get("id")
    if not pid:
        raise EditorError("could not create the project %r: %r" % (name, created))
    return pid


def push(session, project_name, scenes, preset):
    """Replace a Project's Scenes with `scenes`. Returns the committed summary.

    DESTRUCTIVE: existing Scenes are deleted with delete_recordings=True, so
    any Takes recorded against them are destroyed, not orphaned. Deliberate --
    see docs/adr/0002-editor-scenes-replace-destructively.md. One Content owns
    one Project per length, always matching the current Scaletta.
    """
    pid = _project_id(session, project_name)
    tx = session.call("begin_project_edit", {"project_id": pid})
    # begin_project_edit returns no timeline_hash -- only get_scenes does, and
    # every hash used below is reread from there anyway.
    tx_id = tx["tx_id"]
    try:
        existing = session.call("get_scenes", {"tx_id": tx_id})
        old = [s["id"] for s in existing.get("scenes", [])]
        removed = len(old)
        if old:
            session.call("delete_scenes", {
                "tx_id": tx_id, "timeline_hash": existing["timeline_hash"],
                "scene_ids": old, "delete_recordings": True})
        session.call("update_canvas", {
            "tx_id": tx_id, "format": {"type": "preset", "preset": preset}})
        # Reread once, after BOTH edits: each can invalidate the hash, and
        # create_scenes is rejected outright if it carries a stale one.
        thash = session.call("get_scenes", {"tx_id": tx_id})["timeline_hash"]
        session.call("create_scenes", {
            "tx_id": tx_id, "timeline_hash": thash, "scenes": scenes})
        got = [s["name"] for s in session.call("get_scenes", {"tx_id": tx_id})
               .get("scenes", [])]
        want = [s["name"] for s in scenes]
        if got != want:
            raise EditorError("scenes verified wrong: %r != %r" % (got, want))
        summary = ("Set %d scenes from the Scaletta (%s)" % (len(scenes), preset))
        if removed:
            summary += ", replacing %d and their recordings" % removed
        session.call("commit_project_edit", {"tx_id": tx_id,
                                             "change_summary": summary})
        return summary
    except Exception:
        # Never leave a transaction open: an abandoned tx blocks the next run.
        try:
            session.call("abort_project_edit", {"tx_id": tx_id})
        except Exception:
            pass
        raise


def main(argv=None):
    import argparse
    import pathlib
    ap = argparse.ArgumentParser(description="Write a Scaletta into the Editor as Scenes.")
    ap.add_argument("scaletta")
    ap.add_argument("--binary", required=True)
    ap.add_argument("--name", required=True, help="Editor Project name")
    ap.add_argument("--preset", required=True, choices=["landscape", "vertical"])
    ap.add_argument("--timeout", type=float, default=60.0)
    a = ap.parse_args(argv)
    try:
        scenes = split_scenes(pathlib.Path(a.scaletta).read_text(encoding="utf-8"))
    except (OSError, SplitError) as e:
        print("editor-script: %s" % e)
        return 1
    try:
        with Session(a.binary, timeout=a.timeout) as s:
            summary = push(s, a.name, scenes, a.preset)
    except EditorError as e:
        print("editor-script: %s" % e)
        return 1
    print("%s -- %s" % (a.name, summary))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())

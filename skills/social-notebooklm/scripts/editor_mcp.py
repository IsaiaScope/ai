#!/usr/bin/env python3
"""One long-lived JSON-RPC session against the video Editor's MCP server.

Knows nothing about Scenes, Projects or Scalette: it spawns the binary, keeps
the connection open, and turns `tools/call` into a python call. Two properties
of the server shape this, both established against a running Borumi 0.29.3
rather than read from its docs:

  * `get_guides` with no arguments is a gate. Every other tool refuses until it
    has been called, and individual tools refuse again naming further guides
    they need -- `update_canvas` wants `editing_canvas`, which an enumerated
    list got wrong on the first attempt.
  * IDs are per-connection aliases. An ID obtained in one connection is
    `unknown_id_alias` in the next, so a per-call subprocess cannot work and
    nothing may be persisted between runs except a Project's name.

Guides are therefore fetched reactively: the server names what it wants in the
error, so the transport reads that rather than carrying a list to keep in sync.
"""
import json
import re
import select
import subprocess

# The server puts the exact retry argument in its refusal, e.g.
#   Call get_guides with {"guide_ids":["project_edits","editing_canvas"]}
_GUIDE_IDS = re.compile(r'"guide_ids"\s*:\s*(\[[^\]]*\])')
_GUIDE_REQUIRED = "guide_required"


class EditorError(Exception):
    """The Editor refused, timed out, or died."""


def parse_required_guides(text):
    """Guide ids named in a `guide_required` message; [] for anything else.

    The bare gate message names none, which is not the same as "not a
    refusal" -- the caller distinguishes them by checking for the marker
    first, so an empty list here means "fetch the gate".
    """
    if _GUIDE_REQUIRED not in text:
        return []
    m = _GUIDE_IDS.search(text)
    if not m:
        return []
    try:
        ids = json.loads(m.group(1))
    except ValueError:
        return []
    return [str(i) for i in ids]


class Session:
    """A live connection. Use as a context manager; one per Editor Project."""

    def __init__(self, binary, timeout=60.0):
        self._timeout = timeout
        try:
            self._p = subprocess.Popen(
                [binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, bufsize=1)
        except OSError as e:
            raise EditorError("cannot start the editor at %s: %s" % (binary, e))
        self._id = 0
        self._rpc("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "social-notebooklm", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self._guides({})                      # the gate, once per connection

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        if self._p.poll() is None:
            try:
                self._p.stdin.close()
            except Exception:
                pass
            self._p.terminate()
            try:
                self._p.wait(timeout=5)
            except Exception:
                self._p.kill()

    # -- wire ------------------------------------------------------------

    def _send(self, msg):
        try:
            self._p.stdin.write(json.dumps(msg) + "\n")
            self._p.stdin.flush()
        except (BrokenPipeError, ValueError):
            raise EditorError("the editor closed the connection")

    def _readline(self):
        """One line, or EditorError. select() bounds a wedged or absent app.

        The stage is chained into scaletta.sh, so an unbounded read would
        block the whole pipeline rather than degrade it -- and what the
        binary does with the app shut is not established.
        """
        ready, _, _ = select.select([self._p.stdout], [], [], self._timeout)
        if not ready:
            self.close()
            raise EditorError("the editor timed out after %gs -- is it running?"
                              % self._timeout)
        line = self._p.stdout.readline()
        if not line:
            raise EditorError("the editor exited unexpectedly")
        return line

    def _rpc(self, method, params):
        self._id += 1
        want = self._id
        self._send({"jsonrpc": "2.0", "id": want, "method": method, "params": params})
        while True:
            line = self._readline().strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue                       # notifications and log noise
            if d.get("id") == want:
                return d

    def _text(self, d):
        if "error" in d:
            raise EditorError(json.dumps(d["error"]))
        return "".join(c.get("text", "")
                       for c in d.get("result", {}).get("content", []))

    def _guides(self, args):
        self._text(self._rpc("tools/call", {"name": "get_guides", "arguments": args}))

    # -- api -------------------------------------------------------------

    def call(self, name, args):
        """Call a tool, satisfying whatever guide it asks for, once.

        Returns the parsed JSON body when the server sends JSON, the raw text
        otherwise. A second refusal for the same call raises rather than
        looping: the server is asking for something it will not accept.
        """
        for attempt in (1, 2):
            text = self._text(self._rpc("tools/call", {"name": name, "arguments": args}))
            if _GUIDE_REQUIRED not in text:
                try:
                    return json.loads(text)
                except ValueError:
                    return text
            if attempt == 2:
                raise EditorError("%s kept asking for guides: %s" % (name, text))
            ids = parse_required_guides(text)
            self._guides({"guide_ids": ids} if ids else {})
        raise EditorError("unreachable")
